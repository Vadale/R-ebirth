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
//! Bounded, single-threaded (WP4): capture accumulates into a pre-sized `Vec`
//! (the R boundary budget-checks the estimate first); there is no background sink
//! thread yet — the Arrow-IPC spill and its D-008 G2 thread checkpoint are WP4
//! Step 5.

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
    /// The token piece at `token_pos`, filled by the text-facing [`LoadedModel::trace_texts`];
    /// `None` for the raw-id [`LoadedModel::activations`] path (a `no_vocab` model
    /// has no pieces — the R `token` column is then `NA`).
    pub token: Option<String>,
    pub values: Vec<f32>,
}

/// The engine tensor name to match for `comp` on architecture `arch`, or `None`
/// when this architecture is not supported for tracing.
///
/// Per architecture, exactly ONE name (never a union): on a llama graph BOTH the
/// post-Wo `attn_out-<il>` AND the pre-Wo `kqv_out-<il>` exist, so a `{attn_out,
/// kqv_out}` alias would capture the wrong/both tensors. `residual`/`mlp_out` are
/// consistent across the supported architectures; `attn_out` is not — llama names
/// the post-projection output `attn_out`, while qwen2/gemma3 build attention via
/// the shared `build_attn` helper whose only per-layer attention-output tensor is
/// `kqv_out` (verified against b9726: `src/models/{llama,qwen2,gemma3}.cpp`,
/// `src/llama-graph.cpp`). An unsupported architecture returns `None` → the caller
/// raises `rebirth_error_trace`, never a silent empty capture.
fn component_name(arch: &str, comp: Component) -> Option<&'static str> {
    let supported = matches!(arch, "llama" | "qwen2" | "gemma3");
    match comp {
        Component::Residual => supported.then_some("l_out"),
        Component::MlpOut => supported.then_some("ffn_out"),
        Component::AttnOut => match arch {
            "llama" => Some("attn_out"),
            "qwen2" | "gemma3" => Some("kqv_out"),
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
    /// This prompt's token count (the expected row count of every tapped tensor).
    n_tokens: usize,
    rows: Vec<CaptureRow>,
    /// Reused host buffer for one tensor's `n_tokens * n_embd` f32.
    scratch: Vec<f32>,
    /// The first capture failure, surfaced by the engine after the decode returns
    /// (a tap error also returns `false` to cancel the remaining compute).
    error: Option<RebirthError>,
}

impl CaptureState {
    fn new(resolved: ResolvedSpec) -> Self {
        CaptureState {
            resolved,
            prompt_id: 0,
            positions: Vec::new(),
            n_tokens: 0,
            rows: Vec::new(),
            scratch: Vec::new(),
            error: None,
        }
    }

    /// Point the state at a new prompt before its decode (rows keep accumulating).
    fn begin_prompt(&mut self, prompt_id: u32, positions: Vec<u32>, n_tokens: usize) {
        self.prompt_id = prompt_id;
        self.positions = positions;
        self.n_tokens = n_tokens;
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

        // Index-based to avoid borrowing `self.positions`/`self.scratch` across the
        // `self.rows` push.
        for i in 0..self.positions.len() {
            let p = self.positions[i];
            let start = (p as usize) * n_embd;
            let values = self.scratch[start..start + n_embd].to_vec();
            self.rows.push(CaptureRow {
                prompt_id: self.prompt_id,
                token_pos: p,
                layer: il,
                component,
                token: None,
                values,
            });
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
                    return Err(RebirthError::Trace {
                        reason: format!(
                            "The '{}' component cannot be traced for a '{arch}' model. \
                             Activation tracing supports the llama, qwen2, and gemma3 \
                             architectures; this model's architecture is not among them.",
                            comp.as_str()
                        ),
                    })
                }
            }
        }
        Ok(ResolvedSpec {
            names,
            layers: spec.layers.clone(),
            n_embd: self.hidden_size().max(0) as usize,
        })
    }

    /// `RebirthError::ContextOverflow` if a prompt of `len` tokens does not fit the
    /// context window (checked before any allocation).
    fn check_trace_fits(&self, len: usize) -> Result<(), RebirthError> {
        let ctx = self.context_length();
        if len as u64 > ctx as u64 {
            return Err(RebirthError::ContextOverflow {
                prompt_tokens: len as u32,
                context_length: ctx,
                overflow: len as u32 - ctx,
            });
        }
        Ok(())
    }

    /// Trace a batch of pre-tokenized id sequences with one trace context, capturing
    /// per the spec. The shared core of [`activations`](Self::activations) and
    /// [`trace_texts`](Self::trace_texts); rows carry no token pieces (the text path
    /// fills them). Prompts are processed sequentially (API-GRAMMAR §1.5).
    fn trace_sequences(
        &self,
        batches: &[&[i32]],
        spec: &CaptureSpec,
    ) -> Result<Vec<CaptureRow>, RebirthError> {
        if batches.is_empty() {
            return Ok(Vec::new());
        }
        let resolved = self.resolve_spec(spec)?;

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
            self.check_trace_fits(ids.len())?;
            longest = longest.max(ids.len());
        }
        // Size the context so each prompt decodes in one batch (clamped to the
        // handle's window, which every prompt already fits).
        let n_ctx = (longest.max(1)).min(self.context_length() as usize) as u32;

        // The capture state lives behind a stable raw pointer for the callback's
        // lifetime. `Box::into_raw` gives clear single-owner provenance; the guard
        // reclaims it on every exit path (including `?`).
        let state_ptr = Box::into_raw(Box::new(CaptureState::new(resolved)));
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
            // SAFETY: single-threaded; the callback is not running between decodes,
            // so this is the only live access to `*state_ptr` here.
            unsafe { (*state_ptr).begin_prompt(i as u32, positions, ids.len()) };
            self.trace_decode(&ctx, ids, state_ptr)?;
        }

        drop(ctx); // stop the callback referencing `state_ptr` before we move rows out
                   // SAFETY: the callback can no longer run; take the accumulated rows.
        let rows = unsafe { std::mem::take(&mut (*state_ptr).rows) };
        Ok(rows)
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

    /// Exact-value building block for the synthetic golden (`synthetic_trace.rs`):
    /// the per-(layer, component, position) activations for one raw id sequence, in
    /// memory. No tokenizer needed; rows carry no token pieces.
    pub fn activations(
        &self,
        ids: &[i32],
        spec: &CaptureSpec,
    ) -> Result<Vec<CaptureRow>, RebirthError> {
        self.trace_sequences(&[ids], spec)
    }

    /// Trace pre-tokenized id batches (no tokenizer required); rows carry no token
    /// pieces. One trace context serves the whole batch.
    pub fn trace_token_batch(
        &self,
        batches: &[&[i32]],
        spec: &CaptureSpec,
    ) -> Result<Vec<CaptureRow>, RebirthError> {
        self.trace_sequences(batches, spec)
    }

    /// The R-facing entry: tokenize each text (`add_special = true`,
    /// `parse_special = false`, as for embeddings) then trace, attaching each
    /// captured position's token piece. Requires a tokenizer (a `no_vocab` model
    /// raises `rebirth_error_tokenize`).
    pub fn trace_texts(
        &self,
        texts: &[&str],
        spec: &CaptureSpec,
    ) -> Result<Vec<CaptureRow>, RebirthError> {
        self.require_tokenizer()?;

        let mut encodings = Vec::with_capacity(texts.len());
        for &text in texts {
            encodings.push(self.encode(text, true, false)?);
        }
        let batches: Vec<&[i32]> = encodings.iter().map(|e| e.ids.as_slice()).collect();
        let mut rows = self.trace_sequences(&batches, spec)?;

        // Attach the token piece for each captured (prompt, position).
        for row in &mut rows {
            if let Some(enc) = encodings.get(row.prompt_id as usize) {
                row.token = enc.pieces.get(row.token_pos as usize).cloned();
            }
        }
        Ok(rows)
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
        // attn_out is architecture-dependent: llama names the post-Wo output
        // `attn_out`; qwen2/gemma3 expose only the pre-Wo `kqv_out`. Matching a
        // single name (not a union) keeps the llama capture off the pre-Wo tensor.
        assert_eq!(
            component_name("llama", Component::AttnOut),
            Some("attn_out")
        );
        assert_eq!(component_name("qwen2", Component::AttnOut), Some("kqv_out"));
        assert_eq!(
            component_name("gemma3", Component::AttnOut),
            Some("kqv_out")
        );
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
