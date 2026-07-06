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
use rebirth_llm::{
    BackendKind, CaptureRow, CaptureSpec, Component, GenerateParams, LoadRequest, LoadedModel,
    ModelMetadata, Pooling, Positions, RebirthError, SpillPlan, TraceOutput,
};

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

/// R (1-based index) -> engine (0-based), for layers/positions/neurons. The single
/// inbound conversion site (ARCHITECTURE.md §4). R has already validated the value
/// is a positive integer, so `one_based - 1` is non-negative; the `.max(0)` makes
/// the narrowing to `u32` total even for an unvalidated caller.
fn to_engine_index(one_based: i32) -> u32 {
    (one_based - 1).max(0) as u32
}

/// Engine (0-based index) -> R (1-based), for layers/positions/neurons. The single
/// outbound conversion site (ARCHITECTURE.md §4). Inverse of [`to_engine_index`] on
/// the valid range: `from_engine_index(to_engine_index(x)) == x` for `x >= 1`.
fn from_engine_index(zero_based: u32) -> i32 {
    (zero_based as i64 + 1) as i32
}

/// Borrow the live model behind `ptr` and run `f`, mapping a closed/foreign
/// pointer, a `RebirthError`, or a caught panic to the right classed payload.
fn with_model<F>(ptr: &Robj, f: F) -> Robj
where
    F: FnOnce(&LoadedModel) -> Result<Robj, RebirthError>,
{
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = <&ExternalPtr<LlmHandle>>::try_from(ptr).map_err(|_| RebirthError::Closed)?;
        handle.run(f)
    })))
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
        RebirthError::Embed { reason } => {
            vec![("reason", Robj::from(reason.as_str()))]
        }
        RebirthError::Trace { reason } => {
            vec![("reason", Robj::from(reason.as_str()))]
        }
        // R has no u64: the two byte sizes surface as doubles (exact for these
        // magnitudes), matching the R-side predictive OOM's `estimate_bytes` field.
        RebirthError::Oom {
            estimate_bytes,
            budget_bytes,
            ..
        } => vec![
            ("estimate_bytes", Robj::from(*estimate_bytes as f64)),
            ("budget_bytes", Robj::from(*budget_bytes as f64)),
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

/// Resolve a `catch_unwind` outcome into the classed payload R receives: a
/// success passes through, a `RebirthError` becomes its error payload, and a
/// caught panic becomes a `rebirth_error_internal` payload (§2). Every boundary
/// entry funnels its result through here.
fn resolve(result: std::thread::Result<Result<Robj, RebirthError>>) -> Robj {
    match result {
        Ok(Ok(payload)) => payload,
        Ok(Err(error)) => error_payload(error),
        Err(panic) => panic_payload(panic),
    }
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
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let loaded = rebirth_llm::load(request)?;
        let meta = loaded.metadata();
        let ptr: Robj = ExternalPtr::new(LlmHandle::new(loaded)).into();
        Ok::<Robj, RebirthError>(ok_payload(ptr, meta))
    })))
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

// Generate a continuation of `prompt`. All argument validation and defaulting
// (including drawing the seed when the user passed NULL) happen in R; here we
// build the params, run template + tokenize + generate under `with_model`'s
// catch_unwind, and return the continuation text plus the seed actually used.
// `stop` is the R character vector of stop sequences (empty for none). `seed`
// arrives as a double (R has no u64) holding a whole non-negative number.
// (Eight params: this boundary mirrors the R `llm_generate()` arguments 1:1;
// extendr maps each to a `.Call` argument, so they cannot be bundled.)
#[allow(clippy::too_many_arguments)]
#[extendr]
fn rebirth_generate(
    ptr: Robj,
    prompt: &str,
    chat: bool,
    max_tokens: i32,
    temperature: f64,
    top_p: f64,
    seed: f64,
    stop: Vec<String>,
) -> Robj {
    with_model(&ptr, |model| {
        let params = GenerateParams {
            max_tokens: max_tokens.max(0) as usize,
            temperature: temperature as f32,
            top_p: top_p as f32,
            seed: seed as u64,
            stop,
        };
        let generation = model.generate_prompt(prompt, chat, &params)?;
        Ok(List::from_pairs(vec![
            ("ok", Robj::from(true)),
            ("text", Robj::from(generation.text)),
            ("seed", Robj::from(generation.seed as f64)),
        ])
        .into())
    })
}

// Embed a character vector into a row-major matrix. R has validated
// m/x/pooling/normalize; here we parse the pooling enum, run embed_texts under
// with_model's catch_unwind, and return the flat values plus the two dimensions.
// No 1-based<->0-based conversion is needed: llm_embed takes text, not token-id
// indices (the internal ids never surface to R), so the §4 index boundary is
// crossed nowhere here.
#[extendr]
fn rebirth_embed(ptr: Robj, texts: Vec<String>, pooling: &str, normalize: bool) -> Robj {
    with_model(&ptr, |model| {
        let pool = Pooling::parse(pooling).ok_or_else(|| RebirthError::Internal {
            context: format!(
                "pooling '{pooling}' reached the boundary unresolved (R must resolve match.arg)"
            ),
        })?;
        let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
        let emb = model.embed_texts(&refs, pool, normalize)?;
        // Upcast f32 -> f64 (R doubles); `values` stays row-major (n_rows x n_embd),
        // consumed by matrix(..., byrow = TRUE) in R.
        let values: Vec<f64> = emb.values.iter().map(|&v| v as f64).collect();
        Ok(List::from_pairs(vec![
            ("ok", Robj::from(true)),
            ("values", Robj::from(values)),
            ("n_embd", Robj::from(emb.n_embd as i32)),
            ("n_rows", Robj::from(emb.n_rows as i32)),
        ])
        .into())
    })
}

// Trace activations over the prompt tokens. R has validated m/prompts/layers/
// positions/components/spill and (for the length-known filters with spill = FALSE)
// run the predictive OOM check; here we build the engine-native (0-based) capture
// spec -- the 1-based -> 0-based conversion for `layers`/`positions` happens ONLY
// here (ARCHITECTURE §4) -- assemble the spill plan, run trace_texts_spill under
// with_model's catch_unwind (which does the authoritative count -> estimate ->
// decide, so the `positions = "all"` size is exact), and return either the seven
// long-format in-memory columns (indices shifted back to 1-based) or a spill
// report (the file path + the capture's dims for the lazy object). `layers` empty
// = all blocks; `positions_mode` is "last"/"all"/"explicit" with `positions_values`
// the 1-based explicit positions (empty otherwise). The spill strings (path,
// model, trace_id, spec_key) are authored in R, which owns the session spill dir.
#[allow(clippy::too_many_arguments)]
#[extendr]
fn rebirth_trace(
    ptr: Robj,
    prompts: Vec<String>,
    layers: Vec<i32>,
    positions_mode: &str,
    positions_values: Vec<i32>,
    components: Vec<String>,
    spill: bool,
    budget_bytes: f64,
    spill_path: &str,
    model_id: &str,
    trace_id: &str,
    spec_key: &str,
) -> Robj {
    with_model(&ptr, |model| {
        let spec = build_capture_spec(&layers, positions_mode, &positions_values, &components)?;
        let refs: Vec<&str> = prompts.iter().map(String::as_str).collect();
        let plan = SpillPlan {
            spill,
            // R passes a validated positive budget as a double; clamp defensively.
            budget_bytes: budget_bytes.max(0.0) as u64,
            spill_path: spill_path.to_string(),
            model: model_id.to_string(),
            trace_id: trace_id.to_string(),
            spec_key: spec_key.to_string(),
        };
        Ok(trace_output_payload(
            model.trace_texts_spill(&refs, &spec, &plan)?,
        ))
    })
}

/// The R payload for a completed trace: the in-memory long-format columns, or a
/// spill report the R side turns into a lazy `rebirth_trace`.
fn trace_output_payload(output: TraceOutput) -> Robj {
    match output {
        TraceOutput::Memory(rows) => trace_payload(&rows),
        #[cfg(feature = "spill")]
        TraceOutput::Spilled(report) => spill_payload(&report),
    }
}

/// The R payload for a spilled trace: the file path plus the capture's dimensions
/// (layers/positions shifted engine 0-based -> R 1-based), so the boundary builds
/// a lazy `rebirth_trace` whose print/summary need no data load. `n_rows`/
/// `n_positions` are doubles (R has no u64; exact at these magnitudes).
#[cfg(feature = "spill")]
fn spill_payload(report: &rebirth_llm::SpillReport) -> Robj {
    let layers: Vec<i32> = report
        .layers
        .iter()
        .map(|&l| from_engine_index(l))
        .collect();
    let positions: Vec<i32> = report
        .positions
        .iter()
        .map(|&p| from_engine_index(p))
        .collect();
    let components: Vec<String> = report
        .components
        .iter()
        .map(|c| c.as_str().to_string())
        .collect();
    List::from_pairs(vec![
        ("ok", Robj::from(true)),
        ("spilled", Robj::from(true)),
        ("spill_path", Robj::from(report.path.as_str())),
        ("n_rows", Robj::from(report.n_rows as f64)),
        ("n_positions", Robj::from(report.n_positions as f64)),
        ("layers", Robj::from(layers)),
        ("positions", Robj::from(positions)),
        ("components", Robj::from(components)),
        ("n_embd", Robj::from(report.n_embd as i32)),
        ("trace_id", Robj::from(report.trace_id.as_str())),
    ])
    .into()
}

/// Build the engine-native capture spec from the validated R arguments, applying
/// the 1-based -> 0-based conversion for `layers`/`positions` here and nowhere else.
fn build_capture_spec(
    layers: &[i32],
    positions_mode: &str,
    positions_values: &[i32],
    components: &[String],
) -> Result<CaptureSpec, RebirthError> {
    let layers = if layers.is_empty() {
        None
    } else {
        Some(layers.iter().map(|&l| to_engine_index(l)).collect())
    };
    let positions = match positions_mode {
        "last" => Positions::Last,
        "all" => Positions::All,
        "explicit" => Positions::Explicit(
            positions_values
                .iter()
                .map(|&p| to_engine_index(p))
                .collect(),
        ),
        other => {
            return Err(RebirthError::Internal {
                context: format!(
                    "positions mode '{other}' reached the boundary unresolved \
                     (R must pass \"last\", \"all\", or \"explicit\")"
                ),
            })
        }
    };
    let components = components
        .iter()
        .map(|c| {
            Component::parse(c).ok_or_else(|| RebirthError::Internal {
                context: format!("component '{c}' reached the boundary unresolved"),
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(CaptureSpec {
        layers,
        positions,
        components,
    })
}

/// Expand the captured rows into the exact 7-column `rebirth_trace` payload
/// (API-GRAMMAR §2), one long-format entry per (row, neuron). Every index is
/// shifted engine 0-based -> R 1-based here; `value` is upcast f32 -> f64.
fn trace_payload(rows: &[CaptureRow]) -> Robj {
    let total: usize = rows.iter().map(|r| r.values.len()).sum();
    let mut prompt_id = Vec::with_capacity(total);
    let mut token_pos = Vec::with_capacity(total);
    let mut token = Vec::with_capacity(total);
    let mut layer = Vec::with_capacity(total);
    let mut component = Vec::with_capacity(total);
    let mut neuron = Vec::with_capacity(total);
    let mut value = Vec::with_capacity(total);

    for row in rows {
        let pid = from_engine_index(row.prompt_id);
        let pos = from_engine_index(row.token_pos);
        let lyr = from_engine_index(row.layer);
        let comp = row.component.as_str();
        let tok = row.token.as_deref().unwrap_or("");
        for (k, &v) in row.values.iter().enumerate() {
            prompt_id.push(pid);
            token_pos.push(pos);
            token.push(tok.to_string());
            layer.push(lyr);
            component.push(comp.to_string());
            neuron.push(from_engine_index(k as u32));
            value.push(v as f64);
        }
    }

    List::from_pairs(vec![
        ("ok", Robj::from(true)),
        ("spilled", Robj::from(false)),
        ("prompt_id", Robj::from(prompt_id)),
        ("token_pos", Robj::from(token_pos)),
        ("token", Robj::from(token)),
        ("layer", Robj::from(layer)),
        ("component", Robj::from(component)),
        ("neuron", Robj::from(neuron)),
        ("value", Robj::from(value)),
    ])
    .into()
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
    resolve(catch_unwind(AssertUnwindSafe(
        || -> Result<Robj, RebirthError> {
            panic!("forced panic for the internal-error self-test")
        },
    )))
}

// Test-only: trace RAW (1-based) token ids with spill, bypassing the tokenizer, so
// the `no_vocab` synthetic model can exercise the full spill path (writer + reader)
// in CI where `llm_trace()` (which tokenizes text) cannot run. Fixed capture spec
// (all layers, all positions, all three components) to keep the surface small; the
// R test authors the matching `spec_key`. Internal (never in NAMESPACE).
#[allow(clippy::too_many_arguments)]
#[extendr]
fn rebirth_selftest_trace_tokens_spill(
    ptr: Robj,
    tokens: Vec<i32>,
    spill: bool,
    budget_bytes: f64,
    spill_path: &str,
    model_id: &str,
    trace_id: &str,
    spec_key: &str,
) -> Robj {
    with_model(&ptr, |model| {
        let spec = CaptureSpec {
            layers: None,
            positions: Positions::All,
            components: vec![Component::Residual, Component::AttnOut, Component::MlpOut],
        };
        let ids: Vec<i32> = tokens.iter().map(|&t| to_engine_token(t)).collect();
        let plan = SpillPlan {
            spill,
            budget_bytes: budget_bytes.max(0.0) as u64,
            spill_path: spill_path.to_string(),
            model: model_id.to_string(),
            trace_id: trace_id.to_string(),
            spec_key: spec_key.to_string(),
        };
        Ok(trace_output_payload(model.trace_token_batch_spill(
            &[&ids],
            &spec,
            &plan,
        )?))
    })
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
    fn rebirth_generate;
    fn rebirth_embed;
    fn rebirth_trace;
    fn rebirth_selftest_new_handle;
    fn rebirth_selftest_panic;
    fn rebirth_selftest_trace_tokens_spill;
}

#[cfg(test)]
mod tests {
    use super::{from_engine_index, to_engine_index};
    use rebirth_llm::parse_tensor_name;

    // The canonical defect class (ARCHITECTURE §4): 1-based <-> 0-based conversion
    // lives ONLY here, so it is property-tested here.
    #[test]
    fn engine_index_round_trips_over_the_valid_range() {
        // from_engine_index(to_engine_index(x)) == x for every 1-based index.
        for x in 1..=4096i32 {
            assert_eq!(
                from_engine_index(to_engine_index(x)),
                x,
                "round-trip at {x}"
            );
        }
        // Anchor the two ends explicitly: layer 1 <-> engine il 0.
        assert_eq!(to_engine_index(1), 0);
        assert_eq!(from_engine_index(0), 1);
    }

    #[test]
    fn tensor_name_layer_surfaces_as_one_based_api_layer() {
        // The tap parses a graph tensor name to a 0-based engine layer; this
        // boundary is the only place it becomes the 1-based API layer. So the
        // graph name "l_out-7" (engine il = 7) surfaces to R as layer 8.
        let (base, il) = parse_tensor_name("l_out-7").expect("l_out-7 parses");
        assert_eq!(base, "l_out");
        assert_eq!(il, 7);
        assert_eq!(from_engine_index(il), 8, "l_out-7 -> API layer 8");
    }
}
