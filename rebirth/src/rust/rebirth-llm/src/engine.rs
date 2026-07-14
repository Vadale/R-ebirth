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
use std::thread::ThreadId;

use crate::error::RebirthError;
use crate::ffi;
use crate::probe::ProbeCache;
use crate::vision::VisionContext;

/// D-008 gate G2: the raw llama.cpp handles are confined to the R main thread
/// (ARCHITECTURE.md section 3). WP4 Step 5 introduces the first background thread
/// (the spill writer), which receives only owned plain `CaptureRow` data — never
/// a handle — so the confinement holds. This debug-only tripwire fires if any
/// future code ever touches a handle from another thread: the `unsafe impl Send +
/// Sync` below is then no longer sound, and the misuse trips here first.
#[inline]
pub(crate) fn assert_r_main_thread(owner: ThreadId, what: &str) {
    debug_assert_eq!(
        std::thread::current().id(),
        owner,
        "relm: {what} touched off the R main thread (D-008 G2 violation)"
    );
}

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
    /// The R main thread the handle was created on (D-008 G2 confinement check).
    owner: ThreadId,
    /// The sentinel-probe verdict cache (D-021), shared through every `Arc<Model>`
    /// clone so a derived handle inherits it: the intervention mechanism is proven
    /// on this model's weights once per (mechanism, layer), then reused. `Mutex`
    /// only for the `Sync` bound `Arc<Model>` requires — access is on the R main
    /// thread and always uncontended.
    probe_cache: Mutex<ProbeCache>,
    /// The vision-encoder (mtmd) context bound to this model when it was loaded
    /// with `llm(projector=)`; `None` for a text-only handle (WP-V2, D-026).
    /// Living on the `Arc`-shared `Model` — the projector shares the model
    /// pointer (`mtmd_init_from_file(mmproj, model)`) — means every handle
    /// derived from these weights, including an intervened handle's fresh
    /// context (`clone_with_fresh_context`), carries the projector, and it is
    /// freed exactly once, before the model, when the last handle is gone.
    vision: Option<VisionContext>,
    _backend: Backend,
}

// The raw handle is only ever touched on the R main thread (ARCHITECTURE.md §3),
// but `Arc<Model>` requires `Send + Sync`. This is asserted, not proven: WP4's
// spill writer thread never receives a `Model`/`Context` (only owned `CaptureRow`
// data over a bounded channel), so the handle is never actually sent across a
// thread boundary. The `owner` thread-id `debug_assert` in the getters and Drop
// (D-008 G2) is the tripwire that catches any future code that breaks this.
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
        assert_r_main_thread(self.owner, "Model::drop");
        // Free the vision context BEFORE the model it is bound to (it holds
        // the model's vocab pointer): fields would otherwise drop after this
        // body, i.e. after llama_model_free.
        self.vision.take();
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
    /// The R main thread the context was created on (D-008 G2 confinement check).
    owner: ThreadId,
}

// Asserted, not proven — see the `Model` note above. The context handle is used
// only on the R main thread; the spill writer thread never receives it.
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Drop for Context {
    fn drop(&mut self) {
        assert_r_main_thread(self.owner, "Context::drop");
        // SAFETY: `ptr` came from `llama_init_from_model`; freed exactly once and
        // before the `Arc<Model>` it borrows (dropped right after this).
        unsafe { ffi::llama_free(self.ptr.as_ptr()) };
    }
}

/// A freshly created raw `llama_context` that frees itself on `Drop` until
/// ownership is released with [`OwnedContext::into_raw`]. It makes the window
/// between `llama_init_from_model` and the final owning-struct construction
/// leak-proof by construction: any `?`/early return in that window drops the
/// guard and frees the context, so no call site has to remember a manual
/// `llama_free` (the pattern this replaces — two hand-written frees on the
/// `n_embd <= 0` paths of the embedding/trace builders — was easy to forget on a
/// newly added early return). Every context builder below funnels through it.
struct OwnedContext {
    ptr: NonNull<ffi::llama_context>,
}

impl OwnedContext {
    /// Create a context for `model` from `cparams`, mapping a null result (out of
    /// memory, or an unsupported configuration) to the classed error `on_fail()`
    /// returns.
    fn create(
        model: &Model,
        cparams: ffi::llama_context_params,
        on_fail: impl FnOnce() -> RebirthError,
    ) -> Result<OwnedContext, RebirthError> {
        // SAFETY: `model.ptr` is a live model; `cparams` matches the C layout. A
        // null return means no context was created, so there is nothing to free.
        let ctx_ptr = unsafe { ffi::llama_init_from_model(model.ptr.as_ptr(), cparams) };
        let ptr = NonNull::new(ctx_ptr).ok_or_else(on_fail)?;
        Ok(OwnedContext { ptr })
    }

    /// The raw context pointer, for read-only queries (e.g. `llama_n_ctx`) made
    /// while the guard still owns the context.
    fn as_ptr(&self) -> *mut ffi::llama_context {
        self.ptr.as_ptr()
    }

    /// Release ownership: the caller takes the raw pointer and the guard no longer
    /// frees it. Used when the pointer moves into an owning struct's field.
    fn into_raw(self) -> NonNull<ffi::llama_context> {
        let ptr = self.ptr;
        std::mem::forget(self);
        ptr
    }
}

impl Drop for OwnedContext {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from `llama_init_from_model` and is freed exactly
        // once — `into_raw` forgets the guard when ownership transfers out, so
        // this runs only on the leak-prevention (early-return) path.
        unsafe { ffi::llama_free(self.ptr.as_ptr()) };
    }
}

/// A transient embeddings-mode context (D-011): `create_embedding_context` builds
/// one per `llm_embed` call, sized to the batch, and it drops at the call's end.
/// Unlike [`Context`] it is never stored in the `Arc`-shared handle, so it needs
/// no `unsafe impl Send + Sync` — it lives and dies on the R main thread inside a
/// single call (keeping the D-008 G2 thread-safety gate closed).
pub(crate) struct EmbeddingContext {
    pub(crate) ptr: NonNull<ffi::llama_context>,
    /// Keeps the model alive for the context's lifetime; dropped after `ptr`.
    _model: Arc<Model>,
    pub(crate) n_embd: usize,
}

impl Drop for EmbeddingContext {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from `llama_init_from_model`; freed exactly once and
        // before the `Arc<Model>` it holds (dropped right after this).
        unsafe { ffi::llama_free(self.ptr.as_ptr()) };
    }
}

/// A transient tracing context (WP4, D-011/D-012 pattern): `create_trace_context`
/// builds one per `llm_trace` call with the scheduler eval callback installed
/// (`cb_eval`/`cb_eval_user_data`), so the forward pass can be observed. Like
/// [`EmbeddingContext`] it is never stored in the `Arc`-shared handle — it lives
/// and dies on the R main thread inside one call, needing no `unsafe impl Send +
/// Sync` (keeping the D-008 G2 thread-safety gate closed). The generation context
/// never gets a callback, so tap-off overhead is structurally zero. The methods
/// live in `trace.rs` next to the `CaptureState` the callback drives.
pub(crate) struct TraceContext {
    pub(crate) ptr: NonNull<ffi::llama_context>,
    /// Keeps the model alive for the context's lifetime; dropped after `ptr`.
    _model: Arc<Model>,
}

impl Drop for TraceContext {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from `llama_init_from_model`; freed exactly once and
        // before the `Arc<Model>` it holds. Freeing the context tears down the
        // scheduler (and thus the installed callback), so no capture can run after
        // this — the caller drops the context before reclaiming the capture state.
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
        assert_r_main_thread(self.ctx.owner, "Context::ctx_ptr");
        self.ctx.ptr.as_ptr()
    }

    /// The model's vocabulary (owned by the model; valid for its whole lifetime).
    pub(crate) fn vocab_ptr(&self) -> *const ffi::llama_vocab {
        assert_r_main_thread(self.ctx.model.owner, "Model::vocab_ptr");
        // SAFETY: `model.ptr` is a live model; the vocab is owned by it and the
        // returned pointer is valid for as long as the model is.
        unsafe { ffi::llama_model_get_vocab(self.ctx.model.ptr.as_ptr()) }
    }

    /// The live model pointer (metadata and chat-template queries).
    pub(crate) fn model_ptr(&self) -> *const ffi::llama_model {
        assert_r_main_thread(self.ctx.model.owner, "Model::model_ptr");
        self.ctx.model.ptr.as_ptr()
    }

    /// Whether the model carries a real tokenizer (`false` for a `no_vocab`
    /// model such as the synthetic fixture — tokenization is unsupported there).
    pub(crate) fn has_tokenizer(&self) -> bool {
        let vocab = self.vocab_ptr();
        if vocab.is_null() {
            return false;
        }
        // SAFETY: `vocab` is non-null and owned by the live model.
        // 0 == LLAMA_VOCAB_TYPE_NONE (llama.h l.73).
        unsafe { ffi::llama_vocab_type(vocab) != 0 }
    }

    /// Vocabulary size (row count of the logit vector).
    pub(crate) fn n_vocab(&self) -> i32 {
        self.ctx.model.vocab_size()
    }

    /// The active context window in tokens (`n_ctx`).
    pub(crate) fn context_length(&self) -> u32 {
        self.ctx.context_length
    }

    /// The maximum tokens one `llama_decode` batch may carry (`n_batch`). A
    /// prompt longer than this is decoded in chunks (generate.rs).
    pub(crate) fn n_batch(&self) -> u32 {
        // SAFETY: `ctx_ptr` is a live context for the model's lifetime.
        unsafe { ffi::llama_n_batch(self.ctx_ptr()) }
    }

    // --- crate-internal embedding support (embed.rs) ------------------------

    /// Build a fresh embeddings-mode context sized to `n_ctx` tokens (D-011):
    /// `embeddings = true`, `pooling_type = NONE` (so `llama_get_embeddings_ith`
    /// yields per-token post-final-norm rows), `attention_type = UNSPECIFIED`
    /// (llama auto-selects causal for generative models, non-causal for encoders),
    /// and `n_batch = n_ubatch = n_ctx` so any sequence up to `n_ctx` tokens
    /// decodes in a single batch — required for a non-causal encoder (its whole
    /// sequence must live in one ubatch) and the clean way to avoid the
    /// `GGML_ASSERT(n_tokens_all <= n_batch)` abort without per-chunk pooling.
    pub(crate) fn create_embedding_context(
        &self,
        n_ctx: u32,
    ) -> Result<EmbeddingContext, RebirthError> {
        let model = self.ctx.model.clone();

        // SAFETY: default params are a plain by-value C struct we only tweak. The
        // three embedding fields' offsets are guarded by the ffi.rs ABI test.
        let mut cparams = unsafe { ffi::llama_context_default_params() };
        cparams.n_ctx = n_ctx;
        cparams.n_batch = n_ctx;
        cparams.n_ubatch = n_ctx;
        cparams.embeddings = true;
        cparams.pooling_type = 0; // LLAMA_POOLING_TYPE_NONE
        cparams.attention_type = -1; // LLAMA_ATTENTION_TYPE_UNSPECIFIED

        // The guard frees the context on any early return below (the `n_embd <= 0`
        // reject) until ownership transfers into `EmbeddingContext`.
        let ctx = OwnedContext::create(&model, cparams, || RebirthError::Embed {
            reason: "Could not create an embedding context for this model. \
                     The model may not support embeddings, or there was not enough memory. \
                     Try a shorter input, or free other loaded models first."
                .to_string(),
        })?;

        // SAFETY: `model.ptr` is a live model; read-only scalar getter.
        let n_embd = unsafe { ffi::llama_model_n_embd(model.ptr.as_ptr()) };
        if n_embd <= 0 {
            // `ctx` drops here, freeing the freshly created context.
            return Err(RebirthError::Embed {
                reason: "This model reports no embedding dimension, so it cannot \
                         produce embeddings. Use a model that has an embedding output."
                    .to_string(),
            });
        }

        Ok(EmbeddingContext {
            ptr: ctx.into_raw(),
            _model: model,
            n_embd: n_embd as usize,
        })
    }

    /// The model's own pooling from GGUF `<arch>.pooling_type`, or `None` when the
    /// key is absent — read via the existing `llama_model_meta_val_str` and parsed
    /// as an integer exactly like `quantization()` parses `general.file_type`.
    /// `embed.rs` maps the value to a reduction (§2.4 / D-011).
    pub(crate) fn model_pooling_type_meta(&self) -> Option<i32> {
        let model = &self.ctx.model;
        let key = format!("{}.pooling_type", model.architecture());
        model
            .meta_str(&key)
            .and_then(|s| s.trim().parse::<i32>().ok())
    }

    // --- crate-internal tracing support (trace.rs) --------------------------

    /// The model's architecture string (`general.architecture`, e.g. `"llama"`,
    /// `"qwen2"`), used by the tap's per-architecture component-name matcher.
    pub(crate) fn architecture(&self) -> String {
        assert_r_main_thread(self.ctx.model.owner, "Model::architecture");
        self.ctx.model.architecture()
    }

    /// The residual-stream width (`n_embd`); every tapped component tensor
    /// (residual/attn_out/mlp_out) is this wide, so it is the expected row length.
    pub(crate) fn hidden_size(&self) -> i32 {
        assert_r_main_thread(self.ctx.model.owner, "Model::hidden_size");
        // SAFETY: `model.ptr` is a live model; read-only scalar getter.
        unsafe { ffi::llama_model_n_embd(self.ctx.model.ptr.as_ptr()) }
    }

    /// The number of transformer blocks (`n_layer`); the capture's layer count
    /// when `layers = None` (all blocks), used for the predictive spill estimate.
    pub(crate) fn num_layers(&self) -> i32 {
        assert_r_main_thread(self.ctx.model.owner, "Model::num_layers");
        // SAFETY: `model.ptr` is a live model; read-only scalar getter.
        unsafe { ffi::llama_model_n_layer(self.ctx.model.ptr.as_ptr()) }
    }

    /// Build a fresh tracing context sized to `n_ctx` tokens, with the scheduler
    /// eval callback `cb_eval` and its `cb_eval_user_data` installed (D-012). Sizing
    /// mirrors the embedding context (`n_batch = n_ubatch = n_ctx`) so each prompt
    /// decodes in a single batch — required for the "flag every token as an output"
    /// trick that gives every tapped tensor `n_tokens` rows in token order (the tap
    /// then filters positions host-side). Otherwise the context is a plain forward
    /// pass (default pooling/attention), matching the graph whose tensor names the
    /// matcher was verified against.
    pub(crate) fn create_trace_context(
        &self,
        n_ctx: u32,
        cb_eval: ffi::GgmlSchedEvalCallback,
        cb_eval_user_data: *mut c_void,
    ) -> Result<TraceContext, RebirthError> {
        let model = self.ctx.model.clone();

        // SAFETY: default params are a plain by-value C struct we only tweak. The
        // `cb_eval`/`cb_eval_user_data` offsets are guarded by the ffi.rs ABI test.
        let mut cparams = unsafe { ffi::llama_context_default_params() };
        cparams.n_ctx = n_ctx;
        cparams.n_batch = n_ctx;
        cparams.n_ubatch = n_ctx;
        // A function pointer stored in the opaque `*mut c_void` callback field (the
        // ffi mirror types callbacks as void pointers; a data and a code pointer are
        // the same width on every target this crate builds for).
        cparams.cb_eval = cb_eval as *mut c_void;
        cparams.cb_eval_user_data = cb_eval_user_data;

        // The guard frees the context on any early return below (the `n_embd <= 0`
        // reject) until ownership transfers into `TraceContext`.
        let ctx = OwnedContext::create(&model, cparams, || RebirthError::Trace {
            reason: "Could not create a tracing context for this model. \
                     There may not be enough memory; free other loaded models first, \
                     or trace fewer prompts at once."
                .to_string(),
        })?;

        // SAFETY: `model.ptr` is a live model; read-only scalar getter. The row
        // width the tap validates against comes from `hidden_size()` on the caller
        // side; here we only reject a model with no hidden dimension up front.
        let n_embd = unsafe { ffi::llama_model_n_embd(model.ptr.as_ptr()) };
        if n_embd <= 0 {
            // `ctx` drops here, freeing the freshly created context.
            return Err(RebirthError::Trace {
                reason: "This model reports no hidden dimension, so its activations \
                         cannot be traced."
                    .to_string(),
            });
        }

        Ok(TraceContext {
            ptr: ctx.into_raw(),
            _model: model,
        })
    }

    // --- crate-internal vision support (vision.rs, WP-V2/D-026) -------------

    /// Whether this handle was loaded with a projector (`llm(projector=)`) and
    /// can take image input. Carries over to a derived (intervened) handle:
    /// the vision context lives on the `Arc`-shared `Model`.
    pub fn has_vision(&self) -> bool {
        self.ctx.model.vision.is_some()
    }

    /// The live mtmd (vision-encoder) context, if any. Crate-internal like the
    /// other raw handles (ARCHITECTURE.md §2.2).
    pub(crate) fn vision_ptr(&self) -> Option<*mut ffi::mtmd_context> {
        self.ctx.model.vision.as_ref().map(|v| v.as_ptr())
    }

    // --- crate-internal intervention support (intervene.rs / probe.rs) ------

    /// The shared per-model sentinel-probe verdict cache (D-021). Reached through
    /// the `Arc<Model>`, so the source handle and every derived handle see the same
    /// cache and pay a layer's probe cost at most once.
    pub(crate) fn probe_cache(&self) -> &std::sync::Mutex<ProbeCache> {
        &self.ctx.model.probe_cache
    }

    /// Build a NEW `LoadedModel` sharing this model's weights (an `Arc<Model>`
    /// clone — no reload) with a FRESH generation context of the same
    /// configuration (causal, `embeddings = false` — the `load()` context). The
    /// source handle's own context is never touched, so the original stays
    /// bit-for-bit unchanged (WP5 reversibility, D-016). `intervene.rs` then
    /// applies the steering / ablation adapters to the returned context; the
    /// interventions live on the per-context adapters, not the shared weights, so
    /// a fresh context is a clean slate regardless of what the source carried.
    pub(crate) fn clone_with_fresh_context(&self) -> Result<LoadedModel, RebirthError> {
        let model = self.ctx.model.clone();

        // SAFETY: default params are a plain by-value C struct we only tweak;
        // mirrors `load()`'s generation context (only `n_ctx` is set).
        let mut cparams = unsafe { ffi::llama_context_default_params() };
        cparams.n_ctx = self.ctx.context_length;

        let ctx = OwnedContext::create(&model, cparams, || RebirthError::Intervention {
            reason: "Could not create a context for the intervened model. There may \
                     not be enough memory; free other loaded models first, or reduce \
                     context_length."
                .to_string(),
        })?;

        // SAFETY: the guard owns a live context; query its resolved window before
        // transferring ownership into the `Context` below.
        let context_length = unsafe { ffi::llama_n_ctx(ctx.as_ptr()) };

        Ok(LoadedModel {
            ctx: Context {
                ptr: ctx.into_raw(),
                model,
                context_length,
                gpu_layers: self.ctx.gpu_layers,
                mmap: self.ctx.mmap,
                owner: std::thread::current().id(),
            },
        })
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
    /// `Some(path)` = an mmproj GGUF to load as the vision projector
    /// (`llm(projector=)`, WP-V2/D-026); `None` = text-only, unchanged.
    pub projector: Option<PathBuf>,
}

/// Load a GGUF model into an owned `LoadedModel`, or return a classed error.
pub fn load(req: LoadRequest) -> Result<LoadedModel, RebirthError> {
    load_impl(req, None)
}

/// Like [`load`], but forces the context's `n_batch` — the maximum number of
/// tokens a single `llama_decode` may carry. `None` keeps the engine default
/// (for a causal context, `min(n_ctx, 2048)`).
///
/// Primarily a test seam: a small `n_batch` makes a short prompt exceed one
/// decode batch, so the `n_batch`-chunked forward pass (`prompt_last_logits`) is
/// exercised without feeding thousands of tokens — the regression guard for the
/// `llm_logits` over-batch abort.
pub fn load_with_batch(
    req: LoadRequest,
    n_batch: Option<u32>,
) -> Result<LoadedModel, RebirthError> {
    load_impl(req, n_batch)
}

fn load_impl(req: LoadRequest, n_batch: Option<u32>) -> Result<LoadedModel, RebirthError> {
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
    // Build the owning Model BEFORE the optional projector load, so an early
    // return below frees the model through its Drop instead of leaking it.
    let mut model = Model {
        ptr: model_ptr,
        resolved_backend: req.backend,
        owner: std::thread::current().id(),
        probe_cache: Mutex::new(ProbeCache::default()),
        vision: None,
        _backend: backend,
    };

    // `llm(projector=)`: bind the vision encoder to the loaded model (WP-V2,
    // D-026). `use_gpu` follows the handle backend; a failure (bad mmproj,
    // embd-size mismatch) is a classed image error and drops `model` cleanly.
    if let Some(ref mmproj) = req.projector {
        model.vision = Some(crate::vision::load_projector(
            model.ptr.as_ptr(),
            mmproj,
            req.backend != BackendKind::Cpu,
        )?);
    }
    let model = Arc::new(model);

    // SAFETY: default params are a plain by-value C struct we only tweak.
    let mut cparams = unsafe { ffi::llama_context_default_params() };
    cparams.n_ctx = req.context_length;
    // Test seam (load_with_batch): shrink the decode batch below n_ctx so the
    // chunked-decode path can be reached by a short prompt. llama derives
    // n_ubatch = min(n_batch, default) from this, so setting n_batch suffices.
    if let Some(nb) = n_batch {
        cparams.n_batch = nb;
    }

    // On failure the `Arc<Model>` drops after the guard, freeing the model and
    // backend; the guard owns the context until it moves into `Context` below.
    let ctx = OwnedContext::create(&model, cparams, || RebirthError::ModelLoad {
        failing_check: "context_init".to_string(),
    })?;

    // SAFETY: the guard owns a live context; query its resolved window before
    // transferring ownership into the `Context` below.
    let context_length = unsafe { ffi::llama_n_ctx(ctx.as_ptr()) };

    Ok(LoadedModel {
        ctx: Context {
            ptr: ctx.into_raw(),
            model,
            context_length,
            gpu_layers: resolved_gpu_layers,
            mmap: req.mmap,
            owner: std::thread::current().id(),
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
            projector: None,
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
        path.push(format!("relm-garbage-{}.gguf", std::process::id()));
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
            projector: None,
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
            projector: None,
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
