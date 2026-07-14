//! Vision / multimodal T1 (WP-V2, D-026): the projector lifecycle, the
//! untrusted-image pre-decode gate, and the interleaved image+text ingest.
//!
//! Security contract (docs/audit-wp-v1-mtmd-2026-07-14.md §5, binding):
//! - **Req 1, fail-closed allow-list:** the raw file bytes are gated in Rust on
//!   full magic prefixes — JPEG `FF D8 FF`, PNG `89 50 4E 47 0D 0A 1A 0A`, BMP
//!   `42 4D` — and anything else (GIF included, dropped per the audit §2b
//!   recommendation) is rejected with a classed image error before any decode
//!   FFI call. Never routed on file extension.
//! - **Req 2, same-buffer:** the file is read ONCE here and the identical
//!   buffer goes to `mtmd_helper_bitmap_init_from_buf`; the path-taking helper
//!   (whose C-side re-read reopens the audio sniff via TOCTOU) is not declared.
//! - **Req 3, pre-decode caps:** byte cap (caller-supplied, hard ceiling
//!   `i32::MAX` for the stb `int` length), then `stbi_info_from_memory` (a
//!   header-only probe on the same buffer, exported from libmtmd — verified
//!   with `nm`) with `1 <= nx, ny <= 16384` and `nx * ny <= 33,554,432` pixels,
//!   all in u64 — so no oversized or degenerate decode ever starts (kills the
//!   decompression-bomb OOM, the un-caught `bad_alloc` in the helper, and the
//!   `mtmd-image.cpp` degenerate-dims asserts).
//! - **Req 7:** `mtmd_context_params.cb_eval` stays NULL (T3 is out of scope).
//!
//! The interleaved decode reuses upstream's tested `mtmd_helper_eval_chunks`
//! (n_batch-aware for both text and image chunks — the hard-rule-8a chokepoint
//! for this path; M-RoPE / non-causal handling is never reimplemented in Rust,
//! the D-012 fails-silent trap).

use std::ffi::{c_void, CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::Path;
use std::ptr::NonNull;
use std::sync::{Mutex, Once, PoisonError};
use std::thread::ThreadId;

use crate::engine::{assert_r_main_thread, LoadedModel};
use crate::error::RebirthError;
use crate::ffi;
use crate::generate::GenerateParams;
use crate::generate::Generation;

// --- pre-decode caps (audit req 3) ------------------------------------------

/// Hard byte ceiling: `mtmd_helper_bitmap_init_from_buf` narrows the buffer
/// length to stb's `int` (audit F6), so a buffer at or over 2^31 bytes must
/// never reach it regardless of the user-facing cap.
pub const IMAGE_HARD_MAX_BYTES: u64 = i32::MAX as u64;

/// Maximum width/height accepted before decode (audit req 3b).
pub const IMAGE_MAX_DIM: u64 = 16_384;

/// Maximum total pixel count accepted before decode (audit req 3b): 32 Mpx,
/// far above any real photograph a VLM tokenizes, far below the ~2 GB u8 (x2
/// copies, x4 as f32 in clip) a crafted PNG could otherwise legally expand to.
pub const IMAGE_MAX_PIXELS: u64 = 33_554_432;

/// The magic-byte allow-list (audit req 1). GIF is deliberately absent (audit
/// §2b: the riskiest stb decoder for near-zero VLM value — first frame only).
/// Returns the canonical lowercase format name, or `None` for anything else
/// (including audio magics — RIFF/WAVE, MP3 sync, fLaC, ID3 — which must never
/// reach the auto-detecting decode helper).
fn detect_image_format(bytes: &[u8]) -> Option<&'static str> {
    const PNG: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if bytes.len() >= 8 && bytes[..8] == PNG {
        return Some("png");
    }
    if bytes.len() >= 3 && bytes[..3] == [0xFF, 0xD8, 0xFF] {
        return Some("jpeg");
    }
    if bytes.len() >= 2 && bytes[..2] == [0x42, 0x4D] {
        return Some("bmp");
    }
    None
}

/// Gate `bytes` (the exact buffer that will be handed to the decode helper):
/// magic allow-list, then the byte cap, then the header-only dimension probe
/// with the dimension/pixel caps computed in u64. Returns the detected format
/// name. Every rejection is a classed image error whose message names the
/// specific failing stage (the mutation-proof the per-commit adversarial tests
/// assert on), and the file's path rides on the structured `path` field.
pub(crate) fn validate_image_bytes(
    path: &str,
    bytes: &[u8],
    max_bytes: u64,
) -> Result<&'static str, RebirthError> {
    let image_err = |reason: String| RebirthError::Image {
        reason,
        path: Some(path.to_string()),
        expected: None,
        actual: None,
    };

    // Stage 1 — the fail-closed magic allow-list (audit req 1), before any FFI.
    let format = detect_image_format(bytes).ok_or_else(|| {
        image_err(format!(
            "'{path}' is not a supported image: its magic bytes match none of the \
             allowed formats (JPEG, PNG, BMP). Audio, video, GIF, and every other \
             format are rejected before any decode. Convert the image to PNG or \
             JPEG and try again."
        ))
    })?;

    // Stage 2 — the byte cap (audit req 3a), authoritative on this buffer.
    let cap = max_bytes.min(IMAGE_HARD_MAX_BYTES);
    if bytes.len() as u64 > cap {
        return Err(image_err(format!(
            "'{path}' is {} bytes, over the {} image byte cap. If this is a \
             legitimate image, raise options(relm.image_max_bytes = ) — the hard \
             ceiling is {} bytes.",
            bytes.len(),
            cap,
            IMAGE_HARD_MAX_BYTES
        )));
    }

    // Stage 3 — the header-only dimension probe on the SAME buffer (audit
    // req 3b). stbi_info_from_memory parses only the header: no pixel
    // allocation happens, so this is safe to run before any cap on the
    // decoded size. The length cast is sound: stage 2 capped it below i32::MAX.
    let mut nx: c_int = 0;
    let mut ny: c_int = 0;
    let mut comp: c_int = 0;
    // SAFETY: `bytes` outlives the call; the three out-pointers are valid
    // locals; the length fits c_int (stage 2).
    let ok = unsafe {
        ffi::stbi_info_from_memory(
            bytes.as_ptr(),
            bytes.len() as c_int,
            &mut nx,
            &mut ny,
            &mut comp,
        )
    };
    if ok != 1 {
        return Err(image_err(format!(
            "'{path}' starts like a {format} file but its image header could not \
             be parsed — the file is likely truncated or corrupt. Re-export the \
             image and try again."
        )));
    }

    // Stage 4 — dimension and pixel caps, in u64 so no product can wrap. A
    // negative BMP height is the format's top-down row convention, not a
    // degenerate size: stb's own decoder takes its absolute value
    // (stb_image.h L5545-5546), so the caps apply to the magnitude — the
    // exact size a decode would materialize. Width has no such convention.
    let w_signed = nx as i64;
    let h_signed = (ny as i64).abs();
    if w_signed < 1 || h_signed < 1 {
        return Err(image_err(format!(
            "'{path}' reports a degenerate image size ({nx} x {ny} pixels); \
             every dimension must be at least 1."
        )));
    }
    let (w, h) = (w_signed as u64, h_signed as u64);
    if w > IMAGE_MAX_DIM || h > IMAGE_MAX_DIM {
        return Err(image_err(format!(
            "'{path}' is {w} x {h} pixels; the maximum supported dimension is \
             {IMAGE_MAX_DIM}. Downscale the image and try again."
        )));
    }
    if w * h > IMAGE_MAX_PIXELS {
        return Err(image_err(format!(
            "'{path}' is {w} x {h} = {} pixels, over the {IMAGE_MAX_PIXELS}-pixel \
             cap. Downscale the image and try again.",
            w * h
        )));
    }

    Ok(format)
}

/// Read an image file ONCE and run the full pre-decode gate on the bytes that
/// will be passed onward (the audit req-2 same-buffer contract). The read
/// itself is CAP-BOUNDED (`Read::take(cap + 1)`, the auditor's F1 hardening):
/// even a file that grows after the metadata pre-check can never buffer more
/// than `cap + 1` bytes — the `+ 1` makes an over-cap file detectable by the
/// authoritative length check on the bytes actually read, which stays inside
/// [`validate_image_bytes`].
pub(crate) fn read_and_validate_image(path: &str, max_bytes: u64) -> Result<Vec<u8>, RebirthError> {
    use std::io::Read;

    let image_err = |reason: String| RebirthError::Image {
        reason,
        path: Some(path.to_string()),
        expected: None,
        actual: None,
    };

    let cap = max_bytes.min(IMAGE_HARD_MAX_BYTES);
    let file = std::fs::File::open(Path::new(path))
        .map_err(|e| image_err(format!("could not read the image file '{path}': {e}.")))?;
    // Metadata from the OPEN handle (no path re-resolution): the fast-path
    // reject for an over-cap file, before any bytes are buffered.
    let meta = file
        .metadata()
        .map_err(|e| image_err(format!("could not read the image file '{path}': {e}.")))?;
    if !meta.is_file() {
        return Err(image_err(format!(
            "'{path}' is not a regular file, so it cannot be read as an image."
        )));
    }
    if meta.len() > cap {
        // Same wording as the buffer-level check in validate_image_bytes, so
        // callers see one message for one condition regardless of which of the
        // two checks (pre-read metadata / authoritative buffer) fired.
        return Err(image_err(format!(
            "'{path}' is {} bytes, over the {cap} image byte cap. If this is a \
             legitimate image, raise options(relm.image_max_bytes = ) — the hard \
             ceiling is {IMAGE_HARD_MAX_BYTES} bytes.",
            meta.len()
        )));
    }

    let mut bytes = Vec::new();
    file.take(cap.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|e| image_err(format!("could not read the image file '{path}': {e}.")))?;
    validate_image_bytes(path, &bytes, max_bytes)?;
    Ok(bytes)
}

/// Run the read + full pre-decode gate on `path` with NO model and NO decode:
/// the model-free seam the R selftest boundary exposes so the per-commit CI
/// suite can assert every classed rejection (audit req 4) from the R side.
/// Returns the detected format name on success.
pub fn validate_image_file(path: &str, max_bytes: u64) -> Result<&'static str, RebirthError> {
    let bytes = read_and_validate_image(path, max_bytes)?;
    // Re-derive the (already-validated) format for the caller; the two calls
    // see the same buffer, so this cannot disagree with the gate above.
    Ok(detect_image_format(&bytes).expect("validated bytes carry an allow-listed magic"))
}

// --- mtmd error-log capture --------------------------------------------------

// libmtmd reports its failure reasons only through its log callback (e.g. the
// projector/model n_embd mismatch, mtmd.cpp L372-376, surfaces as an ERROR line
// after `mtmd_init_from_file` catches the exception at L798-803 and returns
// NULL). A process-global capture buffer keeps the last ERROR text so it can be
// carried on the classed R condition instead of sprayed on the console.
// INFO/WARN chatter is dropped (mirroring engine.rs `quiet_log`). Access is
// mutex-guarded and the buffer capped, so a hostile file cannot grow it.
static MTMD_LOG: Mutex<String> = Mutex::new(String::new());
static MTMD_LOG_INSTALL: Once = Once::new();
const MTMD_LOG_CAP_BYTES: usize = 8 * 1024;

extern "C" fn mtmd_capture_log(level: c_int, text: *const c_char, _user_data: *mut c_void) {
    const GGML_LOG_LEVEL_ERROR: c_int = 4;
    if level != GGML_LOG_LEVEL_ERROR || text.is_null() {
        return;
    }
    // SAFETY: `text` is a non-null, NUL-terminated engine string.
    let msg = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    let mut buf = MTMD_LOG.lock().unwrap_or_else(PoisonError::into_inner);
    if buf.len() < MTMD_LOG_CAP_BYTES {
        buf.push_str(&msg);
    }
}

/// Install the capturing mtmd log filter exactly once (process-global, like
/// the llama-side `quiet_log`).
fn install_mtmd_log() {
    MTMD_LOG_INSTALL.call_once(|| {
        // SAFETY: installs a static extern "C" callback; no R involvement.
        unsafe { ffi::mtmd_log_set(Some(mtmd_capture_log), std::ptr::null_mut()) };
    });
}

/// Take and clear the captured ERROR text (trimmed). Called before an mtmd FFI
/// call to reset the buffer, and after a failure to read its reason.
fn drain_mtmd_log() -> String {
    let mut buf = MTMD_LOG.lock().unwrap_or_else(PoisonError::into_inner);
    std::mem::take(&mut *buf).trim().to_string()
}

/// Parse the engine's own mmproj-model mismatch message into the two sizes.
/// The format string is pinned at the vendored tag (mtmd.cpp L372-376):
/// `"mismatch between text model (n_embd = %d) and mmproj (n_embd = %d)\n..."`.
/// Re-validate on every `vendor-bump` (the unit test below pins the literal).
fn parse_embd_mismatch(log: &str) -> Option<(i32, i32)> {
    const TEXT_KEY: &str = "mismatch between text model (n_embd = ";
    const CLIP_KEY: &str = ") and mmproj (n_embd = ";
    let start = log.find(TEXT_KEY)? + TEXT_KEY.len();
    let rest = &log[start..];
    let mid = rest.find(CLIP_KEY)?;
    let text_embd: i32 = rest[..mid].trim().parse().ok()?;
    let after = &rest[mid + CLIP_KEY.len()..];
    let end = after.find(')')?;
    let clip_embd: i32 = after[..end].trim().parse().ok()?;
    Some((text_embd, clip_embd))
}

// --- projector lifecycle -----------------------------------------------------

/// An owned mtmd (vision-encoder) context bound to a loaded model. It lives on
/// the shared `Model` (engine.rs), so every handle derived from the same
/// weights — including an intervened handle's fresh llama context — shares one
/// projector, and it is freed (before the model, in `Model::drop`) only when
/// the last handle is gone.
pub(crate) struct VisionContext {
    ptr: NonNull<ffi::mtmd_context>,
    /// The R main thread the context was created on (D-008 G2 confinement).
    owner: ThreadId,
}

impl VisionContext {
    pub(crate) fn as_ptr(&self) -> *mut ffi::mtmd_context {
        assert_r_main_thread(self.owner, "VisionContext::as_ptr");
        self.ptr.as_ptr()
    }
}

impl Drop for VisionContext {
    fn drop(&mut self) {
        assert_r_main_thread(self.owner, "VisionContext::drop");
        // SAFETY: `ptr` came from `mtmd_init_from_file` and is freed exactly
        // once, before the model it references (Model::drop takes the vision
        // context first).
        unsafe { ffi::mtmd_free(self.ptr.as_ptr()) };
    }
}

/// Load an mmproj GGUF and bind its vision encoder to the loaded model
/// (`llm(projector=)`, grammar §3). The mmproj is engine-trusted input (audit
/// req 5, the same trust class as the main GGUF — a hostile projector file can
/// hit uncatchable asserts in the clip loader); provenance is the registry's
/// SHA256 pin or the user's own responsibility, documented on `llm()`.
///
/// A NULL return is upstream's reject (every constructor failure, including
/// its own embd-size check against `llama_model_n_embd_inp`, mtmd.cpp
/// L370-376) and maps to a classed image error; the mismatch case names both
/// sizes (reject-not-clamp), parsed from the engine's own message since the C
/// API exposes no projector-side dim getter (see the ffi.rs note).
pub(crate) fn load_projector(
    model_ptr: *const ffi::llama_model,
    mmproj: &Path,
    use_gpu: bool,
) -> Result<VisionContext, RebirthError> {
    let path_display = mmproj.display().to_string();
    let image_err =
        |reason: String, expected: Option<i32>, actual: Option<i32>| RebirthError::Image {
            reason,
            path: Some(path_display.clone()),
            expected,
            actual,
        };

    let path_str = mmproj.to_str().ok_or_else(|| {
        image_err(
            format!("the projector path '{path_display}' is not valid UTF-8."),
            None,
            None,
        )
    })?;
    let c_path = CString::new(path_str).map_err(|_| {
        image_err(
            format!("the projector path '{path_display}' contains a NUL byte."),
            None,
            None,
        )
    })?;

    install_mtmd_log();
    drain_mtmd_log();

    // The load runs in (up to) two stages, both with `cb_eval` left at its
    // NULL default (audit req 7: no vision-tower tracing, T3 out of scope):
    //
    // 1. A CPU PROBE (`use_gpu = false`, `warmup = false`). At the vendored
    //    tag, every mtmd-constructor validation that fires AFTER the clip
    //    weights are loaded — the embd-size mismatch (mtmd.cpp L370-376), the
    //    unsupported-projector checks — throws out of the constructor, which
    //    never runs the destructor, so the raw `ctx_v` clip context LEAKS
    //    (upstream bug). On a GPU backend the leaked Metal buffers keep
    //    residency sets alive and `GGML_ASSERT([rsets->data count] == 0)`
    //    (ggml-metal-device.m:622) ABORTS the R session at process exit.
    //    Probing on CPU turns any such leak into plain heap memory on an
    //    error path — no residency sets, no abort — at zero patch cost.
    // 2. The REAL context on the handle backend. It only runs on an mmproj
    //    that already passed every constructor check, so the remaining
    //    failure mode is clip_init returning NULL (e.g. backend OOM), which
    //    throws with `ctx_v` still null — nothing leaks. (The projector path
    //    is engine-trusted input, req 5: a file swapped between the two
    //    stages is outside the threat model, like the model GGUF itself.)

    // SAFETY: default params are a plain by-value C struct we only tweak; the
    // ffi.rs ABI test pins every field's offset and default.
    let mut probe_params = unsafe { ffi::mtmd_context_params_default() };
    probe_params.use_gpu = false;
    probe_params.print_timings = false;
    probe_params.warmup = false;
    debug_assert!(
        probe_params.cb_eval.is_null(),
        "cb_eval must stay NULL (req 7)"
    );

    // SAFETY: `c_path` outlives the call; `model_ptr` is the caller's live
    // model; the params match the C layout (ABI-pinned). A NULL return means
    // the exception was caught internally (mtmd.cpp L798-803) and logged.
    let probe = unsafe { ffi::mtmd_init_from_file(c_path.as_ptr(), model_ptr, probe_params) };
    let Some(probe_ptr) = NonNull::new(probe) else {
        let engine_reason = drain_mtmd_log();
        // SAFETY: `model_ptr` is a live model; read-only scalar getter.
        let n_embd_inp = unsafe { ffi::llama_model_n_embd_inp(model_ptr) };
        if let Some((text_embd, clip_embd)) = parse_embd_mismatch(&engine_reason) {
            return Err(image_err(
                format!(
                    "The projector '{path_display}' does not match this model: the \
                     model expects input embeddings of width {text_embd}, but the \
                     projector produces width {clip_embd}. Use the mmproj file \
                     published for this exact model."
                ),
                Some(text_embd),
                Some(clip_embd),
            ));
        }
        let detail = if engine_reason.is_empty() {
            String::from("no engine detail available")
        } else {
            engine_reason
        };
        return Err(image_err(
            format!(
                "Failed to load the projector '{path_display}' ({detail}). The file \
                 may be missing, corrupt, or not an mmproj GGUF for a supported \
                 vision architecture; this model expects input embeddings of width \
                 {n_embd_inp}."
            ),
            None,
            None,
        ));
    };

    let vision = if use_gpu {
        // NOTE for the vendor-bump maintainer: a GPU-backend load parses the
        // mmproj TWICE (the CPU probe above + the real init below) — the cost
        // of keeping the constructor-leak abort unreachable with zero patch.
        // Free the CPU probe before the real init so the mmproj weights are
        // never resident twice.
        // SAFETY: `probe_ptr` is the live context just created; freed once.
        unsafe { ffi::mtmd_free(probe_ptr.as_ptr()) };

        // SAFETY: as above; the GPU context is the one the handle keeps.
        let mut params = unsafe { ffi::mtmd_context_params_default() };
        params.use_gpu = true;
        params.print_timings = false;
        debug_assert!(params.cb_eval.is_null(), "cb_eval must stay NULL (req 7)");
        drain_mtmd_log();
        // SAFETY: same contract as the probe call.
        let ctx = unsafe { ffi::mtmd_init_from_file(c_path.as_ptr(), model_ptr, params) };
        let Some(ptr) = NonNull::new(ctx) else {
            let engine_reason = drain_mtmd_log();
            let detail = if engine_reason.is_empty() {
                String::from("no engine detail available")
            } else {
                engine_reason
            };
            return Err(image_err(
                format!(
                    "Failed to initialize the projector '{path_display}' on the GPU \
                     backend ({detail}). There may not be enough memory; free other \
                     loaded models first, or load with backend = \"cpu\"."
                ),
                None,
                None,
            ));
        };
        VisionContext {
            ptr,
            owner: std::thread::current().id(),
        }
    } else {
        // The kept CPU-backend context IS the probe, created with
        // `warmup = false` — a perf-only difference (no dummy warmup encode;
        // the first real encode pays the graph build instead). Results are
        // identical.
        VisionContext {
            ptr: probe_ptr,
            owner: std::thread::current().id(),
        }
    };

    // SAFETY: `ptr` is the live context just created.
    if !unsafe { ffi::mtmd_support_vision(vision.as_ptr()) } {
        // `vision` drops here, freeing the context.
        return Err(image_err(
            format!(
                "The projector '{path_display}' loaded but provides no vision \
                 encoder (an audio-only mmproj?), so it cannot take image input."
            ),
            None,
            None,
        ));
    }

    Ok(vision)
}

// --- RAII wrappers for the ingest --------------------------------------------

/// An owned decoded bitmap (`mtmd_bitmap`), freed on drop. Created ONLY by
/// `mtmd_helper_bitmap_init_from_buf` on a gated buffer (audit reqs 2/6: the
/// raw `mtmd_bitmap_init` entry point is not even declared).
struct Bitmap {
    ptr: NonNull<ffi::mtmd_bitmap>,
}

impl Drop for Bitmap {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from the decode helper and is freed exactly once.
        unsafe { ffi::mtmd_bitmap_free(self.ptr.as_ptr()) };
    }
}

/// An owned chunk list (`mtmd_input_chunks`), freed on drop.
struct Chunks {
    ptr: NonNull<ffi::mtmd_input_chunks>,
}

impl Chunks {
    fn new() -> Result<Chunks, RebirthError> {
        // SAFETY: plain constructor; freed in Drop.
        let ptr = unsafe { ffi::mtmd_input_chunks_init() };
        NonNull::new(ptr)
            .map(|ptr| Chunks { ptr })
            .ok_or_else(|| RebirthError::Internal {
                context: "mtmd_input_chunks_init returned NULL".to_string(),
            })
    }

    fn as_ptr(&self) -> *mut ffi::mtmd_input_chunks {
        self.ptr.as_ptr()
    }

    /// The combined text+image token count (KV-cache slots) across all chunks,
    /// checked against the context window before any decode.
    fn total_tokens(&self) -> usize {
        // SAFETY: `ptr` is a live chunk list; per-chunk pointers are owned by
        // it and valid while it lives.
        unsafe {
            let n = ffi::mtmd_input_chunks_size(self.ptr.as_ptr());
            (0..n)
                .map(|i| {
                    let chunk = ffi::mtmd_input_chunks_get(self.ptr.as_ptr(), i);
                    if chunk.is_null() {
                        0
                    } else {
                        ffi::mtmd_input_chunk_get_n_tokens(chunk)
                    }
                })
                .sum()
        }
    }
}

impl Drop for Chunks {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from `mtmd_input_chunks_init`; freed exactly once.
        unsafe { ffi::mtmd_input_chunks_free(self.ptr.as_ptr()) };
    }
}

/// The engine's media marker (`"<__media__>"`), one per image, inserted BEFORE
/// the prompt text (grammar: images-before-text; interleaved-marker control is
/// a reserved later capability). The fallback literal equals the default the
/// ffi.rs ABI test pins against `mtmd_default_marker()`.
fn default_marker() -> String {
    // SAFETY: returns a static engine-owned NUL-terminated string.
    let ptr = unsafe { ffi::mtmd_default_marker() };
    if ptr.is_null() {
        return "<__media__>".to_string();
    }
    // SAFETY: non-null, NUL-terminated, static.
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

// --- the T1 ingest ------------------------------------------------------------

impl LoadedModel {
    /// Generate a continuation of a text `prompt` with `images` (file paths)
    /// inserted before it — `llm_generate(images=)` for one prompt. The gated
    /// image bytes are decoded to bitmaps, the marker-bearing prompt is
    /// tokenized into text/image chunks, the combined token count is checked
    /// against the context window, the chunks are ingested through upstream's
    /// n_batch-aware `mtmd_helper_eval_chunks`, and generation continues with
    /// the EXISTING sampler loop from the position the helper reports. With no
    /// images this delegates to the plain text path unchanged.
    pub fn generate_prompt_with_images(
        &self,
        prompt: &str,
        chat: bool,
        images: &[String],
        image_max_bytes: u64,
        params: &GenerateParams,
    ) -> Result<Generation, RebirthError> {
        if images.is_empty() {
            // Text-only: byte-identical behavior, zero mtmd involvement.
            return self.generate_prompt(prompt, chat, params);
        }
        self.require_tokenizer()?;
        let Some(mctx) = self.vision_ptr() else {
            return Err(RebirthError::Image {
                reason: "This model was loaded without a projector, so it cannot \
                         take image input. Reload it with llm(path, projector = \
                         <mmproj GGUF>) to enable images."
                    .to_string(),
                path: None,
                expected: None,
                actual: None,
            });
        };
        if params.max_tokens == 0 {
            return Ok(Generation {
                tokens: Vec::new(),
                text: String::new(),
                stop_reason: crate::generate::StopReason::MaxTokens,
                seed: params.seed,
            });
        }

        install_mtmd_log();

        // 1. Read + gate each file once, decode the SAME buffer (reqs 1-3).
        let mut bitmaps: Vec<Bitmap> = Vec::with_capacity(images.len());
        for path in images {
            let bytes = read_and_validate_image(path, image_max_bytes)?;
            drain_mtmd_log();
            // SAFETY: `mctx` is the live vision context; `bytes` is the gated
            // buffer, borrowed only for the call (the helper copies what it
            // keeps). `placeholder = false` decodes for real.
            let wrapper = unsafe {
                ffi::mtmd_helper_bitmap_init_from_buf(mctx, bytes.as_ptr(), bytes.len(), false)
            };
            // MTMD_VIDEO=OFF: the only branch that sets video_ctx is compiled out.
            debug_assert!(wrapper.video_ctx.is_null());
            let ptr = NonNull::new(wrapper.bitmap).ok_or_else(|| {
                let engine_reason = drain_mtmd_log();
                let detail = if engine_reason.is_empty() {
                    String::from("no engine detail available")
                } else {
                    engine_reason
                };
                RebirthError::Image {
                    reason: format!(
                        "'{path}' passed the format gate but could not be decoded \
                         ({detail}). The file is likely corrupt; re-export the \
                         image and try again."
                    ),
                    path: Some(path.clone()),
                    expected: None,
                    actual: None,
                }
            })?;
            bitmaps.push(Bitmap { ptr });
        }

        // 2. One marker per image BEFORE the text, then the usual chat
        //    templating — identical to the text path's resolution.
        let marker = default_marker();
        // The literal media marker is reserved in an image-bearing prompt:
        // mtmd_tokenize splits the text on every occurrence and requires the
        // marker count to equal the bitmap count, so a user-supplied marker
        // would either mis-place an image or fail the count check. The R layer
        // rejects this before the boundary (relm_error_argument on `prompt`);
        // this engine-side backstop keeps the crate safe for non-R callers
        // (unreachable through the R surface, hence exercised by no R test).
        if prompt.contains(marker.as_str()) {
            return Err(RebirthError::Image {
                reason: format!(
                    "the prompt contains the reserved media marker '{marker}'. On a \
                     call with images, the engine inserts one marker per image; a \
                     literal marker in the text would corrupt the image placement. \
                     Remove it from the prompt."
                ),
                path: None,
                expected: None,
                actual: None,
            });
        }
        let mut content = marker.repeat(images.len());
        content.push_str(prompt);
        let (text, add_special, parse_special) = self.resolve_prompt_text(&content, chat)?;
        let c_text = CString::new(text).map_err(|_| RebirthError::Generation {
            reason: "the prompt contains an interior NUL byte".to_string(),
        })?;
        let input = ffi::mtmd_input_text {
            text: c_text.as_ptr(),
            add_special,
            parse_special,
        };

        // 3. Tokenize into interleaved text/image chunks.
        let chunks = Chunks::new()?;
        let bitmap_ptrs: Vec<*const ffi::mtmd_bitmap> = bitmaps
            .iter()
            .map(|b| b.ptr.as_ptr() as *const ffi::mtmd_bitmap)
            .collect();
        drain_mtmd_log();
        // SAFETY: every pointer is live for the call: `mctx` and the chunk
        // list are owned above, `input.text` borrows `c_text`, and the bitmap
        // array borrows `bitmaps` (all dropped after).
        let ret = unsafe {
            ffi::mtmd_tokenize(
                mctx,
                chunks.as_ptr(),
                &input,
                bitmap_ptrs.as_ptr(),
                bitmap_ptrs.len(),
            )
        };
        match ret {
            0 => {}
            // Return 1 = marker/bitmap count mismatch. The engine authors
            // exactly one marker per bitmap AND rejects a user-supplied marker
            // above, so this is a genuine internal invariant break.
            1 => {
                return Err(RebirthError::Internal {
                    context: "mtmd_tokenize reported a marker/bitmap count mismatch; \
                              the engine authors exactly one marker per image and \
                              rejects user-supplied markers before tokenizing"
                        .to_string(),
                })
            }
            _ => {
                let engine_reason = drain_mtmd_log();
                let detail = if engine_reason.is_empty() {
                    String::from("no engine detail available")
                } else {
                    engine_reason
                };
                return Err(RebirthError::Image {
                    reason: format!(
                        "Image preprocessing failed ({detail}). The image may use \
                         an aspect ratio or size this model's preprocessor cannot \
                         handle; try a different image."
                    ),
                    path: None,
                    expected: None,
                    actual: None,
                });
            }
        }

        // The tokenizer preprocessed the bitmaps into the chunks' own storage;
        // free the decoded RGB buffers now (grammar rule 6: image buffers are
        // one-shot, freed right after ingest, never a growing capture).
        drop(bitmaps);

        // 4. Combined text+image token count vs the context window: the
        //    existing classed overflow (its message states by how much).
        self.check_fits(chunks.total_tokens())?;

        // 5. Fresh pass, then the upstream interleaved ingest, chunked by this
        //    context's n_batch (hard rule 8a) with only the final token
        //    requesting logits.
        let n_vocab = self.n_vocab_checked()?;
        self.clear_memory();
        let mut new_n_past: ffi::llama_pos = 0;
        drain_mtmd_log();
        // SAFETY: `mctx`/`ctx_ptr` are live; `chunks` outlives the call;
        // `new_n_past` is a valid out-pointer.
        let status = unsafe {
            ffi::mtmd_helper_eval_chunks(
                mctx,
                self.ctx_ptr(),
                chunks.as_ptr(),
                0,
                0,
                (self.n_batch().max(1)) as i32,
                true,
                &mut new_n_past,
            )
        };
        if status != 0 {
            let engine_reason = drain_mtmd_log();
            let detail = if engine_reason.is_empty() {
                String::from("no engine detail available")
            } else {
                engine_reason
            };
            return Err(RebirthError::Generation {
                reason: format!("multimodal ingest failed (status {status}: {detail})"),
            });
        }

        // 6. The last flagged output row is the whole-prompt next-token
        //    distribution (llama.h L1025: -1 = the last logits); continue with
        //    the EXISTING sampler loop from the helper-reported position
        //    (M-RoPE models advance positions differently from token counts,
        //    which is exactly why new_n_past comes from the helper).
        let logits = self.logits_ith(-1, n_vocab)?;
        self.continue_generation(logits, new_n_past, params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // All tests here are model-free and run per-commit in CI (`cargo test
    // -p rebirth-llm`, rust.yaml) — hard rule 8e.

    /// A minimal PNG prefix `stbi_info_from_memory` accepts: signature + IHDR
    /// carrying the given dimensions + an IDAT chunk header (stb's header scan
    /// keeps reading chunks after IHDR — looking for tRNS — and reports success
    /// at the first IDAT; CRCs are not verified for info). Lets the tests probe
    /// the dimension caps without committing binary fixtures.
    fn png_header(width: u32, height: u32) -> Vec<u8> {
        let mut v = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        v.extend_from_slice(&13u32.to_be_bytes()); // IHDR length
        v.extend_from_slice(b"IHDR");
        v.extend_from_slice(&width.to_be_bytes());
        v.extend_from_slice(&height.to_be_bytes());
        // bit depth 8, color type 2 (RGB), compression 0, filter 0, interlace 0
        v.extend_from_slice(&[8, 2, 0, 0, 0]);
        v.extend_from_slice(&[0, 0, 0, 0]); // IHDR CRC (not checked for info)
        v.extend_from_slice(&0u32.to_be_bytes()); // IDAT length
        v.extend_from_slice(b"IDAT");
        v
    }

    #[test]
    fn magic_allow_list_accepts_exactly_jpeg_png_bmp() {
        assert_eq!(detect_image_format(&png_header(4, 4)), Some("png"));
        assert_eq!(detect_image_format(&[0xFF, 0xD8, 0xFF, 0xE0]), Some("jpeg"));
        assert_eq!(detect_image_format(b"BM\x00\x00"), Some("bmp"));
    }

    #[test]
    fn magic_allow_list_rejects_gif_audio_and_garbage() {
        // GIF is DROPPED (audit section 2b): both full magics must be rejected.
        assert_eq!(detect_image_format(b"GIF87a...."), None);
        assert_eq!(detect_image_format(b"GIF89a...."), None);
        // Audio magics (the miniaudio-gate mutation proof, audit req 4): none
        // may pass — the loose upstream sniff (RIFF/WAVE, MPEG sync 0xFF 0xE0+,
        // fLaC, ID3) must be unreachable through this allow-list.
        assert_eq!(detect_image_format(b"RIFF\x24\x00\x00\x00WAVEfmt "), None);
        assert_eq!(detect_image_format(&[0xFF, 0xFB, 0x90, 0x00]), None); // MP3 sync
        assert_eq!(detect_image_format(&[0xFF, 0xE0, 0x00, 0x00]), None); // loosest MPEG sync
        assert_eq!(detect_image_format(b"fLaC\x00\x00\x00\x22"), None);
        assert_eq!(
            detect_image_format(b"ID3\x04\x00\x00\x00\x00\x00\x00"),
            None
        );
        // Garbage, the empty buffer, and short prefixes of valid magics.
        assert_eq!(detect_image_format(b"not an image at all"), None);
        assert_eq!(detect_image_format(&[]), None);
        assert_eq!(detect_image_format(&[0xFF, 0xD8]), None); // JPEG needs 3 bytes
        assert_eq!(detect_image_format(&[0x89, 0x50, 0x4E, 0x47]), None); // PNG needs 8
    }

    #[test]
    fn validate_rejects_disallowed_formats_at_stage_one() {
        // The stage-1 message is the mutation proof: a WAV buffer must fail on
        // the MAGIC stage (naming the allowed formats), proving rejection
        // happens before the header probe / any decode.
        for bytes in [
            b"RIFF\x24\x00\x00\x00WAVEfmt ".as_slice(),
            b"GIF89a\x01\x00\x01\x00".as_slice(),
            &[0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00],
            b"fLaC\x00\x00\x00\x22\x00\x00".as_slice(),
        ] {
            let err = validate_image_bytes("x.bin", bytes, u64::MAX)
                .expect_err("disallowed format must be rejected");
            match &err {
                RebirthError::Image { reason, path, .. } => {
                    assert!(
                        reason.contains("magic bytes match none of the allowed formats"),
                        "stage-1 reason expected, got: {reason}"
                    );
                    assert!(
                        reason.contains("JPEG, PNG, BMP"),
                        "the three allowed formats must be named: {reason}"
                    );
                    assert_eq!(path.as_deref(), Some("x.bin"));
                }
                other => panic!("expected Image error, got {other:?}"),
            }
        }
    }

    #[test]
    fn validate_enforces_the_byte_cap_after_the_magic_gate() {
        // A well-formed PNG over a tiny cap fails on the BYTE-CAP stage.
        let bytes = png_header(4, 4);
        let err = validate_image_bytes("big.png", &bytes, 8).expect_err("over the byte cap");
        match &err {
            RebirthError::Image { reason, .. } => {
                assert!(reason.contains("byte cap"), "cap reason: {reason}");
                assert!(
                    reason.contains("relm.image_max_bytes"),
                    "the override must be named: {reason}"
                );
            }
            other => panic!("expected Image error, got {other:?}"),
        }
    }

    #[test]
    fn validate_rejects_a_truncated_header_of_an_allowed_format() {
        // Valid JPEG magic, nothing else: stbi_info must fail -> stage-3 reason.
        let err = validate_image_bytes("t.jpg", &[0xFF, 0xD8, 0xFF], u64::MAX)
            .expect_err("truncated header");
        match &err {
            RebirthError::Image { reason, .. } => {
                assert!(
                    reason.contains("header could not be parsed"),
                    "header-probe reason: {reason}"
                );
            }
            other => panic!("expected Image error, got {other:?}"),
        }
    }

    #[test]
    fn validate_enforces_the_dimension_and_pixel_caps_in_u64() {
        // Over one dimension: 100_000 x 4.
        let err = validate_image_bytes("wide.png", &png_header(100_000, 4), u64::MAX)
            .expect_err("over-dim image");
        match &err {
            RebirthError::Image { reason, .. } => {
                assert!(
                    reason.contains("maximum supported dimension"),
                    "dim reason: {reason}"
                );
            }
            other => panic!("expected Image error, got {other:?}"),
        }
        // Each dimension within the 16384 cap but the PRODUCT over the pixel
        // cap: 16000 x 16000 = 256 Mpx (the u64 product can never wrap).
        let err = validate_image_bytes("huge.png", &png_header(16_000, 16_000), u64::MAX)
            .expect_err("over-pixel image");
        match &err {
            RebirthError::Image { reason, .. } => {
                assert!(reason.contains("pixel"), "pixel-cap reason: {reason}");
            }
            other => panic!("expected Image error, got {other:?}"),
        }
        // Degenerate zero dimension reported by the header.
        let err = validate_image_bytes("zero.png", &png_header(0, 4), u64::MAX)
            .expect_err("zero-dim image");
        match &err {
            RebirthError::Image { reason, .. } => {
                // stbi itself rejects a 0-dim PNG header, so either the
                // header-probe or the degenerate-size stage may fire; both are
                // classed rejections before any decode.
                assert!(
                    reason.contains("degenerate") || reason.contains("header could not be parsed"),
                    "zero-dim reason: {reason}"
                );
            }
            other => panic!("expected Image error, got {other:?}"),
        }
        // Boundary acceptance: 16384 x 1 and 1 x 16384 pass the gate (the
        // audit req-4 degenerate-but-legal shapes are gated MODEL-side, not
        // rejected here).
        assert_eq!(
            validate_image_bytes("thin.png", &png_header(16_384, 1), u64::MAX).unwrap(),
            "png"
        );
        assert_eq!(
            validate_image_bytes("tall.png", &png_header(1, 16_384), u64::MAX).unwrap(),
            "png"
        );
    }

    /// A minimal BMP prefix (`BM` + BITMAPINFOHEADER) with a signed height:
    /// negative = the top-down row convention stb's decoder folds with abs()
    /// (stb_image.h L5545-5546). Enough for `stbi_info_from_memory`.
    fn bmp_header(width: i32, height: i32) -> Vec<u8> {
        let mut v = vec![0x42, 0x4D]; // "BM"
        v.extend_from_slice(&54u32.to_le_bytes()); // file size (unchecked)
        v.extend_from_slice(&0u32.to_le_bytes()); // reserved
        v.extend_from_slice(&54u32.to_le_bytes()); // pixel-data offset
        v.extend_from_slice(&40u32.to_le_bytes()); // BITMAPINFOHEADER size
        v.extend_from_slice(&width.to_le_bytes());
        v.extend_from_slice(&height.to_le_bytes());
        v.extend_from_slice(&1u16.to_le_bytes()); // planes
        v.extend_from_slice(&24u16.to_le_bytes()); // bits per pixel
        v.extend_from_slice(&0u32.to_le_bytes()); // compression = BI_RGB
        v.extend_from_slice(&[0u8; 20]); // rest of the 40-byte header
        v
    }

    #[test]
    fn a_top_down_bmp_negative_height_is_the_format_convention_not_degenerate() {
        // grDevices::bmp() (and many writers) emit top-down BMPs with a
        // negative height; the gate must apply the caps to the magnitude,
        // exactly like stb's decoder, instead of rejecting the file.
        assert_eq!(
            validate_image_bytes("td.bmp", &bmp_header(64, -64), u64::MAX).unwrap(),
            "bmp"
        );
        // The caps still bind on the magnitude…
        let err = validate_image_bytes("td-big.bmp", &bmp_header(64, -100_000), u64::MAX)
            .expect_err("over-dim magnitude");
        match &err {
            RebirthError::Image { reason, .. } => {
                assert!(reason.contains("maximum supported dimension"), "{reason}");
            }
            other => panic!("expected Image error, got {other:?}"),
        }
        // …and a genuinely degenerate width is still rejected.
        let err =
            validate_image_bytes("bad.bmp", &bmp_header(0, 64), u64::MAX).expect_err("zero width");
        match &err {
            RebirthError::Image { reason, .. } => {
                assert!(
                    reason.contains("degenerate") || reason.contains("header could not be parsed"),
                    "{reason}"
                );
            }
            other => panic!("expected Image error, got {other:?}"),
        }
    }

    #[test]
    fn read_and_validate_maps_a_missing_file_to_a_classed_image_error() {
        let err = read_and_validate_image("/nonexistent/definitely/not.png", u64::MAX)
            .expect_err("missing file");
        match &err {
            RebirthError::Image { reason, path, .. } => {
                assert!(reason.contains("could not read"), "io reason: {reason}");
                assert_eq!(path.as_deref(), Some("/nonexistent/definitely/not.png"));
            }
            other => panic!("expected Image error, got {other:?}"),
        }
    }

    #[test]
    fn embd_mismatch_parse_pins_the_upstream_format_string() {
        // The literal produced by mtmd.cpp L372-376 at b9726 (vendor-bump
        // checklist: re-verify this format string on every bump).
        let log = "mtmd_init_from_file: error: mismatch between text model \
                   (n_embd = 896) and mmproj (n_embd = 1536)\n\
                   hint: you may be using wrong mmproj\n";
        assert_eq!(parse_embd_mismatch(log), Some((896, 1536)));
        // Robustness: an unrelated error parses to None (the generic classed
        // load failure is raised instead — never a fabricated mismatch).
        assert_eq!(parse_embd_mismatch("failed to open file"), None);
        assert_eq!(parse_embd_mismatch(""), None);
    }

    #[test]
    fn hard_byte_ceiling_is_the_stb_int_limit() {
        // F6: the decode helper narrows the length to a C int; the ceiling must
        // make that narrowing lossless by construction.
        assert_eq!(IMAGE_HARD_MAX_BYTES, 2_147_483_647);
        // The pre-decode caps documented in the R help (roxygen twin values).
        assert_eq!(IMAGE_MAX_DIM, 16_384);
        assert_eq!(IMAGE_MAX_PIXELS, 33_554_432);
    }
}
