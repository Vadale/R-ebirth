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

/// Expansion factor from an f32 activation's engine bytes to its peak resident cost
/// in the long-format R `data.frame` the caller receives (D-017). Each captured
/// value becomes one long-format row of exactly 40 bytes — four i32 columns
/// (`prompt_id`/`token_pos`/`layer`/`neuron`, 4 B each), one f64 `value` (8 B), and
/// two character columns (`token`/`component`, 8 B pointers each into R's shared
/// CHARSXP pool) — i.e. 10x the 4-byte f32 asymptotically. `11` upper-bounds this for
/// every *real*-model trace (hidden_size >= 896 -> <= 10.65x) and every budget-relevant
/// large capture (ratio -> 10.0x); tiny sub-600-row synthetic traces (hidden=32) reach
/// ~27.75x but are < ~22 KB, far under any budget. The budget is compared against this
/// materialized cost, not the f32 bytes (the H-1 fix). R pins the identical value
/// in `TRACE_MATERIALIZED_EXPANSION` (`trace.R`), each side unit-tested — a one-sided
/// change breaks the R/engine symmetry the spill decision relies on (audit P-5).
pub const TRACE_MATERIALIZED_EXPANSION: u64 = 11;

/// One activation component of a transformer block. The R API exposes exactly
/// these three (`API-GRAMMAR.md` §2); the boundary parses the string names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Component {
    /// The block-output residual stream (`l_out-<il>`), post-attention + FFN.
    Residual,
    /// The attention sub-layer output AFTER the output projection `Wo`
    /// (TransformerLens `hook_attn_out`, D-014). Only llama NAMES it
    /// (`attn_out-<il>`); the other supported archs expose only the pre-`Wo`
    /// tensor (a different quantity), so `attn_out` there is a classed error —
    /// see [`component_name`].
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
            // across prompts of differing lengths, API-GRAMMAR §4). De-duplicate
            // defensively (M-1): a repeated position would otherwise emit duplicate
            // capture rows that as.matrix() then mis-assembles. R already
            // sort(unique())s explicit positions, so this guards a direct engine
            // caller; sorting is harmless (rows are re-sorted by (prompt, pos)
            // downstream) and it also keeps the spilled n_positions count exact.
            Positions::Explicit(v) => {
                let mut out: Vec<u32> = v
                    .iter()
                    .copied()
                    .filter(|&p| (p as usize) < n_tokens)
                    .collect();
                out.sort_unstable();
                out.dedup();
                out
            }
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
/// Every arm is an EXPLICIT per-architecture name derived from the model graph
/// source (D-014: never name-trusting — a name is used only after checking, at the
/// b9726 pin, that the tensor carrying it is the quantity the component defines).
/// Exactly ONE name per (arch, component), never a union: on a llama graph BOTH the
/// post-`Wo` `attn_out-<il>` AND the pre-`Wo` `kqv_out-<il>` exist, so a `{attn_out,
/// kqv_out}` alias would capture the wrong/both tensors. `None` → the caller raises
/// `rebirth_error_trace`, never a silent or wrong capture.
///
/// Sources verified at b9726 (`rebirth/src/llama.cpp/src/models/`):
/// - `residual` = the block-output residual stream `l_out-<il>` (after `build_cvec`),
///   named uniformly on every supported arch: `llama.cpp:224`, `qwen2.cpp:130`,
///   `gemma3.cpp:195`, `qwen3.cpp:138`, `qwen35.cpp:202`, `gemma4.cpp:398` — the last
///   OUTSIDE gemma4's dense/MoE branch, so it covers every layer.
/// - `mlp_out` = the FFN sub-layer output `ffn_out-<il>` before the residual add:
///   `llama.cpp:195`, `qwen2.cpp:125`, `gemma3.cpp:185`, `qwen3.cpp:133`,
///   `qwen35.cpp:195`. NOT gemma4: there `ffn_out` is emitted only on DENSE layers
///   (`gemma4.cpp:357`, inside the non-MoE `else`) while MoE layers name
///   `ffn_moe_combined-<il>` (`gemma4.cpp:344`), so an `ffn_out` match would silently
///   drop every MoE layer — gemma4 `mlp_out` → `None`.
/// - `attn_out` (D-014) = the post-projection (`Wo`) attention output, `hidden_size`
///   wide (TransformerLens `hook_attn_out`). Only llama NAMES it (`attn_out-<il>`,
///   `llama.cpp:172`). qwen2/gemma3/qwen3/qwen35 build attention through the shared
///   `build_attn` and name only the pre-`Wo` `kqv_out-<il>` (a different quantity, and
///   not `hidden_size` wide on gemma3). gemma4 is the dangerous COLLISION: it names a
///   tensor `attn_out-<il>` (`gemma4.cpp:288`) but that is the mid-block residual sum
///   `ggml_add(attn_post_norm(attn), inpL)`, NOT the post-`Wo` output — matching it
///   would silently mislabel a different quantity (the exact D-014 failure). So
///   `attn_out` stays llama-only; every other arch → `None`.
fn component_name(arch: &str, comp: Component) -> Option<&'static str> {
    match comp {
        Component::Residual => match arch {
            "llama" | "qwen2" | "gemma3" | "qwen3" | "qwen35" | "gemma4" => Some("l_out"),
            _ => None,
        },
        Component::MlpOut => match arch {
            // gemma4 is intentionally absent: `ffn_out` is dense-only there (a partial
            // capture that would silently miss MoE layers), so gemma4 `mlp_out` errors.
            "llama" | "qwen2" | "gemma3" | "qwen3" | "qwen35" => Some("ffn_out"),
            _ => None,
        },
        Component::AttnOut => match arch {
            // llama-only: the ONLY arch that names the post-`Wo` output. gemma4's
            // same-named `attn_out-<il>` is a different quantity (see above) and is
            // deliberately NOT matched here.
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
                    // "Traceable at all" == the residual stream is observable; every
                    // supported decoder names `l_out-<il>`, so this one query is the
                    // single source of truth (no second arch list to drift, hard rule
                    // 8f). The human-readable list below is pinned to this matcher by
                    // the `arch_allow_list_message_matches_the_matcher` test.
                    let traceable_arch = component_name(&arch, Component::Residual).is_some();
                    let reason = if !traceable_arch {
                        format!(
                            "Activation tracing is not supported for the '{arch}' \
                             architecture (supported: llama, qwen2, gemma3, qwen3, \
                             qwen35, gemma4)."
                        )
                    } else {
                        // A traceable architecture, but this specific component is not
                        // observable by name at the current engine version and is NEVER
                        // substituted silently (D-014): e.g. `attn_out` where only the
                        // pre-`Wo` tensor is named, or gemma4 `mlp_out` where `ffn_out`
                        // covers only the dense layers.
                        let available =
                            [Component::Residual, Component::MlpOut, Component::AttnOut]
                                .into_iter()
                                .filter(|&c| component_name(&arch, c).is_some())
                                .map(Component::as_str)
                                .collect::<Vec<_>>()
                                .join(", ");
                        format!(
                            "The '{}' component is not observable for a '{arch}' model at \
                             the current engine version, and is never substituted silently. \
                             Available components: {available}. See ?llm_trace.",
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
        positions: &[Vec<u32>],
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
            // The positions were resolved once by the caller (the identical Vecs the
            // budget estimate summed, D-017); clone this prompt's set into the state.
            let prompt_positions = positions[i].clone();
            let prompt_pieces = pieces.get(i).cloned().unwrap_or_default();
            // SAFETY: single-threaded; the callback is not running between decodes,
            // so this is the only live access to `*state_ptr` here.
            unsafe {
                (*state_ptr).begin_prompt(i as u32, prompt_positions, ids.len(), prompt_pieces)
            };
            self.trace_decode(&ctx, ids, state_ptr)?;
        }

        drop(ctx); // stop the callback referencing `state_ptr` before we move the sink out
                   // SAFETY: the callback can no longer run; take the filled sink.
        let sink =
            unsafe { std::mem::replace(&mut (*state_ptr).sink, RowSink::Memory(Vec::new())) };
        Ok(sink)
    }

    /// Capture into memory and return the rows (the in-budget path; no Arrow, no
    /// background thread). Used by the raw-id `activations` building block.
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
        let positions: Vec<Vec<u32>> = batches
            .iter()
            .map(|ids| spec.positions.resolve(ids.len()))
            .collect();
        let sink = self.run_capture(
            batches,
            pieces,
            &positions,
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

    /// The predicted peak resident size of the capture as the caller receives it, in
    /// bytes: the f32 activation bytes `n_positions x n_layers x n_components x n_embd
    /// x 4` times [`TRACE_MATERIALIZED_EXPANSION`] (D-017), i.e. the cost of the
    /// materialized long-format R `data.frame`, not the engine's f32 host buffers
    /// (the H-1 fix — the f32 basis under-counted the real object ~10x). `n_positions`
    /// sums the pre-resolved per-prompt `positions` (the identical Vecs the capture
    /// then consumes, so the estimate and the capture measure the same set — D-017),
    /// so `positions = "all"` is estimated exactly from the tokenized lengths (the
    /// count-then-decide half of the 16 GB rule). The R pre-check
    /// (`check_trace_budget`) computes the identical quantity.
    fn estimate_capture_bytes(&self, positions: &[Vec<u32>], resolved: &ResolvedSpec) -> u64 {
        let n_layers = match &resolved.layers {
            Some(v) => v.len() as u64,
            None => self.num_layers().max(0) as u64,
        };
        let n_components = resolved.names.len() as u64;
        let n_embd = resolved.n_embd as u64;
        let n_positions: u64 = positions.iter().map(|p| p.len() as u64).sum();
        n_positions
            .saturating_mul(n_layers)
            .saturating_mul(n_components)
            .saturating_mul(n_embd)
            .saturating_mul(4)
            .saturating_mul(TRACE_MATERIALIZED_EXPANSION)
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
        // Resolve each prompt's capture positions ONCE here; the budget estimate and
        // the capture below then share the identical per-prompt Vecs, so they measure
        // the same set by construction (D-017) rather than re-resolving independently.
        let positions: Vec<Vec<u32>> = batches
            .iter()
            .map(|ids| spec.positions.resolve(ids.len()))
            .collect();
        let estimate = self.estimate_capture_bytes(&positions, &resolved);

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
                    &positions,
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
            &positions,
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
        positions: &[Vec<u32>],
        spec: &CaptureSpec,
        resolved: ResolvedSpec,
        longest: usize,
        plan: &SpillPlan,
        positions_recycled: bool,
    ) -> Result<TraceOutput, RebirthError> {
        // Row-count metadata for the object's print/summary (no data load needed).
        // Uses the same pre-resolved positions the budget estimate summed (D-017).
        let n_positions: u64 = positions.iter().map(|p| p.len() as u64).sum();
        let mut positions_union: Vec<u32> = positions.iter().flatten().copied().collect();
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
                positions,
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
        // residual (`l_out`) is observable on EVERY supported arch, including the
        // WP7.5a additions qwen3/qwen35/gemma4 (gemma4's `l_out` is named outside its
        // dense/MoE branch, so it covers every layer).
        for arch in ["llama", "qwen2", "gemma3", "qwen3", "qwen35", "gemma4"] {
            assert_eq!(
                component_name(arch, Component::Residual),
                Some("l_out"),
                "residual on {arch}"
            );
        }
        // mlp_out (`ffn_out`) is observable on the dense archs, INCLUDING qwen3/qwen35,
        // but NOT gemma4 (there `ffn_out` is dense-only; MoE layers name
        // `ffn_moe_combined`, so a match would silently drop them).
        for arch in ["llama", "qwen2", "gemma3", "qwen3", "qwen35"] {
            assert_eq!(
                component_name(arch, Component::MlpOut),
                Some("ffn_out"),
                "mlp_out on {arch}"
            );
        }
        assert_eq!(component_name("gemma4", Component::MlpOut), None);
        // attn_out (D-014) = the post-projection output. Only llama names it; every
        // other arch names only the pre-Wo `kqv_out` (a different quantity), so
        // attn_out is NOT observable there and returns None -> rebirth_error_trace,
        // never a silent substitute. A `{attn_out, kqv_out}` union would also wrongly
        // capture the pre-Wo tensor on llama, which carries `kqv_out` too.
        assert_eq!(
            component_name("llama", Component::AttnOut),
            Some("attn_out")
        );
        for arch in ["qwen2", "gemma3", "qwen3", "qwen35", "gemma4"] {
            assert_eq!(
                component_name(arch, Component::AttnOut),
                None,
                "attn_out on {arch}"
            );
        }
        // Unsupported architecture: no name for any component (-> rebirth_error_trace).
        for comp in [Component::Residual, Component::AttnOut, Component::MlpOut] {
            assert_eq!(component_name("bert", comp), None);
        }
    }

    #[test]
    fn gemma4_attn_out_name_collision_is_rejected() {
        // ADVERSARIAL (D-021): gemma4 NAMES a tensor `attn_out-<il>` (gemma4.cpp:288),
        // but it is the mid-block residual sum `ggml_add(attn_post_norm(attn), inpL)`,
        // NOT the post-`Wo` output D-014 defines. The matcher must NOT match it — else
        // `llm_trace(components = "attn_out")` on a gemma4 model would silently capture
        // and mislabel a different quantity. Lock the collision out forever: attn_out on
        // gemma4 is None, so the boundary raises rebirth_error_trace.
        assert_eq!(component_name("gemma4", Component::AttnOut), None);
        // And the tensor gemma4 DOES name (`attn_out`) is never in a resolved spec for
        // any requested gemma4 component, so the capture callback cannot match it.
        for comp in [Component::Residual, Component::MlpOut] {
            assert_ne!(component_name("gemma4", comp), Some("attn_out"));
        }
    }

    #[test]
    fn arch_allow_list_message_matches_the_matcher() {
        // Twin-pin (hard rule 8f): the human-readable "supported: ..." list in the
        // resolve_spec allow-list message must name exactly the archs the matcher can
        // trace (residual observable). If someone adds an arch to `component_name` but
        // not the message (or vice versa), this fails. Unsupported archs stay None.
        for arch in ["llama", "qwen2", "gemma3", "qwen3", "qwen35", "gemma4"] {
            assert!(
                component_name(arch, Component::Residual).is_some(),
                "message lists {arch} as supported, so its residual must be observable"
            );
        }
        for arch in ["bert", "mamba", "rwkv", "qwen2moe", "gemma4-assistant"] {
            assert!(
                component_name(arch, Component::Residual).is_none(),
                "{arch} is not in the supported list, so it must not be traceable"
            );
        }
    }

    #[test]
    fn positions_resolve_against_the_token_count() {
        assert_eq!(Positions::Last.resolve(8), vec![7]);
        assert_eq!(Positions::Last.resolve(0), Vec::<u32>::new());
        assert_eq!(Positions::All.resolve(3), vec![0, 1, 2]);
        // Explicit indices are kept in-range; out-of-range ones are dropped.
        assert_eq!(Positions::Explicit(vec![0, 2, 9]).resolve(4), vec![0, 2]);
        // Duplicate and unsorted explicit positions are de-duplicated and sorted
        // (M-1 defense): a repeated position must not emit duplicate capture rows.
        assert_eq!(
            Positions::Explicit(vec![2, 0, 2, 9, 0]).resolve(4),
            vec![0, 2]
        );
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
    fn materialized_expansion_factor_is_the_pinned_value() {
        // Twin pin (audit P-5): R's TRACE_MATERIALIZED_EXPANSION (trace.R) pins the
        // identical value in its own test, so a one-sided change to the budget
        // expansion factor breaks one of the two tests and the R/engine spill decision
        // cannot silently diverge. Value justified in the const's doc comment.
        assert_eq!(TRACE_MATERIALIZED_EXPANSION, 11);
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
