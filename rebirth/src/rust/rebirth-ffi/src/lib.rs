//! `rebirth` — the native boundary of the R package (extendr).
//!
//! This is the only crate that speaks R (extendr) and the only one that holds
//! the boundary `unsafe` (ARCHITECTURE.md §2). Its job for WP1:
//!
//! - expose one internal `.Call` entry, [`rebirth_model_load`], that all R-side
//!   validation has already vetted;
//! - catch any Rust panic (`catch_unwind`) so it becomes a classed
//!   `rebirth_error_internal` payload, never a raw panic on the R console;
//! - map every [`RebirthError`] variant to a structured payload
//!   `list(ok, class, message, fields)` **returned** to R — the R helper
//!   `rebirth_abort()` does the actual `stop()` (condition raising stays in R,
//!   ARCHITECTURE.md §2), while this crate decides the class + fields (§8);
//! - expose the close / is-closed boundary calls plus the backend-capability
//!   query R needs to resolve `backend = "auto"`.
//!
//! None of these functions is `@export`ed: the user-facing surface is the R
//! `llm()` (and its S3 methods), which call these wrappers internally.

use std::any::Any;
use std::cell::RefCell;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

use extendr_api::prelude::*;
use rebirth_llm::{BackendKind, LoadRequest, LoadedModel, ModelMetadata, RebirthError};

/// The native side of an `llm` handle: an owned loaded model, or `None` once the
/// handle has been closed. Interior mutability lets a shared `&LlmHandle` (all
/// extendr hands out) free the model deterministically. Access is confined to
/// the R main thread (ARCHITECTURE.md §3), so a `RefCell` is sound here.
struct LlmHandle {
    inner: RefCell<Option<LoadedModel>>,
}

impl LlmHandle {
    fn new(model: LoadedModel) -> Self {
        LlmHandle {
            inner: RefCell::new(Some(model)),
        }
    }

    /// An already-closed handle (a real external pointer with no model), used to
    /// exercise the close / is-closed boundary without a GGUF file.
    fn empty() -> Self {
        LlmHandle {
            inner: RefCell::new(None),
        }
    }

    fn is_closed(&self) -> bool {
        self.inner.borrow().is_none()
    }

    /// Free the model now. Returns `true` if this call freed it (was open),
    /// `false` if it was already closed (double-close is a no-op).
    fn close(&self) -> bool {
        self.inner.borrow_mut().take().is_some()
    }

    /// Run `f` against the live model, or `rebirth_error_closed` if the handle
    /// has been closed. Keeps `inner` private to this type.
    fn run<F, T>(&self, f: F) -> Result<T, RebirthError>
    where
        F: FnOnce(&LoadedModel) -> Result<T, RebirthError>,
    {
        let borrow = self.inner.borrow();
        let model = borrow.as_ref().ok_or(RebirthError::Closed)?;
        f(model)
    }
}

// --- index conversion (the single 1-based <-> 0-based boundary, §4) ---------

/// R (1-based token id) -> engine (0-based). The only place the conversion is
/// applied on the way in (ARCHITECTURE.md §4). `id <= 0` is out of range for a
/// 1-based id and maps to a negative engine id the engine's validation rejects.
fn to_engine_token(id_1based: i32) -> i32 {
    id_1based - 1
}

/// Engine (0-based token id) -> R (1-based). The only place the conversion is
/// applied on the way out (ARCHITECTURE.md §4).
fn from_engine_token(id_0based: i32) -> i32 {
    id_0based + 1
}

/// Borrow the live model behind `ptr` and run `f`, mapping a closed/foreign
/// pointer, a `RebirthError`, or a caught panic to the right classed payload.
fn with_model<F>(ptr: &Robj, f: F) -> Robj
where
    F: FnOnce(&LoadedModel) -> Result<Robj, RebirthError>,
{
    let result = catch_unwind(AssertUnwindSafe(|| {
        let handle = <&ExternalPtr<LlmHandle>>::try_from(ptr).map_err(|_| RebirthError::Closed)?;
        handle.run(f)
    }));
    match result {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => error_payload(error),
        Err(panic) => panic_payload(panic),
    }
}

// --- payload construction --------------------------------------------------

/// Build the R payload for a successful load: the handle plus every metadata
/// slot the R `llm` object stores (`API-GRAMMAR.md` §2, plus summary extras).
fn ok_payload(ptr: Robj, meta: ModelMetadata) -> Robj {
    List::from_pairs(vec![
        ("ok", Robj::from(true)),
        ("ptr", ptr),
        ("architecture", Robj::from(meta.architecture)),
        ("parameters", Robj::from(meta.parameters as f64)),
        ("quantization", Robj::from(meta.quantization)),
        ("layers", Robj::from(meta.layers)),
        ("hidden_size", Robj::from(meta.hidden_size)),
        ("context_length", Robj::from(meta.context_length as i32)),
        ("context_train", Robj::from(meta.context_train)),
        ("backend", Robj::from(meta.backend)),
        ("size_bytes", Robj::from(meta.size_bytes as f64)),
        ("vocab_size", Robj::from(meta.vocab_size)),
        ("description", Robj::from(meta.description)),
    ])
    .into()
}

/// The structured `fields` sub-list carried by each error class (§8: code — and
/// coding models — branch on these).
fn error_fields(error: &RebirthError) -> Robj {
    let pairs: Vec<(&str, Robj)> = match error {
        RebirthError::ModelLoad { failing_check } => {
            vec![("failing_check", Robj::from(failing_check.as_str()))]
        }
        RebirthError::Backend {
            requested,
            available,
        } => vec![
            ("requested", Robj::from(requested.as_str())),
            ("available", Robj::from(available.as_str())),
        ],
        RebirthError::Closed => Vec::new(),
        RebirthError::Tokenize { reason } => {
            vec![("reason", Robj::from(reason.as_str()))]
        }
        RebirthError::Generation { reason } => {
            vec![("reason", Robj::from(reason.as_str()))]
        }
        RebirthError::ContextOverflow {
            prompt_tokens,
            context_length,
            overflow,
        } => vec![
            ("prompt_tokens", Robj::from(*prompt_tokens as i32)),
            ("context_length", Robj::from(*context_length as i32)),
            ("overflow", Robj::from(*overflow as i32)),
        ],
        RebirthError::Internal { context } => {
            vec![("context", Robj::from(context.as_str()))]
        }
    };
    List::from_pairs(pairs).into()
}

/// Map a `RebirthError` to the `(class, message, fields)` payload R raises.
fn error_payload(error: RebirthError) -> Robj {
    List::from_pairs(vec![
        ("ok", Robj::from(false)),
        ("class", Robj::from(error.class())),
        ("message", Robj::from(error.to_string())),
        ("fields", error_fields(&error)),
    ])
    .into()
}

/// A caught panic becomes a `rebirth_error_internal` payload with the panic
/// message — a panic must never reach the R console raw (ARCHITECTURE.md §2).
fn panic_payload(panic: Box<dyn Any + Send>) -> Robj {
    let context = panic
        .downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| panic.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "a panic with a non-string payload".to_string());
    error_payload(RebirthError::Internal { context })
}

// --- boundary entries ------------------------------------------------------

// Load a GGUF model. All argument validation and defaulting happen in R before
// this call (ARCHITECTURE.md §2); here we only normalize the enum/sentinel args
// (§4), run the engine under `catch_unwind`, and return a classed payload.
// `gpu_layers < 0` is the R `NULL` sentinel (auto / all layers). `backend` is a
// concrete backend name resolved in R — never `"auto"`.
// (Plain `//`, not `///`: extendr propagates doc comments into the generated R
// wrapper; these entries are internal, so their wrappers stay undocumented.)
#[extendr]
fn rebirth_model_load(
    path: &str,
    context_length: i32,
    gpu_layers: i32,
    backend: &str,
    mmap: bool,
) -> Robj {
    let backend = match BackendKind::parse(backend) {
        Some(kind) => kind,
        None => {
            return error_payload(RebirthError::Internal {
                context: format!(
                    "backend '{backend}' reached the boundary unresolved (R must resolve \"auto\")"
                ),
            });
        }
    };
    let request = LoadRequest {
        path: PathBuf::from(path),
        context_length: context_length.max(1) as u32,
        gpu_layers: if gpu_layers < 0 {
            None
        } else {
            Some(gpu_layers)
        },
        backend,
        mmap,
    };

    // The entire success path -- load, metadata snapshot, external-pointer and
    // payload construction -- runs inside catch_unwind so a panic anywhere maps
    // to a classed rebirth_error_internal (ARCHITECTURE.md §2.2), never a generic
    // extendr error.
    let result = catch_unwind(AssertUnwindSafe(|| {
        let loaded = rebirth_llm::load(request)?;
        let meta = loaded.metadata();
        let ptr: Robj = ExternalPtr::new(LlmHandle::new(loaded)).into();
        Ok::<Robj, RebirthError>(ok_payload(ptr, meta))
    }));
    match result {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => error_payload(error),
        Err(panic) => panic_payload(panic),
    }
}

// Deterministically free the native model behind `ptr` (the `close.llm` path).
// Idempotent: a double close, or a pointer already freed by the GC finalizer,
// is a no-op. Returns an R NULL.
#[extendr]
fn rebirth_handle_close(ptr: Robj) -> Robj {
    if let Ok(handle) = <&ExternalPtr<LlmHandle>>::try_from(&ptr) {
        let _ = handle.close();
    }
    // A null (finalized) or foreign pointer is treated as already closed.
    ().into()
}

// Whether `ptr` is closed — the tag every future boundary entry consults first
// (ARCHITECTURE.md §3). A finalized or foreign pointer counts as closed.
#[extendr]
fn rebirth_handle_is_closed(ptr: Robj) -> bool {
    match <&ExternalPtr<LlmHandle>>::try_from(&ptr) {
        Ok(handle) => handle.is_closed(),
        Err(_) => true,
    }
}

// The backends this build can use, in preference order (GPU first). R uses this
// to resolve `backend = "auto"` and to validate an explicit backend.
#[extendr]
fn rebirth_available_backends() -> Robj {
    let names: Vec<String> = rebirth_llm::available_backends()
        .iter()
        .map(|b| b.as_str().to_string())
        .collect();
    names.into()
}

// Encode `text` into tokens. Returns a payload carrying the 1-based token ids
// (R API, §4) and their display pieces; R assembles the named integer vector.
// `add_special`/`parse_special` are decided in R (chat vs raw completion).
#[extendr]
fn rebirth_tokenize(ptr: Robj, text: &str, add_special: bool, parse_special: bool) -> Robj {
    with_model(&ptr, |model| {
        let enc = model.encode(text, add_special, parse_special)?;
        let ids: Vec<i32> = enc.ids.iter().map(|&id| from_engine_token(id)).collect();
        Ok(List::from_pairs(vec![
            ("ok", Robj::from(true)),
            ("ids", Robj::from(ids)),
            ("pieces", Robj::from(enc.pieces)),
        ])
        .into())
    })
}

// Decode 1-based token ids (R API, §4) back into a single string. The ids are
// validated as positive integers in R; the engine range-checks after the
// 1->0-based conversion here.
#[extendr]
fn rebirth_detokenize(ptr: Robj, ids: Vec<i32>) -> Robj {
    with_model(&ptr, |model| {
        let engine_ids: Vec<i32> = ids.iter().map(|&id| to_engine_token(id)).collect();
        let text = model.decode_tokens(&engine_ids, false, true)?;
        Ok(List::from_pairs(vec![("ok", Robj::from(true)), ("text", Robj::from(text))]).into())
    })
}

// Test-only: a real, already-closed handle for exercising the close /
// is-closed boundary without a GGUF file. Internal (never in NAMESPACE).
#[extendr]
fn rebirth_selftest_new_handle() -> Robj {
    ExternalPtr::new(LlmHandle::empty()).into()
}

// Test-only: force a panic inside the `catch_unwind` path and return the
// resulting `rebirth_error_internal` payload — proves a panic maps to a classed
// condition instead of reaching R raw. Internal (never in NAMESPACE).
#[extendr]
fn rebirth_selftest_panic() -> Robj {
    match catch_unwind(AssertUnwindSafe(|| -> Result<(), RebirthError> {
        panic!("forced panic for the internal-error self-test")
    })) {
        Ok(Ok(())) => ().into(),
        Ok(Err(error)) => error_payload(error),
        Err(panic) => panic_payload(panic),
    }
}

// Macro to generate exports. The functions above are internal `.Call` targets;
// the user-facing surface is the R `llm()` and its S3 methods.
extendr_api::extendr_module! {
    mod rebirth;
    fn rebirth_model_load;
    fn rebirth_handle_close;
    fn rebirth_handle_is_closed;
    fn rebirth_available_backends;
    fn rebirth_tokenize;
    fn rebirth_detokenize;
    fn rebirth_selftest_new_handle;
    fn rebirth_selftest_panic;
}
