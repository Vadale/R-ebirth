//! Activation tracing (WP4): observe per-layer hidden states during a forward
//! pass via llama.cpp's scheduler eval callback (D-012, zero vendored patch).
//!
//! The engine wrapper for `llm_trace()`. A dedicated, transient [`TraceContext`]
//! (engine.rs) is created per call with a Rust `extern "C"` trampoline installed
//! as `cb_eval`; as the graph computes, the trampoline matches each node's name
//! against the requested components/layers and copies the wanted tensors host-side
//! ([`ffi::ggml_backend_tensor_get`]). All indices here are ENGINE-native (0-based)
//! — the 1-based R API conversion happens only in `rebirth-ffi` (ARCHITECTURE §4).
//! The crate stays R-free (ARCHITECTURE §2): plain Rust types in and out, C-FFI
//! `unsafe` minimal and individually SAFETY-commented (D-009).
//!
//! Capture flows into a [`RowSink`]: either a pre-sized in-memory `Vec` (the
//! in-budget path — no background thread, no Arrow touched) or, when the predicted
//! size exceeds the budget and `spill = TRUE`, the disk-spill sink
//! ([`crate::spill`], feature `spill`) that streams rows to an Arrow-IPC file on a
//! background writer thread (WP4 Step 5, D-013). The estimate is computed from the
//! tokenized lengths *before* any capture allocation (the 16 GB rule): count →
//! estimate → decide → only then capture.

use std::ffi::{c_void, CStr};

use crate::engine::{LoadedModel, TraceContext};
use crate::error::RebirthError;
use crate::ffi;
use crate::generate::Batch;

/// One activation component of a transformer block. The R API exposes exactly
/// these three (`API-GRAMMAR.md` §2); the boundary parses the string names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Component {
    /// The block-output residual stream (`l_out-<il>`), post-attention + FFN.
    Residual,
    /// The attention sub-layer output (`attn_out-<il>` on llama, `kqv_out-<il>` on
    /// qwen2/gemma3 — see [`component_name`]).
    AttnOut,
    /// The raw FFN/MLP sub-layer output before the residual add (`ffn_out-<il>`).
    MlpOut,
}

impl Component {
    /// The R-facing component name (`API-GRAMMAR.md` §2).
    pub fn as_str(self) -> &'static str {
        match self {
            Component::Residual => "residual",
            Component::AttnOut => "attn_out",
            Component::MlpOut => "mlp_out",
        }
    }

    /// Parse an R-facing component name; `None` for anything but the three known
    /// components (R validates the set, so an unknown value here is a boundary bug).
    pub fn parse(s: &str) -> Option<Component> {
        match s {
            "residual" => Some(Component::Residual),
            "attn_out" => Some(Component::AttnOut),
            "mlp_out" => Some(Component::MlpOut),
            _ => None,
        }
    }
}

/// Which token positions of each prompt to capture. Resolved per-prompt against
/// its token count (a prompt-length-independent `Last`, an `All`, or explicit
/// 0-based indices). Explicit indices out of a prompt's range are dropped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Positions {
    Last,
    All,
    Explicit(Vec<u32>),
}

impl Positions {
    /// The 0-based token positions to capture for a prompt of `n_tokens` tokens.
    fn resolve(&self, n_tokens: usize) -> Vec<u32> {
        match self {
            Positions::Last => {
                if n_tokens == 0 {
                    Vec::new()
                } else {
                    vec![(n_tokens - 1) as u32]
                }
            }
            Positions::All => (0..n_tokens as u32).collect(),
            // Keep only in-range positions; a caller-supplied index past a prompt's
            // end simply produces no row for that prompt (positions are recycled
            // across prompts of differing lengths, API-GRAMMAR §4).
            Positions::Explicit(v) => v
                .iter()
                .copied()
                .filter(|&p| (p as usize) < n_tokens)
                .collect(),
        }
    }

    /// Whether an explicit `positions` vector, recycled across prompts of these
    /// per-prompt token counts, had any requested position fall out of range for at
    /// least one prompt (so it was dropped for that prompt). This is the
    /// API-GRAMMAR §4 recycling-warning signal ("recycled per prompt with a warning
    /// if lengths differ"): the reportable case is precisely a differing-length
    /// batch where the same explicit vector does not fit every prompt. Always false
    /// for `Last`/`All`, which are resolved per prompt and never out of range.
    fn recycled_out_of_range(&self, token_counts: &[usize]) -> bool {
        match self {
            Positions::Explicit(v) => token_counts
                .iter()
                .any(|&n| v.iter().any(|&p| p as usize >= n)),
            _ => false,
        }
    }
}

/// What to capture (engine-native, 0-based). Built at the `rebirth-ffi` boundary
/// from the validated R arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureSpec {
    /// Blocks to capture (0-based engine `il`); `None` = every block.
    pub layers: Option<Vec<u32>>,
    pub positions: Positions,
    /// The requested components (a non-empty subset of the three).
    pub components: Vec<Component>,
}

/// One captured hidden-state row: the `values` (n_embd wide) of one `component`
/// at one `(prompt_id, token_pos, layer)`. All indices are engine-native (0-based);
/// `rebirth-ffi` shifts them to the 1-based R API and expands `values` into the
/// long-format `neuron`/`value` columns.
#[derive(Debug, Clone, PartialEq)]
pub struct CaptureRow {
    pub prompt_id: u32,
    pub token_pos: u32,
    pub layer: u32,
    pub component: Component,
    /// The token piece at `token_pos`, filled from the prompt's pieces by the
    /// text-facing [`LoadedModel::trace_texts_spill`]; `None` for the raw-id
    /// [`LoadedModel::activations`] path (a `no_vocab` model has no pieces — the R
    /// `token` column is then `NA`). Filled at capture time so a spilled row lands
    /// on disk already carrying its `token`.
    pub token: Option<String>,
    pub values: Vec<f32>,
}

/// Where captured rows go: an in-memory `Vec` (in budget) or the disk-spill sink
/// (over budget with `spill = TRUE`). The callback pushes into it on the R thread;
/// the spill variant hands each row to the writer thread over its bounded channel.
enum RowSink {
    Memory(Vec<CaptureRow>),
    #[cfg(feature = "spill")]
    Spill(crate::spill::SpillSink),
}

impl RowSink {
    /// Append one captured row. In-memory is infallible; the spill sink returns a
    /// classed error if its writer thread has stopped (backpressure send failure).
    fn push(&mut self, row: CaptureRow) -> Result<(), RebirthError> {
        match self {
            RowSink::Memory(rows) => {
                rows.push(row);
                Ok(())
            }
            #[cfg(feature = "spill")]
            RowSink::Spill(sink) => sink.push(row),
        }
    }
}

/// The result of a planned trace: rows held in memory, or a report of a completed
/// spill (the boundary reconstructs the lazy `rebirth_trace` from the report
/// without loading the file).
#[derive(Debug)]
pub enum TraceOutput {
    Memory {
        rows: Vec<CaptureRow>,
        /// Whether an explicit `positions` vector was recycled across prompts of
        /// differing lengths and dropped some out-of-range positions (the
        /// API-GRAMMAR §4 warning signal). Always false for `Last`/`All`. The R
        /// boundary turns a `true` into a single `warning()`.
        positions_recycled: bool,
    },
    #[cfg(feature = "spill")]
    Spilled(SpillReport),
}

/// What the R boundary needs to reconstruct a spilled `rebirth_trace` object and
/// its lazy reader without loading the file. Indices are engine-native (0-based);
/// `rebirth-ffi` shifts them to the 1-based R API (ARCHITECTURE.md section 4).
#[cfg(feature = "spill")]
#[derive(Debug)]
pub struct SpillReport {
    /// The single `.arrow` file written for this trace.
    pub path: String,
    /// Total long-format rows written (positions x layers x components x n_embd).
    pub n_rows: u64,
    /// Total captured `(prompt, position)` pairs; each `(layer, component)` group
    /// holds this many `(prompt, position)` rows (times `n_embd` neurons).
    pub n_positions: u64,
    /// 0-based union of captured layers.
    pub layers: Vec<u32>,
    /// 0-based union of captured token positions across prompts.
    pub positions: Vec<u32>,
    /// The captured components, in request order.
    pub components: Vec<Component>,
    pub n_embd: usize,
    /// The per-trace identity echoed back for the object's staleness check.
    pub trace_id: String,
    /// Whether an explicit `positions` vector was recycled across prompts of
    /// differing lengths and dropped some out-of-range positions (API-GRAMMAR §4;
    /// same signal as [`TraceOutput::Memory`]).
    pub positions_recycled: bool,
}

/// The spill routing + budget decision inputs, all supplied by the R boundary
/// (which owns the session spill directory and the integrity strings). Present in
/// every build; the actual disk writer is compiled only under the `spill` feature.
pub struct SpillPlan {
    /// Whether an over-budget capture may stream to disk (else it is an OOM).
    pub spill: bool,
    /// The in-memory budget in bytes; above it the decision is spill-or-OOM.
    pub budget_bytes: u64,
    /// Absolute path of the `.arrow` file to write if spilling.
    pub spill_path: String,
    /// The model identifier (its path) for the integrity footer.
    pub model: String,
    /// The per-trace identity string for the integrity footer.
    pub trace_id: String,
    /// A canonical capture-spec string for the integrity footer.
    pub spec_key: String,
}

/// The engine tensor name to match for `comp` on architecture `arch`, or `None`
/// when this component is not observable by name for this architecture.
///
/// Per architecture, exactly ONE name (never a union): on a llama graph BOTH the
/// post-Wo `attn_out-<il>` AND the pre-Wo `kqv_out-<il>` exist, so a `{attn_out,
/// kqv_out}` alias would capture the wrong/both tensors. `residual` (`l_out`) and
/// `mlp_out` (`ffn_out`) are consistent across the supported architectures. `attn_out`
/// (D-014) is the post-projection attention output: only llama names it; qwen2/gemma3
/// name only the pre-Wo `kqv_out` (a different quantity, and not `hidden_size` wide on
/// gemma3), so `attn_out` there returns `None` and is never silently substituted
/// (verified against b9726: `src/models/{llama,qwen2,gemma3}.cpp`, `src/llama-graph.cpp`).
/// `None` → the caller raises `rebirth_error_trace`, never a silent empty capture.
fn component_name(arch: &str, comp: Component) -> Option<&'static str> {
    let supported = matches!(arch, "llama" | "qwen2" | "gemma3");
    match comp {
        Component::Residual => supported.then_some("l_out"),
        Component::MlpOut => supported.then_some("ffn_out"),
        // D-014: `attn_out` is the post-projection (Wo) attention output, hidden_size
        // wide. Only llama names it (`attn_out-<il>`); qwen2/gemma3 build attention via
        // the shared `build_attn` and name only the pre-Wo `kqv_out-<il>` — a different
        // quantity (and not hidden_size wide on gemma3), never substituted silently. So
        // `attn_out` on those archs returns None -> the caller raises rebirth_error_trace.
        Component::AttnOut => match arch {
            "llama" => Some("attn_out"),
            _ => None,
        },
    }
}

/// Split a graph tensor name `"<base>-<il>"` into `(base, il)` with `il` the
/// 0-based engine layer. Names without a trailing `-<number>` (e.g. `"result_norm"`,
/// or the `il = -1` final norm) return `None` — they are not per-layer tensors the
/// tap captures.
///
/// Public so the boundary crate's index-conversion test can carry the canonical
/// off-by-one chain ("l_out-7" -> il 7 -> API layer 8) through one authoritative
/// call rather than a hand-copied constant.
pub fn parse_tensor_name(name: &str) -> Option<(&str, u32)> {
    let (base, suffix) = name.rsplit_once('-')?;
    let il = suffix.parse::<u32>().ok()?;
    Some((base, il))
}

/// The requested components resolved to their engine tensor names for one model,
/// plus the layer filter and row width — computed once per trace before decoding.
#[derive(Clone)]
struct ResolvedSpec {
    /// `(tensor base name, component)` for each requested component.
    names: Vec<(&'static str, Component)>,
    /// 0-based blocks to capture; `None` = all.
    layers: Option<Vec<u32>>,
    /// Expected row width (`n_embd`) of every captured tensor.
    n_embd: usize,
}

impl ResolvedSpec {
    /// The component whose tensor name is `base`, if any (used at capture time to
    /// tag the row). On a llama graph the unrequested `kqv_out` is simply absent
    /// from `names`, so the pre-Wo tensor is never matched for `attn_out`.
    fn component_for(&self, base: &str) -> Option<Component> {
        self.names
            .iter()
            .find(|(name, _)| *name == base)
            .map(|(_, comp)| *comp)
    }

    /// Whether block `il` is in the layer filter.
    fn wants_layer(&self, il: u32) -> bool {
        match &self.layers {
            None => true,
            Some(set) => set.contains(&il),
        }
    }
}

/// The state the eval-callback trampoline drives. Lives behind `cb_eval_user_data`
/// and is touched ONLY on the R (decode) thread, synchronously inside `llama_decode`
/// — so a single `&mut` through the raw pointer is sound (no background thread yet,
/// WP4). Per-prompt fields are refreshed by [`CaptureState::begin_prompt`]; `rows`
/// accumulate across the batch.
struct CaptureState {
    resolved: ResolvedSpec,
    prompt_id: u32,
    /// This prompt's 0-based capture positions.
    positions: Vec<u32>,
    /// This prompt's token pieces (one per token), for the `token` column; empty
    /// on the raw-id path (`token` then stays `None`).
    pieces: Vec<String>,
    /// This prompt's token count (the expected row count of every tapped tensor).
    n_tokens: usize,
    /// Where captured rows go (in-memory or the disk-spill sink).
    sink: RowSink,
    /// Reused host buffer for one tensor's `n_tokens * n_embd` f32.
    scratch: Vec<f32>,
    /// The first capture failure, surfaced by the engine after the decode returns
    /// (a tap error also returns `false` to cancel the remaining compute).
    error: Option<RebirthError>,
}

impl CaptureState {
    fn new(resolved: ResolvedSpec, sink: RowSink) -> Self {
        CaptureState {
            resolved,
            prompt_id: 0,
            positions: Vec::new(),
            pieces: Vec::new(),
            n_tokens: 0,
            sink,
            scratch: Vec::new(),
            error: None,
        }
    }

    /// Point the state at a new prompt before its decode (rows keep accumulating).
    fn begin_prompt(
        &mut self,
        prompt_id: u32,
        positions: Vec<u32>,
        n_tokens: usize,
        pieces: Vec<String>,
    ) {
        self.prompt_id = prompt_id;
        self.positions = positions;
        self.n_tokens = n_tokens;
        self.pieces = pieces;
    }

    /// Record a caught panic as an internal error (idempotent — keep the first).
    fn record_panic(&mut self) {
        if self.error.is_none() {
            self.error = Some(RebirthError::Internal {
                context: "a panic occurred inside the activation-trace callback".to_string(),
            });
        }
    }

    /// Handle one scheduler callback for node `t`.
    ///
    /// `ask = true`: return whether we want to observe `t` (making it a compute
    /// boundary). `ask = false`: `t` is computed and synchronized — copy the wanted
    /// tensor host-side and slice out the requested positions; return `true` to
    /// continue, or `false` to cancel after recording a capture error.
    fn on_node(&mut self, t: *mut ffi::ggml_tensor, ask: bool) -> bool {
        // SAFETY: `t` is the live tensor the scheduler passed; `ggml_get_name`
        // returns a NUL-terminated name owned by the graph, valid for this call.
        let name_ptr = unsafe { ffi::ggml_get_name(t) };
        if name_ptr.is_null() {
            return !ask; // unnamed node: never observe; always keep computing
        }
        // SAFETY: `name_ptr` is non-null and NUL-terminated (per above).
        let name = match unsafe { CStr::from_ptr(name_ptr) }.to_str() {
            Ok(s) => s,
            Err(_) => return !ask, // non-UTF-8 name: not one of ours
        };

        let (base, il) = match parse_tensor_name(name) {
            Some(parsed) => parsed,
            None => return !ask, // not a per-layer `<base>-<il>` tensor
        };
        let component = self.resolved.component_for(base);
        let wanted = component.is_some() && self.resolved.wants_layer(il);

        if ask {
            return wanted;
        }
        // ask == false (data ready). Nothing wanted here -> keep computing.
        if !wanted {
            return true;
        }
        let component = component.expect("wanted implies a matched component");

        // Expected shape: `n_tokens` rows of `n_embd` f32 (all tokens flagged as
        // outputs, so even the last block keeps every position). A mismatch — a
        // pruned row count or a non-F32 dtype — is a capture bug, not a silent bad
        // value: record it and cancel.
        let n_embd = self.resolved.n_embd;
        let expected_elems = self.n_tokens.saturating_mul(n_embd);
        // SAFETY: `t` is the live, computed tensor; both are read-only queries.
        let nelements = unsafe { ffi::ggml_nelements(t) };
        let nbytes = unsafe { ffi::ggml_nbytes(t) };
        if nelements as usize != expected_elems || nbytes != expected_elems * 4 {
            self.error = Some(RebirthError::Trace {
                reason: format!(
                    "Internal error tracing tensor '{name}': expected {expected_elems} float32 \
                     values ({} tokens x {n_embd} neurons) but the tensor has {nelements} \
                     elements in {nbytes} bytes. Please report this with the model and prompt.",
                    self.n_tokens
                ),
            });
            return false;
        }

        if self.scratch.len() < expected_elems {
            self.scratch.resize(expected_elems, 0.0);
        }
        // SAFETY: `t` is computed and synchronized (ask == false). `scratch` holds
        // at least `expected_elems` f32 = `nbytes` bytes; we copy exactly `nbytes`.
        // The tensor is contiguous `[n_embd, n_tokens]`, so row `p` (token `p`) is
        // `scratch[p*n_embd .. (p+1)*n_embd]`.
        unsafe {
            ffi::ggml_backend_tensor_get(t, self.scratch.as_mut_ptr().cast::<c_void>(), 0, nbytes);
        }

        // Index-based to avoid borrowing `self.positions`/`self.scratch`/`self.pieces`
        // across the `self.sink.push`. Each row carries its token piece (filled here
        // so a spilled row lands on disk with its `token`, not patched afterward).
        for i in 0..self.positions.len() {
            let p = self.positions[i];
            let start = (p as usize) * n_embd;
            let values = self.scratch[start..start + n_embd].to_vec();
            let token = self.pieces.get(p as usize).cloned();
            let row = CaptureRow {
                prompt_id: self.prompt_id,
                token_pos: p,
                layer: il,
                component,
                token,
                values,
            };
            if let Err(err) = self.sink.push(row) {
                // A spill-writer failure aborts the pass cleanly: record it and
                // cancel compute (the engine surfaces it after the decode returns).
                self.error = Some(err);
                return false;
            }
        }
        true
    }
}

/// The `extern "C"` scheduler eval callback. Its whole body is wrapped in
/// `catch_unwind`: a panic must NEVER unwind across the C ABI into the ggml
/// scheduler (undefined behaviour). On a caught panic it records an internal error
/// and returns `false` to cancel the compute; the engine then surfaces
/// `rebirth_error_internal` at the `with_model` boundary.
extern "C" fn trace_trampoline(
    t: *mut ffi::ggml_tensor,
    ask: bool,
    user_data: *mut c_void,
) -> bool {
    let state = user_data.cast::<CaptureState>();
    if state.is_null() {
        return !ask; // defensive: no state -> observe nothing, keep computing
    }
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // SAFETY: single-threaded (decode runs on the R thread; the callback fires
        // synchronously inside it). `state` points at a live `CaptureState` owned by
        // the enclosing trace call for the whole decode, and no other reference to
        // it is active while the callback runs.
        let st = unsafe { &mut *state };
        st.on_node(t, ask)
    }));
    match result {
        Ok(keep) => keep,
        Err(_) => {
            // SAFETY: same live pointer; recording the panic and returning false
            // cancels the compute so it surfaces as a classed error, never a raw
            // unwind across the C ABI.
            unsafe { (*state).record_panic() };
            false
        }
    }
}

// --- the trace context's decode path ---------------------------------------

impl TraceContext {
    /// Clear the KV cache so the next prompt starts at position 0 (a no-op on the
    /// freshly created context's first prompt).
    fn clear_memory(&self) {
        // SAFETY: `self.ptr` is a live context; `llama_get_memory` returns its
        // (non-owning) memory handle, cleared in place.
        unsafe {
            let mem = ffi::llama_get_memory(self.ptr.as_ptr());
            if !mem.is_null() {
                ffi::llama_memory_clear(mem, true);
            }
        }
    }

    /// Decode `ids` as one batch with EVERY token flagged as an output, so every
    /// tapped tensor carries all `n_tokens` rows in token order. The tap fires
    /// during this call via the installed `cb_eval`.
    fn decode_all(&self, ids: &[i32]) -> Result<(), RebirthError> {
        self.clear_memory();
        let mut batch = Batch::new(ids.len() as i32)?;
        // `logits_last_only = false`: flag every token (the uniform-indexing trick).
        batch.fill(ids, 0, false);
        // SAFETY: `self.ptr` is a live trace context; `batch.raw` is a fully
        // populated batch whose arrays outlive the call (owned by `batch`).
        // `llama_decode` reads the batch by value; `ptr::read` bitwise-copies it
        // without giving up ownership of the backing arrays.
        let status = unsafe { ffi::llama_decode(self.ptr.as_ptr(), std::ptr::read(&batch.raw)) };
        if status != 0 {
            return Err(RebirthError::Trace {
                reason: format!(
                    "The engine failed to run the traced forward pass \
                     (llama_decode returned {status}). Try a shorter prompt, or reload \
                     the model with a larger context_length."
                ),
            });
        }
        Ok(())
    }
}

// --- the model-facing entry points ------------------------------------------

impl LoadedModel {
    /// Resolve the requested components to their engine tensor names for this
    /// model's architecture, erroring if the architecture supports none of them.
    fn resolve_spec(&self, spec: &CaptureSpec) -> Result<ResolvedSpec, RebirthError> {
        let arch = self.architecture();
        let mut names = Vec::with_capacity(spec.components.len());
        for &comp in &spec.components {
            match component_name(&arch, comp) {
                Some(name) => names.push((name, comp)),
                None => {
                    let supported_arch = matches!(arch.as_str(), "llama" | "qwen2" | "gemma3");
                    let reason = if !supported_arch {
                        format!(
                            "Activation tracing is not supported for the '{arch}' \
                             architecture (supported: llama, qwen2, gemma3)."
                        )
                    } else {
                        // Supported architecture, but this component is not observable by
                        // name at the current engine version: `attn_out` on qwen2/gemma3,
                        // which name only the pre-projection `kqv_out` — a different
                        // quantity, never substituted silently (D-014).
                        let available =
                            [Component::Residual, Component::MlpOut, Component::AttnOut]
                                .into_iter()
                                .filter(|&c| component_name(&arch, c).is_some())
                                .map(Component::as_str)
                                .collect::<Vec<_>>()
                                .join(", ");
                        format!(
                            "The '{}' component is not observable for a '{arch}' model at \
                             the current engine version: this architecture names only the \
                             pre-projection attention tensor, a different quantity that is \
                             not substituted silently. Available components: {available}. \
                             See ?llm_trace.",
                            comp.as_str()
                        )
                    };
                    return Err(RebirthError::Trace { reason });
                }
            }
        }
        Ok(ResolvedSpec {
            names,
            layers: spec.layers.clone(),
            n_embd: self.hidden_size().max(0) as usize,
        })
    }

    /// Validate every prompt (non-empty, in-vocabulary ids, fits the context) and
    /// return the longest token count (the trace context is sized to it). Runs
    /// before any capture allocation.
    fn validate_batches(&self, batches: &[&[i32]]) -> Result<usize, RebirthError> {
        let mut longest = 0usize;
        for ids in batches {
            self.validate_ids(ids)?;
            if ids.is_empty() {
                return Err(RebirthError::Trace {
                    reason: "Cannot trace an empty prompt: it has no tokens to run. \
                             Remove empty prompts, or provide some text."
                        .to_string(),
                });
            }
            self.check_fits(ids.len())?;
            longest = longest.max(ids.len());
        }
        Ok(longest)
    }

    /// Run one trace context over `batches`, pushing captured rows into `sink` and
    /// returning it filled. `pieces[i]` are prompt `i`'s token pieces (empty for
    /// the raw-id path). Prompts are processed sequentially (API-GRAMMAR §1.5).
    /// The shared core of the in-memory and spill entry points.
    fn run_capture(
        &self,
        batches: &[&[i32]],
        pieces: &[Vec<String>],
        spec: &CaptureSpec,
        resolved: ResolvedSpec,
        longest: usize,
        sink: RowSink,
    ) -> Result<RowSink, RebirthError> {
        // Size the context so each prompt decodes in one batch (clamped to the
        // handle's window, which every prompt already fits).
        let n_ctx = (longest.max(1)).min(self.context_length() as usize) as u32;

        // The capture state lives behind a stable raw pointer for the callback's
        // lifetime. `Box::into_raw` gives clear single-owner provenance; the guard
        // reclaims it on every exit path (including `?`, which drops the sink — for
        // a spill sink that joins its writer thread, so nothing is leaked).
        let state_ptr = Box::into_raw(Box::new(CaptureState::new(resolved, sink)));
        struct Reclaim(*mut CaptureState);
        impl Drop for Reclaim {
            fn drop(&mut self) {
                // SAFETY: `self.0` came from `Box::into_raw` and is reclaimed exactly
                // once (this guard drops once), after the trace context that
                // referenced it has been dropped.
                drop(unsafe { Box::from_raw(self.0) });
            }
        }
        let _reclaim = Reclaim(state_ptr);

        // `ctx` is declared after `_reclaim`, so on any early return it drops first
        // (tearing down the scheduler + callback) before the state box is reclaimed.
        let ctx = self.create_trace_context(n_ctx, trace_trampoline, state_ptr.cast::<c_void>())?;

        for (i, ids) in batches.iter().enumerate() {
            let positions = spec.positions.resolve(ids.len());
            let prompt_pieces = pieces.get(i).cloned().unwrap_or_default();
            // SAFETY: single-threaded; the callback is not running between decodes,
            // so this is the only live access to `*state_ptr` here.
            unsafe { (*state_ptr).begin_prompt(i as u32, positions, ids.len(), prompt_pieces) };
            self.trace_decode(&ctx, ids, state_ptr)?;
        }

        drop(ctx); // stop the callback referencing `state_ptr` before we move the sink out
                   // SAFETY: the callback can no longer run; take the filled sink.
        let sink =
            unsafe { std::mem::replace(&mut (*state_ptr).sink, RowSink::Memory(Vec::new())) };
        Ok(sink)
    }

    /// Capture into memory and return the rows (the in-budget path; no Arrow, no
    /// background thread). Shared by the raw-id entry points and the in-budget
    /// branch of the planned capture.
    fn capture_in_memory(
        &self,
        batches: &[&[i32]],
        pieces: &[Vec<String>],
        spec: &CaptureSpec,
    ) -> Result<Vec<CaptureRow>, RebirthError> {
        if batches.is_empty() {
            return Ok(Vec::new());
        }
        let resolved = self.resolve_spec(spec)?;
        let longest = self.validate_batches(batches)?;
        let sink = self.run_capture(
            batches,
            pieces,
            spec,
            resolved,
            longest,
            RowSink::Memory(Vec::new()),
        )?;
        match sink {
            RowSink::Memory(rows) => Ok(rows),
            #[cfg(feature = "spill")]
            RowSink::Spill(_) => unreachable!("capture_in_memory always uses a Memory sink"),
        }
    }

    /// One prompt's traced decode: run it, then surface a tap error (more specific
    /// than a bare decode status) before the decode's own error.
    fn trace_decode(
        &self,
        ctx: &TraceContext,
        ids: &[i32],
        state_ptr: *mut CaptureState,
    ) -> Result<(), RebirthError> {
        let decode = ctx.decode_all(ids);
        // SAFETY: single-threaded; the callback has finished for this decode.
        if let Some(err) = unsafe { (*state_ptr).error.take() } {
            return Err(err);
        }
        decode
    }

    /// The predicted in-memory capture size in bytes: `n_positions x n_layers x
    /// n_components x n_embd x 4`. `n_positions` sums each prompt's resolved
    /// positions, so `positions = "all"` is estimated exactly from the tokenized
    /// lengths (the count-then-decide half of the 16 GB rule).
    fn estimate_capture_bytes(
        &self,
        batches: &[&[i32]],
        spec: &CaptureSpec,
        resolved: &ResolvedSpec,
    ) -> u64 {
        let n_layers = match &resolved.layers {
            Some(v) => v.len() as u64,
            None => self.num_layers().max(0) as u64,
        };
        let n_components = resolved.names.len() as u64;
        let n_embd = resolved.n_embd as u64;
        let n_positions: u64 = batches
            .iter()
            .map(|ids| spec.positions.resolve(ids.len()).len() as u64)
            .sum();
        n_positions
            .saturating_mul(n_layers)
            .saturating_mul(n_components)
            .saturating_mul(n_embd)
            .saturating_mul(4)
    }

    /// Plan and run a capture per the 16 GB rule: validate, estimate, then decide
    /// (in budget → memory; over budget & `spill` → disk; over budget & no `spill`
    /// → `Oom` before any capture allocation). `pieces[i]` are prompt `i`'s token
    /// pieces (empty for the raw-id path). The shared core behind the spill-aware
    /// entry points.
    fn trace_capture_planned(
        &self,
        batches: &[&[i32]],
        pieces: &[Vec<String>],
        spec: &CaptureSpec,
        plan: &SpillPlan,
    ) -> Result<TraceOutput, RebirthError> {
        if batches.is_empty() {
            return Ok(TraceOutput::Memory {
                rows: Vec::new(),
                positions_recycled: false,
            });
        }
        let resolved = self.resolve_spec(spec)?;
        let longest = self.validate_batches(batches)?;
        let estimate = self.estimate_capture_bytes(batches, spec, &resolved);

        // API-GRAMMAR §4 recycling signal: an explicit positions vector applied to
        // prompts of differing lengths where some position falls out of range. The
        // engine knows each prompt's token count, so it is decided here and reported
        // to R (which raises the single warning).
        let token_counts: Vec<usize> = batches.iter().map(|ids| ids.len()).collect();
        let positions_recycled = spec.positions.recycled_out_of_range(&token_counts);

        if estimate > plan.budget_bytes {
            if !plan.spill {
                return Err(RebirthError::Oom {
                    estimate_bytes: estimate,
                    budget_bytes: plan.budget_bytes,
                    suggestion: "Capture less -- set positions = \"last\", narrow \
                                 layers to a band, or drop components."
                        .to_string(),
                });
            }
            #[cfg(feature = "spill")]
            {
                return self.capture_spilled(
                    batches,
                    pieces,
                    spec,
                    resolved,
                    longest,
                    plan,
                    positions_recycled,
                );
            }
            #[cfg(not(feature = "spill"))]
            {
                let _ = (pieces, longest);
                return Err(RebirthError::Oom {
                    estimate_bytes: estimate,
                    budget_bytes: plan.budget_bytes,
                    suggestion: "This build was compiled without disk-spill support \
                                 (the `spill` feature is off), so capture less."
                        .to_string(),
                });
            }
        }

        // In budget: capture into memory (no Arrow, no thread).
        let sink = self.run_capture(
            batches,
            pieces,
            spec,
            resolved,
            longest,
            RowSink::Memory(Vec::new()),
        )?;
        match sink {
            RowSink::Memory(rows) => Ok(TraceOutput::Memory {
                rows,
                positions_recycled,
            }),
            #[cfg(feature = "spill")]
            RowSink::Spill(_) => unreachable!("in-budget branch always uses a Memory sink"),
        }
    }

    /// Stream an over-budget capture to an Arrow-IPC file on the writer thread and
    /// return a [`SpillReport`]. A capture or write failure removes the partial
    /// file so a failed trace leaves nothing on disk.
    #[cfg(feature = "spill")]
    #[allow(clippy::too_many_arguments)]
    fn capture_spilled(
        &self,
        batches: &[&[i32]],
        pieces: &[Vec<String>],
        spec: &CaptureSpec,
        resolved: ResolvedSpec,
        longest: usize,
        plan: &SpillPlan,
        positions_recycled: bool,
    ) -> Result<TraceOutput, RebirthError> {
        // Row-count metadata for the object's print/summary (no data load needed).
        let n_positions: u64 = batches
            .iter()
            .map(|ids| spec.positions.resolve(ids.len()).len() as u64)
            .sum();
        let mut positions_union: Vec<u32> = batches
            .iter()
            .flat_map(|ids| spec.positions.resolve(ids.len()))
            .collect();
        positions_union.sort_unstable();
        positions_union.dedup();
        let layers_union: Vec<u32> = match &resolved.layers {
            Some(v) => {
                let mut v = v.clone();
                v.sort_unstable();
                v.dedup();
                v
            }
            None => (0..self.num_layers().max(0) as u32).collect(),
        };
        let n_embd = resolved.n_embd;

        let sink = crate::spill::SpillSink::new(crate::spill::SpillMeta {
            path: plan.spill_path.clone(),
            trace_id: plan.trace_id.clone(),
            model: plan.model.clone(),
            spec: plan.spec_key.clone(),
            n_embd,
        })?;

        let filled = self
            .run_capture(
                batches,
                pieces,
                spec,
                resolved,
                longest,
                RowSink::Spill(sink),
            )
            .map_err(|err| {
                let _ = std::fs::remove_file(&plan.spill_path);
                err
            })?;
        let n_rows = match filled {
            RowSink::Spill(sink) => sink.finish().map_err(|err| {
                let _ = std::fs::remove_file(&plan.spill_path);
                err
            })?,
            RowSink::Memory(_) => unreachable!("spill branch always uses a Spill sink"),
        };

        Ok(TraceOutput::Spilled(SpillReport {
            path: plan.spill_path.clone(),
            n_rows,
            n_positions,
            layers: layers_union,
            positions: positions_union,
            components: spec.components.clone(),
            n_embd,
            trace_id: plan.trace_id.clone(),
            positions_recycled,
        }))
    }

    /// Exact-value building block for the synthetic golden (`synthetic_trace.rs`):
    /// the per-(layer, component, position) activations for one raw id sequence, in
    /// memory. No tokenizer needed; rows carry no token pieces.
    pub fn activations(
        &self,
        ids: &[i32],
        spec: &CaptureSpec,
    ) -> Result<Vec<CaptureRow>, RebirthError> {
        self.capture_in_memory(&[ids], &[], spec)
    }

    /// Trace pre-tokenized id batches (no tokenizer required); rows carry no token
    /// pieces. One trace context serves the whole batch.
    pub fn trace_token_batch(
        &self,
        batches: &[&[i32]],
        spec: &CaptureSpec,
    ) -> Result<Vec<CaptureRow>, RebirthError> {
        self.capture_in_memory(batches, &[], spec)
    }

    /// Spill-aware raw-id trace (no tokenizer needed; rows carry no token pieces):
    /// estimate the size, then capture into memory or stream to disk or refuse
    /// (`Oom`). The golden/spill Rust tests drive the spill path through here on the
    /// `no_vocab` synthetic model.
    pub fn trace_token_batch_spill(
        &self,
        batches: &[&[i32]],
        spec: &CaptureSpec,
        plan: &SpillPlan,
    ) -> Result<TraceOutput, RebirthError> {
        self.trace_capture_planned(batches, &[], spec, plan)
    }

    /// The R-facing entry: tokenize each text (`add_special = true`,
    /// `parse_special = false`, as for embeddings), estimate the capture's size
    /// from the token counts, then capture into memory (in budget), stream to disk
    /// (`spill = TRUE` over budget), or refuse before allocating (`spill = FALSE`
    /// over budget → `Oom`). The count → estimate → decide → capture ordering keeps
    /// a full trace from OOM-ing the session (the 16 GB rule). Requires a tokenizer
    /// (a `no_vocab` model raises `rebirth_error_tokenize`).
    pub fn trace_texts_spill(
        &self,
        texts: &[&str],
        spec: &CaptureSpec,
        plan: &SpillPlan,
    ) -> Result<TraceOutput, RebirthError> {
        self.require_tokenizer()?;
        if texts.is_empty() {
            return Ok(TraceOutput::Memory {
                rows: Vec::new(),
                positions_recycled: false,
            });
        }

        // Count: tokenize once (its counts drive the estimate; the same ids and
        // pieces are reused for capture, so nothing is tokenized twice).
        let mut encodings = Vec::with_capacity(texts.len());
        for &text in texts {
            encodings.push(self.encode(text, true, false)?);
        }
        let batches: Vec<&[i32]> = encodings.iter().map(|e| e.ids.as_slice()).collect();
        let pieces: Vec<Vec<String>> = encodings.iter().map(|e| e.pieces.clone()).collect();
        self.trace_capture_planned(&batches, &pieces, spec, plan)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn component_parses_the_three_names_and_rejects_others() {
        assert_eq!(Component::parse("residual"), Some(Component::Residual));
        assert_eq!(Component::parse("attn_out"), Some(Component::AttnOut));
        assert_eq!(Component::parse("mlp_out"), Some(Component::MlpOut));
        assert_eq!(Component::parse("banana"), None);
        assert_eq!(Component::parse(""), None);
        // Round-trips through the R-facing name.
        for c in [Component::Residual, Component::AttnOut, Component::MlpOut] {
            assert_eq!(Component::parse(c.as_str()), Some(c));
        }
    }

    #[test]
    fn parse_tensor_name_splits_base_and_zero_based_layer() {
        // The canonical case the name-parse test in rebirth-ffi carries forward:
        // "l_out-7" is engine layer il = 7 (surfaced as API layer 8 there).
        assert_eq!(parse_tensor_name("l_out-7"), Some(("l_out", 7)));
        assert_eq!(parse_tensor_name("attn_out-0"), Some(("attn_out", 0)));
        assert_eq!(parse_tensor_name("kqv_out-31"), Some(("kqv_out", 31)));
        assert_eq!(parse_tensor_name("ffn_out-10"), Some(("ffn_out", 10)));
        // Not per-layer tensors (final norm / output, or malformed).
        assert_eq!(parse_tensor_name("result_norm"), None);
        assert_eq!(parse_tensor_name("l_out-"), None);
        assert_eq!(parse_tensor_name("l_out-x"), None);
    }

    #[test]
    fn component_names_are_per_architecture_never_a_union() {
        // residual / mlp_out are consistent across the supported architectures.
        for arch in ["llama", "qwen2", "gemma3"] {
            assert_eq!(component_name(arch, Component::Residual), Some("l_out"));
            assert_eq!(component_name(arch, Component::MlpOut), Some("ffn_out"));
        }
        // attn_out (D-014) = the post-projection output. Only llama names it; qwen2 and
        // gemma3 name only the pre-Wo `kqv_out` (a different quantity), so attn_out is
        // NOT observable there and returns None -> rebirth_error_trace, never a silent
        // substitute. A `{attn_out, kqv_out}` union would also wrongly capture the pre-Wo
        // tensor on llama, which carries `kqv_out` too.
        assert_eq!(
            component_name("llama", Component::AttnOut),
            Some("attn_out")
        );
        assert_eq!(component_name("qwen2", Component::AttnOut), None);
        assert_eq!(component_name("gemma3", Component::AttnOut), None);
        // Unsupported architecture: no name for any component (-> rebirth_error_trace).
        for comp in [Component::Residual, Component::AttnOut, Component::MlpOut] {
            assert_eq!(component_name("bert", comp), None);
        }
    }

    #[test]
    fn positions_resolve_against_the_token_count() {
        assert_eq!(Positions::Last.resolve(8), vec![7]);
        assert_eq!(Positions::Last.resolve(0), Vec::<u32>::new());
        assert_eq!(Positions::All.resolve(3), vec![0, 1, 2]);
        // Explicit indices are kept in-range; out-of-range ones are dropped.
        assert_eq!(Positions::Explicit(vec![0, 2, 9]).resolve(4), vec![0, 2]);
    }

    #[test]
    fn explicit_positions_recycling_signal_fires_only_on_a_dropped_position() {
        // The API-GRAMMAR §4 warning signal: an explicit vector recycled across
        // prompts of differing lengths where a position falls out of range.
        let p = Positions::Explicit(vec![0, 7]);
        // pos 7 (0-based) is valid for the 8-token prompt, out of range for the
        // 3-token one -> reported.
        assert!(p.recycled_out_of_range(&[8, 3]));
        assert!(p.recycled_out_of_range(&[5])); // out of range for a single short prompt
                                                // All positions in range for every prompt -> not reported (even if lengths
                                                // differ, nothing was dropped).
        assert!(!p.recycled_out_of_range(&[8, 8]));
        assert!(!p.recycled_out_of_range(&[8]));
        // "last"/"all" are resolved per prompt and are never out of range.
        assert!(!Positions::Last.recycled_out_of_range(&[3, 8]));
        assert!(!Positions::All.recycled_out_of_range(&[3, 8]));
    }

    #[test]
    fn resolved_spec_matches_only_requested_names() {
        // A llama attn_out spec must match `attn_out` but NOT the also-present
        // `kqv_out` (the union-alias bug the golden gate would catch).
        let resolved = ResolvedSpec {
            names: vec![("attn_out", Component::AttnOut)],
            layers: Some(vec![0]),
            n_embd: 32,
        };
        assert_eq!(resolved.component_for("attn_out"), Some(Component::AttnOut));
        assert_eq!(resolved.component_for("kqv_out"), None);
        assert!(resolved.wants_layer(0));
        assert!(!resolved.wants_layer(1));
    }
}
