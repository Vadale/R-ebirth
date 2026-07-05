//! Safe engine lifecycle: `Backend`, `Model`, `Context`, and the `load` entry.
//!
//! These wrappers own the raw llama.cpp handles and free them on `Drop`, so the
//! GC path (extendr's external-pointer finalizer) and the deterministic path
//! (`close.llm`) both reduce to dropping the owning value. The crate stays
//! R-free (ARCHITECTURE.md §2): everything here takes/returns plain Rust types.

use std::ffi::{c_void, CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::ptr::NonNull;
use std::sync::{Arc, Mutex, Once, PoisonError};

use crate::error::RebirthError;
use crate::ffi;

/// A concrete compute backend. `"auto"` is resolved to one of these in R before
/// the boundary; the engine never sees `"auto"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    Cpu,
    Metal,
    Cuda,
}

impl BackendKind {
    /// The R-facing lowercase name (`API-GRAMMAR.md` §3 `backend` values).
    pub fn as_str(self) -> &'static str {
        match self {
            BackendKind::Cpu => "cpu",
            BackendKind::Metal => "metal",
            BackendKind::Cuda => "cuda",
        }
    }

    /// Parse an R-facing backend name; `None` for anything but the three known
    /// concrete backends (`"auto"` is resolved in R and never reaches here).
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "cpu" => Some(BackendKind::Cpu),
            "metal" => Some(BackendKind::Metal),
            "cuda" => Some(BackendKind::Cuda),
            _ => None,
        }
    }

    /// Whether this build can actually run on this backend.
    fn is_available(self) -> bool {
        match self {
            // CPU is always present.
            BackendKind::Cpu => true,
            // Metal is built only on macOS arm64 (D-006); confirm at runtime too.
            BackendKind::Metal => {
                cfg!(all(target_os = "macos", target_arch = "aarch64"))
                    && crate::supports_gpu_offload()
            }
            // CUDA is gated behind the (default-off) `cuda` feature until Phase 8.
            BackendKind::Cuda => cfg!(feature = "cuda") && crate::supports_gpu_offload(),
        }
    }
}

/// The backends this build can use, in R-facing preference order (GPU first).
pub fn available_backends() -> Vec<BackendKind> {
    // Touch the backend so the ggml device registry is populated before the
    // capability queries in `is_available` run.
    let _guard = Backend::acquire();
    [BackendKind::Metal, BackendKind::Cuda, BackendKind::Cpu]
        .into_iter()
        .filter(|b| b.is_available())
        .collect()
}

// --- process-global backend, reference-counted -----------------------------

// llama.cpp's backend init/free is process-global. We reference-count it so
// several models share one init and it is torn down only once the last handle
// is gone (ARCHITECTURE.md §3). `Once` installs the quiet log filter exactly
// once so a corrupt-file load cannot spray llama.cpp INFO/WARN onto the R
// console (the actionable text is on the returned RebirthError instead).
static BACKEND_REFCOUNT: Mutex<usize> = Mutex::new(0);
static LOG_FILTER: Once = Once::new();

fn refcount() -> std::sync::MutexGuard<'static, usize> {
    // Poison-tolerant: a panic elsewhere must not turn every later lock into a
    // panic (which, in a Drop during unwinding, would abort the process).
    BACKEND_REFCOUNT
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

/// A quiet log filter: forward only ERROR-level engine messages to stderr, drop
/// the INFO/WARN chatter. Keeps normal loads and the corrupt-file error path
/// from flooding the R console.
extern "C" fn quiet_log(level: c_int, text: *const c_char, _user_data: *mut c_void) {
    const GGML_LOG_LEVEL_ERROR: c_int = 4;
    if level == GGML_LOG_LEVEL_ERROR && !text.is_null() {
        // SAFETY: `text` is a non-null, NUL-terminated engine string.
        let msg = unsafe { CStr::from_ptr(text) }.to_string_lossy();
        eprint!("{msg}");
    }
}

/// A live reference to the initialized process-global backend. Holding one keeps
/// llama.cpp initialized; dropping the last one tears it down.
pub struct Backend {
    _private: (),
}

impl Backend {
    /// Acquire a backend reference, initializing llama.cpp on the first one.
    pub fn acquire() -> Backend {
        let mut count = refcount();
        if *count == 0 {
            LOG_FILTER.call_once(|| {
                // SAFETY: installs a static extern "C" callback; no R involvement.
                unsafe { ffi::llama_log_set(Some(quiet_log), std::ptr::null_mut()) };
            });
            // SAFETY: no arguments; sets up global engine state.
            unsafe { ffi::llama_backend_init() };
        }
        *count += 1;
        Backend { _private: () }
    }
}

impl Clone for Backend {
    fn clone(&self) -> Self {
        Backend::acquire()
    }
}

impl Drop for Backend {
    fn drop(&mut self) {
        let mut count = refcount();
        *count = count.saturating_sub(1);
        if *count == 0 {
            // SAFETY: no arguments; tears down global engine state. Paired with
            // the init in `acquire`; only runs once the last reference is gone.
            unsafe { ffi::llama_backend_free() };
        }
    }
}

// --- model & context -------------------------------------------------------

/// An owned, loaded model. Holds a backend reference for its whole lifetime.
pub struct Model {
    ptr: NonNull<ffi::llama_model>,
    resolved_backend: BackendKind,
    _backend: Backend,
}

// The raw handle is only ever touched on the R main thread (ARCHITECTURE.md §3),
// but `Arc<Model>` requires `Send + Sync`. llama.cpp models are safe to share by
// const reference for the read-only metadata queries used here.
unsafe impl Send for Model {}
unsafe impl Sync for Model {}

impl Model {
    fn meta_str(&self, key: &str) -> Option<String> {
        let c_key = CString::new(key).ok()?;
        // First call with a zero-size buffer to learn the length.
        // SAFETY: `ptr` is a live model; a null/zero buffer only measures.
        let len = unsafe {
            ffi::llama_model_meta_val_str(
                self.ptr.as_ptr(),
                c_key.as_ptr(),
                std::ptr::null_mut(),
                0,
            )
        };
        if len < 0 {
            return None;
        }
        let mut buf = vec![0_u8; len as usize + 1];
        // SAFETY: buffer is `len + 1` bytes; the engine writes a NUL-terminated
        // string of at most `len` bytes plus the terminator.
        let written = unsafe {
            ffi::llama_model_meta_val_str(
                self.ptr.as_ptr(),
                c_key.as_ptr(),
                buf.as_mut_ptr().cast::<c_char>(),
                buf.len(),
            )
        };
        if written < 0 {
            return None;
        }
        buf.truncate(written as usize);
        String::from_utf8(buf).ok()
    }

    fn architecture(&self) -> String {
        self.meta_str("general.architecture")
            .unwrap_or_else(|| "unknown".to_string())
    }

    /// The canonical GGUF-style quantization name (e.g. `"Q4_K_M"`, `"Q8_0"`),
    /// derived from the `general.file_type` metadata value.
    fn quantization(&self) -> String {
        self.meta_str("general.file_type")
            .and_then(|s| s.trim().parse::<i32>().ok())
            .map(ftype_name)
            .unwrap_or_else(|| "unknown".to_string())
    }

    fn description(&self) -> String {
        let mut buf = vec![0_u8; 256];
        // SAFETY: `ptr` is a live model; buffer/len are consistent.
        let written = unsafe {
            ffi::llama_model_desc(
                self.ptr.as_ptr(),
                buf.as_mut_ptr().cast::<c_char>(),
                buf.len(),
            )
        };
        if written < 0 {
            return String::new();
        }
        // Cap at buf.len() - 1 so an over-long description never keeps snprintf's
        // trailing NUL (which would end up as an embedded '\0' in the String).
        buf.truncate((written as usize).min(buf.len() - 1));
        String::from_utf8_lossy(&buf).into_owned()
    }

    fn vocab_size(&self) -> i32 {
        // SAFETY: `ptr` is a live model; the vocab is owned by the model.
        let vocab = unsafe { ffi::llama_model_get_vocab(self.ptr.as_ptr()) };
        if vocab.is_null() {
            return 0;
        }
        // SAFETY: `vocab` is non-null and owned by the live model.
        unsafe { ffi::llama_vocab_n_tokens(vocab) }
    }
}

impl Drop for Model {
    fn drop(&mut self) {
        // SAFETY: `ptr` was produced by `llama_model_load_from_file` and is freed
        // exactly once (this owner is dropped once). Freed after every `Context`
        // that referenced it (contexts hold an `Arc<Model>`).
        unsafe { ffi::llama_model_free(self.ptr.as_ptr()) };
    }
}

/// An owned inference context, created from a `Model`. Frees before the model.
pub struct Context {
    ptr: NonNull<ffi::llama_context>,
    model: Arc<Model>,
    context_length: u32,
    gpu_layers: i32,
    mmap: bool,
}

unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Drop for Context {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from `llama_init_from_model`; freed exactly once and
        // before the `Arc<Model>` it borrows (dropped right after this).
        unsafe { ffi::llama_free(self.ptr.as_ptr()) };
    }
}

/// The R-facing bundle: a loaded model plus its active context. Dropping this
/// frees the context, then (if it was the last reference) the model, then (if it
/// was the last handle) the backend.
pub struct LoadedModel {
    ctx: Context,
}

/// A flat snapshot of the metadata the `llm` S3 object needs (`API-GRAMMAR.md`
/// §2 slots plus the extras `summary.llm` reports).
#[derive(Debug, Clone, PartialEq)]
pub struct ModelMetadata {
    pub architecture: String,
    pub parameters: u64,
    pub quantization: String,
    pub layers: i32,
    pub hidden_size: i32,
    pub context_length: u32,
    pub context_train: i32,
    pub backend: String,
    pub size_bytes: u64,
    pub vocab_size: i32,
    pub description: String,
    pub gpu_layers: i32,
    pub mmap: bool,
}

impl LoadedModel {
    /// Snapshot every metadata value the R layer stores in the handle.
    pub fn metadata(&self) -> ModelMetadata {
        let model = &self.ctx.model;
        // SAFETY: `model.ptr` is live for the whole call; these are read-only
        // scalar getters.
        let (parameters, layers, hidden_size, context_train, size_bytes) = unsafe {
            (
                ffi::llama_model_n_params(model.ptr.as_ptr()),
                ffi::llama_model_n_layer(model.ptr.as_ptr()),
                ffi::llama_model_n_embd(model.ptr.as_ptr()),
                ffi::llama_model_n_ctx_train(model.ptr.as_ptr()),
                ffi::llama_model_size(model.ptr.as_ptr()),
            )
        };
        ModelMetadata {
            architecture: model.architecture(),
            parameters,
            quantization: model.quantization(),
            layers,
            hidden_size,
            context_length: self.ctx.context_length,
            context_train,
            backend: model.resolved_backend.as_str().to_string(),
            size_bytes,
            vocab_size: model.vocab_size(),
            description: model.description(),
            gpu_layers: self.ctx.gpu_layers,
            mmap: self.ctx.mmap,
        }
    }

    // --- crate-internal accessors for the generation module (generate.rs) ---
    // The raw handles never leave the crate; `generate.rs` is the only other
    // caller and confines its own `unsafe` to the C-FFI calls (ARCHITECTURE.md
    // §2.2, D-009).

    /// The live context pointer (`llama_decode`/`llama_get_logits_ith` take
    /// `*mut`; the KV cache is mutated in place behind it).
    pub(crate) fn ctx_ptr(&self) -> *mut ffi::llama_context {
        self.ctx.ptr.as_ptr()
    }

    /// Vocabulary size (row count of the logit vector).
    pub(crate) fn n_vocab(&self) -> i32 {
        self.ctx.model.vocab_size()
    }

    /// The active context window in tokens (`n_ctx`).
    pub(crate) fn context_length(&self) -> u32 {
        self.ctx.context_length
    }
}

/// A fully-validated load request (all R-side defaulting already applied).
#[derive(Debug, Clone, PartialEq)]
pub struct LoadRequest {
    pub path: PathBuf,
    pub context_length: u32,
    /// `None` = auto (offload all layers that fit); `Some(n)` = exactly `n`.
    pub gpu_layers: Option<i32>,
    pub backend: BackendKind,
    pub mmap: bool,
}

/// Load a GGUF model into an owned `LoadedModel`, or return a classed error.
pub fn load(req: LoadRequest) -> Result<LoadedModel, RebirthError> {
    // Acquire the backend up front so the ggml device registry is populated
    // before any capability query, and so it lives for the whole load. On an
    // early return the guard drops and (if last) tears the backend down again.
    let backend = Backend::acquire();

    // Backend availability first: a clear "the machine can't" before touching
    // the file (ARCHITECTURE.md §8 three families of error).
    if !req.backend.is_available() {
        let available = available_backends()
            .iter()
            .map(|b| b.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(RebirthError::Backend {
            requested: req.backend.as_str().to_string(),
            available,
        });
    }

    if !req.path.exists() {
        return Err(RebirthError::ModelLoad {
            failing_check: "file_not_found".to_string(),
        });
    }

    let path_str = req.path.to_str().ok_or_else(|| RebirthError::ModelLoad {
        failing_check: "path_not_utf8".to_string(),
    })?;
    let c_path = CString::new(path_str).map_err(|_| RebirthError::ModelLoad {
        failing_check: "path_has_nul".to_string(),
    })?;

    // SAFETY: default params are a plain by-value C struct we only tweak.
    let mut mparams = unsafe { ffi::llama_model_default_params() };
    mparams.n_gpu_layers = match req.backend {
        BackendKind::Cpu => 0,
        // Negative = all layers (validated against llama-model.cpp at this tag).
        BackendKind::Metal | BackendKind::Cuda => req.gpu_layers.unwrap_or(-1),
    };
    mparams.use_mmap = req.mmap;
    // `mparams` is consumed by the by-value call below; keep what we still need.
    let resolved_gpu_layers = mparams.n_gpu_layers;

    // SAFETY: `c_path` outlives the call; `mparams` matches the C layout.
    let model_ptr = unsafe { ffi::llama_model_load_from_file(c_path.as_ptr(), mparams) };
    let model_ptr = NonNull::new(model_ptr).ok_or_else(|| RebirthError::ModelLoad {
        failing_check: "model_parse".to_string(),
    })?;
    let model = Arc::new(Model {
        ptr: model_ptr,
        resolved_backend: req.backend,
        _backend: backend,
    });

    // SAFETY: default params are a plain by-value C struct we only tweak.
    let mut cparams = unsafe { ffi::llama_context_default_params() };
    cparams.n_ctx = req.context_length;

    // SAFETY: `model.ptr` is a live model; `cparams` matches the C layout. On
    // failure the `Arc<Model>` drops here, freeing the model and backend.
    let ctx_ptr = unsafe { ffi::llama_init_from_model(model.ptr.as_ptr(), cparams) };
    let ctx_ptr = NonNull::new(ctx_ptr).ok_or_else(|| RebirthError::ModelLoad {
        failing_check: "context_init".to_string(),
    })?;

    // SAFETY: `ctx_ptr` is a live context; query its resolved window.
    let context_length = unsafe { ffi::llama_n_ctx(ctx_ptr.as_ptr()) };

    Ok(LoadedModel {
        ctx: Context {
            ptr: ctx_ptr,
            model,
            context_length,
            gpu_layers: resolved_gpu_layers,
            mmap: req.mmap,
        },
    })
}

/// Map a `general.file_type` integer to its canonical GGUF quantization name.
///
/// Mirrors the `llama_ftype` enum at the pinned tag. Re-validate on vendor-bump.
fn ftype_name(ftype: i32) -> String {
    // Strip the LLAMA_FTYPE_GUESSED (1024) bit if present.
    let base = ftype & !1024;
    let name = match base {
        0 => "F32",
        1 => "F16",
        2 => "Q4_0",
        3 => "Q4_1",
        7 => "Q8_0",
        8 => "Q5_0",
        9 => "Q5_1",
        10 => "Q2_K",
        11 => "Q3_K_S",
        12 => "Q3_K_M",
        13 => "Q3_K_L",
        14 => "Q4_K_S",
        15 => "Q4_K_M",
        16 => "Q5_K_S",
        17 => "Q5_K_M",
        18 => "Q6_K",
        19 => "IQ2_XXS",
        20 => "IQ2_XS",
        21 => "Q2_K_S",
        22 => "IQ3_XS",
        23 => "IQ3_XXS",
        24 => "IQ1_S",
        25 => "IQ4_NL",
        26 => "IQ3_S",
        27 => "IQ3_M",
        28 => "IQ2_S",
        29 => "IQ2_M",
        30 => "IQ4_XS",
        31 => "IQ1_M",
        32 => "BF16",
        36 => "TQ1_0",
        37 => "TQ2_0",
        38 => "MXFP4_MOE",
        39 => "NVFP4",
        40 => "Q1_0",
        _ => return format!("ftype_{base}"),
    };
    name.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn backend_kind_roundtrips_and_parses() {
        for k in [BackendKind::Cpu, BackendKind::Metal, BackendKind::Cuda] {
            assert_eq!(BackendKind::parse(k.as_str()), Some(k));
        }
        assert_eq!(BackendKind::parse("auto"), None);
        assert_eq!(BackendKind::parse("opencl"), None);
    }

    #[test]
    fn cpu_is_always_available() {
        let available = available_backends();
        assert!(
            available.contains(&BackendKind::Cpu),
            "cpu must always be available; got {available:?}"
        );
        // CUDA is never built in WP1 (default-off feature).
        assert!(!available.contains(&BackendKind::Cuda));
    }

    #[test]
    fn metal_available_only_on_macos_arm64() {
        let has_metal = available_backends().contains(&BackendKind::Metal);
        if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            assert!(has_metal, "Metal build must report metal availability");
        } else {
            assert!(!has_metal, "non-Metal build must not report metal");
        }
    }

    #[test]
    fn ftype_name_maps_known_and_unknown() {
        assert_eq!(ftype_name(15), "Q4_K_M");
        assert_eq!(ftype_name(7), "Q8_0");
        assert_eq!(ftype_name(1), "F16");
        // GUESSED bit is stripped.
        assert_eq!(ftype_name(15 | 1024), "Q4_K_M");
        // Unknown falls back to a stable, non-panicking label.
        assert_eq!(ftype_name(999), "ftype_999");
    }

    #[test]
    fn load_nonexistent_path_is_model_load_error() {
        let req = LoadRequest {
            path: PathBuf::from("/nonexistent/definitely/not/a/model.gguf"),
            context_length: 512,
            gpu_layers: None,
            backend: BackendKind::Cpu,
            mmap: true,
        };
        match load(req) {
            Err(RebirthError::ModelLoad { failing_check }) => {
                assert_eq!(failing_check, "file_not_found");
            }
            Err(e) => panic!("expected ModelLoad(file_not_found), got {e:?}"),
            Ok(_) => panic!("expected ModelLoad(file_not_found), got a loaded model"),
        }
    }

    #[test]
    fn load_garbage_file_is_model_load_error_not_a_crash() {
        // A file with valid bytes but no GGUF magic: the engine must reject it
        // by returning a null model (which we map to ModelLoad), never abort.
        let mut path = std::env::temp_dir();
        path.push(format!("rebirth-garbage-{}.gguf", std::process::id()));
        {
            let mut f = std::fs::File::create(&path).expect("write temp garbage file");
            f.write_all(b"this is not a gguf file, just some random bytes \x00\x01\x02")
                .expect("write bytes");
        }
        let req = LoadRequest {
            path: path.clone(),
            context_length: 512,
            gpu_layers: None,
            backend: BackendKind::Cpu,
            mmap: true,
        };
        let result = load(req);
        let _ = std::fs::remove_file(&path);
        match result {
            Err(RebirthError::ModelLoad { failing_check }) => {
                assert_eq!(failing_check, "model_parse");
            }
            Err(e) => panic!("expected ModelLoad(model_parse), got {e:?}"),
            Ok(_) => panic!("expected ModelLoad(model_parse), got a loaded model"),
        }
    }

    #[test]
    fn load_unavailable_backend_is_backend_error() {
        // CUDA is never built in WP1, so requesting it must be a Backend error
        // on every platform (before any file access).
        let req = LoadRequest {
            path: PathBuf::from("/does/not/matter.gguf"),
            context_length: 512,
            gpu_layers: None,
            backend: BackendKind::Cuda,
            mmap: true,
        };
        match load(req) {
            Err(RebirthError::Backend {
                requested,
                available,
            }) => {
                assert_eq!(requested, "cuda");
                assert!(available.contains("cpu"), "available should list cpu");
            }
            Err(e) => panic!("expected Backend error, got {e:?}"),
            Ok(_) => panic!("expected Backend error, got a loaded model"),
        }
    }
}
