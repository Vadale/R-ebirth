//! Runtime sentinel intervention probe (D-021 §1.3): before returning a steered /
//! ablated handle, prove on a throwaway context that the intervention mechanism
//! actually takes effect on THIS model at the requested layers — so a
//! standard-residual decoder is enabled while a model where interventions would
//! silently no-op (the D-012 worst case) is refused loudly. This supersedes the
//! removed D-016 hard arch allow-list.
//!
//! Reuses existing machinery only (no new FFI symbol, no new vendored patch): the
//! eval-callback tap (`cb_eval`, as `llm_trace` uses to observe `l_out-<il>`),
//! `llama_set_adapter_cvec` (steering) and `rebirth_set_intervene` (ablation) —
//! applied through [`InterventionSpec::apply_to_context`], the same code path the
//! real derivation uses. On a fresh trace context it decodes one sentinel token and
//! checks, per requested layer `l`:
//!
//! - **ablation-pin** (absolute): a sentinel ablation pins `l_out-<l>[k]` to a
//!   constant `s`; the captured value must equal `s`. Proves `build_cvec` is invoked
//!   in this model's graph, our patched hook fires, and it acts on the SAME tensor
//!   `llm_trace` reports as the residual.
//! - **steer-shift** (relative to a clean base decode): a sentinel control vector
//!   `ε·e_k` at layer `l` must move `l_out-<l>[k]` by exactly `ε`. Proves the native
//!   control-vector path reaches this layer of this model.
//!
//! A pass caches the layer on the shared [`Model`](crate::engine) so the ~two-token
//! cost is paid once; a fail (or a layer whose residual never responds) raises
//! `relm_error_intervention` naming what was probed and did not respond.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::engine::LoadedModel;
use crate::error::RebirthError;
use crate::ffi;
use crate::intervene::InterventionSpec;
use crate::trace::parse_tensor_name;

/// The residual tensor base name every supported decoder emits AFTER `build_cvec`
/// (`llm_trace`'s `residual` component; `cb(cur, "l_out", il)` follows the
/// `build_cvec` call in every `src/models/*.cpp`). The probe observes exactly this
/// tensor, so a pass proves the intervention acts on the quantity `llm_trace` reads.
const RESIDUAL_NAME: &str = "l_out";

/// Sentinel value the ablation pins `l_out[k]` to: a fixed, unusual finite constant
/// well outside the range of a natural residual activation, so a no-op (the pin not
/// firing) leaves the natural value and fails the `≈ s` check.
const SENTINEL_ABLATE: f32 = -17.5;

/// Sentinel shift the control vector must add to `l_out[k]`: large versus f32
/// rounding, so a no-op (shift 0) misses it by far more than the tolerance.
const SENTINEL_STEER: f32 = 12.0;

/// The single token decoded for the probe. Any in-vocabulary id works — one forward
/// pass computes `l_out-<il>` for every block regardless of which token it is.
const PROBE_TOKEN: i32 = 0;

/// A one-token probe needs only a tiny context window (and KV cache); clamp the
/// model's window down to this so the throwaway context is cheap to build.
const PROBE_N_CTX: u32 = 32;

/// Absolute tolerance for the ablation-pin check. The pin is `x*0 + s`, exact in
/// f32, so any real slack is backend fusion noise; a broken mechanism leaves a
/// natural activation, `O(1..30)` away from the sentinel — far outside this band.
const ABLATE_TOL: f64 = 1e-2;

/// Whether an ablation pinned `l_out[k]` to the sentinel (absolute check). A pure
/// function so the discriminating power (a natural value fails) is unit-tested.
fn ablation_pin_ok(observed: f32, sentinel: f32) -> bool {
    (observed as f64 - sentinel as f64).abs() <= ABLATE_TOL
}

/// Whether a control vector shifted `l_out[k]` by `eps` versus the clean base. The
/// tolerance is the f32 rounding of `base + eps` scaled by magnitude, plus a floor;
/// a no-op (shift 0) misses `eps` by far more, so the check is never "always true".
fn steer_shift_ok(base: f32, steered: f32, eps: f32) -> bool {
    let shift = steered as f64 - base as f64;
    let tol = 1e-2 + 1e-4 * (base.abs() as f64 + eps.abs() as f64);
    (shift - eps as f64).abs() <= tol
}

/// Per-model probe verdict cache (shared through `Arc<Model>`): the engine layers
/// (0-based) whose steering / ablation mechanism has already been proven to take
/// effect, so a later derivation re-probes only newly-requested layers ("paid
/// once", D-021). A failing probe never records anything, so a retry re-checks.
#[derive(Default)]
pub(crate) struct ProbeCache {
    steer_ok: BTreeSet<u32>,
    ablate_ok: BTreeSet<u32>,
}

impl ProbeCache {
    /// The requested layers not yet proven, split by mechanism.
    fn todo(&self, steer: &[u32], ablate: &[u32]) -> (Vec<u32>, Vec<u32>) {
        (
            steer
                .iter()
                .copied()
                .filter(|l| !self.steer_ok.contains(l))
                .collect(),
            ablate
                .iter()
                .copied()
                .filter(|l| !self.ablate_ok.contains(l))
                .collect(),
        )
    }

    /// Record layers as proven after a successful probe.
    fn mark(&mut self, steer: &[u32], ablate: &[u32]) {
        self.steer_ok.extend(steer.iter().copied());
        self.ablate_ok.extend(ablate.iter().copied());
    }
}

/// The state the probe's eval-callback trampoline fills: for each requested layer,
/// the captured `l_out-<il>` row (`n_embd` f32 of the single probed token). Touched
/// only on the R (decode) thread, synchronously inside `llama_decode`.
struct ProbeCaptureState {
    /// Engine layers (0-based) to capture `l_out-<il>` for.
    layers: BTreeSet<u32>,
    /// Expected row width (`n_embd`) of the single-token residual.
    n_embd: usize,
    /// Captured rows, keyed by engine layer.
    captured: BTreeMap<u32, Vec<f32>>,
    /// The first capture failure, surfaced by the engine after the decode returns.
    error: Option<RebirthError>,
}

impl ProbeCaptureState {
    fn new(layers: BTreeSet<u32>, n_embd: usize) -> Self {
        ProbeCaptureState {
            layers,
            n_embd,
            captured: BTreeMap::new(),
            error: None,
        }
    }

    fn record_panic(&mut self) {
        if self.error.is_none() {
            self.error = Some(RebirthError::Internal {
                context: "a panic occurred inside the intervention-probe callback".to_string(),
            });
        }
    }

    /// Handle one scheduler callback for node `t`: capture `l_out-<il>` (for a
    /// requested layer) when its data is ready.
    fn on_node(&mut self, t: *mut ffi::ggml_tensor, ask: bool) -> bool {
        // SAFETY: `t` is the live tensor the scheduler passed; `ggml_get_name`
        // returns a NUL-terminated name owned by the graph, valid for this call.
        let name_ptr = unsafe { ffi::ggml_get_name(t) };
        if name_ptr.is_null() {
            return !ask;
        }
        // SAFETY: `name_ptr` is non-null and NUL-terminated (per above).
        let name = match unsafe { CStr::from_ptr(name_ptr) }.to_str() {
            Ok(s) => s,
            Err(_) => return !ask,
        };
        let (base, il) = match parse_tensor_name(name) {
            Some(parsed) => parsed,
            None => return !ask,
        };
        let wanted = base == RESIDUAL_NAME && self.layers.contains(&il);
        if ask {
            return wanted;
        }
        if !wanted {
            return true;
        }

        // A single token was decoded, so `l_out-<il>` is exactly `n_embd` f32. A
        // different shape or dtype is an internal probe bug, not a silent bad read.
        let n_embd = self.n_embd;
        // SAFETY: `t` is the live, computed tensor; both are read-only queries.
        let nelements = unsafe { ffi::ggml_nelements(t) };
        let nbytes = unsafe { ffi::ggml_nbytes(t) };
        if nelements as usize != n_embd || nbytes != n_embd * 4 {
            self.error = Some(RebirthError::Intervention {
                reason: format!(
                    "Internal error probing tensor '{name}': expected {n_embd} float32 \
                     values but the tensor has {nelements} elements in {nbytes} bytes. \
                     Please report this."
                ),
            });
            return false;
        }
        let mut values = vec![0.0f32; n_embd];
        // SAFETY: `t` is computed and synchronized (ask == false); `values` holds
        // exactly `nbytes` bytes and we copy exactly that many.
        unsafe {
            ffi::ggml_backend_tensor_get(t, values.as_mut_ptr().cast::<c_void>(), 0, nbytes);
        }
        self.captured.insert(il, values);
        true
    }
}

/// The `extern "C"` scheduler eval callback for the probe. Its body is wrapped in
/// `catch_unwind`: a panic must NEVER unwind across the C ABI into the scheduler.
extern "C" fn probe_trampoline(
    t: *mut ffi::ggml_tensor,
    ask: bool,
    user_data: *mut c_void,
) -> bool {
    let state = user_data.cast::<ProbeCaptureState>();
    if state.is_null() {
        return !ask;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: single-threaded (the callback fires synchronously inside
        // `llama_decode` on the R thread); `state` points at a live
        // `ProbeCaptureState` owned by the enclosing probe call, with no other
        // active reference while the callback runs.
        let st = unsafe { &mut *state };
        st.on_node(t, ask)
    }));
    match result {
        Ok(keep) => keep,
        Err(_) => {
            // SAFETY: same live pointer; recording the panic and cancelling compute
            // surfaces it as a classed error rather than a raw unwind across the ABI.
            unsafe { (*state).record_panic() };
            false
        }
    }
}

impl LoadedModel {
    /// Prove the derivation's steering / ablation take effect on THIS model at each
    /// requested layer (D-021), or return `relm_error_intervention` naming what
    /// was probed and did not respond — never a silent no-op. Layers already proven
    /// (cached on the shared model) are skipped; a genuine no-op spec (empty, or a
    /// zero steer) has nothing to prove and passes trivially.
    pub(crate) fn verify_interventions_effective(
        &self,
        spec: &InterventionSpec,
    ) -> Result<(), RebirthError> {
        let steer_layers = spec.nonzero_steer_layers();
        let ablate_layers = spec.ablation_layers();

        // Consult the shared cache; probe only layers not yet proven. The lock is
        // released before the (slow) decode so it is never held across the engine.
        let (steer_todo, ablate_todo) = {
            let cache = self.lock_probe_cache();
            cache.todo(&steer_layers, &ablate_layers)
        };
        if steer_todo.is_empty() && ablate_todo.is_empty() {
            return Ok(());
        }

        self.run_intervention_probe(&steer_todo, &ablate_todo)?;

        self.lock_probe_cache().mark(&steer_todo, &ablate_todo);
        Ok(())
    }

    /// Lock the shared probe cache (poison-tolerant: a panic elsewhere must not turn
    /// every later lock into a panic, which in a `Drop` would abort the process).
    fn lock_probe_cache(&self) -> std::sync::MutexGuard<'_, ProbeCache> {
        self.probe_cache()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Run the sentinel checks for the given un-proven layers. One base decode plus
    /// one combined ablation decode plus one decode per steer layer (each steer
    /// probed on a clean context so an upstream sentinel cannot pollute its shift).
    fn run_intervention_probe(
        &self,
        steer_todo: &[u32],
        ablate_todo: &[u32],
    ) -> Result<(), RebirthError> {
        let n_embd = self.hidden_size().max(0) as usize;
        let n_layer = self.num_layers().max(0) as usize;
        if n_embd == 0 || n_layer == 0 {
            return Err(RebirthError::Intervention {
                reason: "This model reports no hidden dimension or no layers, so its \
                         interventions cannot be verified."
                    .to_string(),
            });
        }
        let k_a = 0usize;
        let k_s = usize::from(n_embd > 1); // a neuron distinct from k_a when possible

        // Ablation-pin (absolute; robust to any upstream perturbation): one decode
        // with a sentinel ablation registered at every requested ablation layer.
        if !ablate_todo.is_empty() {
            let mut spec = InterventionSpec::new(n_embd, n_layer);
            for &l in ablate_todo {
                spec.add_ablation(l as usize, &[k_a], SENTINEL_ABLATE);
            }
            let want: BTreeSet<u32> = ablate_todo.iter().copied().collect();
            let cap = self.probe_decode(&spec, &want)?;
            for &l in ablate_todo {
                let row = cap.get(&l).ok_or_else(|| self.probe_no_residual(l))?;
                if !ablation_pin_ok(row[k_a], SENTINEL_ABLATE) {
                    return Err(self.probe_ablation_failed(l, row[k_a]));
                }
            }
        }

        // Steer-shift (relative to a clean base): decode the base once, then one
        // single-layer sentinel steer per requested layer.
        if !steer_todo.is_empty() {
            let want: BTreeSet<u32> = steer_todo.iter().copied().collect();
            let base = self.probe_decode(&InterventionSpec::new(n_embd, n_layer), &want)?;
            for &l in steer_todo {
                let mut spec = InterventionSpec::new(n_embd, n_layer);
                let mut vector = vec![0.0f32; n_embd];
                vector[k_s] = SENTINEL_STEER;
                spec.add_steer(l as usize, &vector);
                let one: BTreeSet<u32> = std::iter::once(l).collect();
                let cap = self.probe_decode(&spec, &one)?;
                let base_row = base.get(&l).ok_or_else(|| self.probe_no_residual(l))?;
                let steered_row = cap.get(&l).ok_or_else(|| self.probe_no_residual(l))?;
                if !steer_shift_ok(base_row[k_s], steered_row[k_s], SENTINEL_STEER) {
                    let shift = steered_row[k_s] as f64 - base_row[k_s] as f64;
                    return Err(self.probe_steer_failed(l, shift));
                }
            }
        }
        Ok(())
    }

    /// One throwaway-context decode of the sentinel token with `spec`'s adapters
    /// applied, returning the captured `l_out-<il>` row for each layer in `layers`.
    /// A FRESH trace context per call (the proven "set adapters once, then decode"
    /// pattern — never mutating adapters on a live context) with the residual tap.
    fn probe_decode(
        &self,
        spec: &InterventionSpec,
        layers: &BTreeSet<u32>,
    ) -> Result<BTreeMap<u32, Vec<f32>>, RebirthError> {
        let n_embd = self.hidden_size().max(0) as usize;
        let n_ctx = self.context_length().clamp(1, PROBE_N_CTX);

        // The capture state lives behind a stable raw pointer for the callback's
        // lifetime; the guard reclaims it on every exit path, after the trace context
        // that referenced it has been dropped.
        let state_ptr = Box::into_raw(Box::new(ProbeCaptureState::new(layers.clone(), n_embd)));
        struct Reclaim(*mut ProbeCaptureState);
        impl Drop for Reclaim {
            fn drop(&mut self) {
                // SAFETY: `self.0` came from `Box::into_raw` and is reclaimed exactly
                // once (this guard drops once), after `ctx` (declared later, dropped
                // first) has torn down the scheduler + callback.
                drop(unsafe { Box::from_raw(self.0) });
            }
        }
        let _reclaim = Reclaim(state_ptr);

        // Declared after `_reclaim`, so on any early return `ctx` drops first.
        // A probe context-allocation failure is an INTERVENTION failure, not a trace
        // one: re-class it (create_trace_context raises RebirthError::Trace) so
        // llm_steer/llm_ablate surface the documented relm_error_intervention.
        let ctx = self
            .create_trace_context(n_ctx, probe_trampoline, state_ptr.cast::<c_void>())
            .map_err(|_| RebirthError::Intervention {
                reason: "could not allocate a context to verify the intervention (out of \
                         memory?); free memory, e.g. close() other loaded models, and retry"
                    .to_string(),
            })?;
        spec.apply_to_context(ctx.ptr.as_ptr())?;
        let decode_result = ctx.decode_all(&[PROBE_TOKEN]);
        // SAFETY: single-threaded; the callback has finished for this decode.
        let capture_err = unsafe { (*state_ptr).error.take() };
        if let Some(err) = capture_err {
            return Err(err);
        }
        decode_result?;
        drop(ctx); // stop the callback before moving the captured rows out
                   // SAFETY: the callback can no longer run; take the captured rows.
        let captured = unsafe { std::mem::take(&mut (*state_ptr).captured) };
        Ok(captured)
    }

    // --- probe failure conditions (name what was probed and did not respond) ---

    fn probe_ablation_failed(&self, il: u32, observed: f32) -> RebirthError {
        RebirthError::Intervention {
            reason: format!(
                "Interventions are not available on this model (architecture '{arch}'): a \
                 sentinel ablation probe at layer {layer} did not take effect — the \
                 residual neuron was not pinned to the sentinel value {SENTINEL_ABLATE} \
                 (it stayed {observed}). Steering and ablation would silently do nothing \
                 here, so they are refused rather than misapplied. The model's residual \
                 stream must pass through the build_cvec choke point for interventions to \
                 work.",
                arch = self.architecture(),
                layer = il + 1,
            ),
        }
    }

    fn probe_steer_failed(&self, il: u32, observed_shift: f64) -> RebirthError {
        RebirthError::Intervention {
            reason: format!(
                "Interventions are not available on this model (architecture '{arch}'): a \
                 sentinel steering probe at layer {layer} did not shift the residual \
                 (expected a shift of {SENTINEL_STEER}, observed {observed_shift:.4}). The \
                 native control-vector path does not reach this layer, so steering would \
                 silently do nothing here and is refused rather than misapplied.",
                arch = self.architecture(),
                layer = il + 1,
            ),
        }
    }

    fn probe_no_residual(&self, il: u32) -> RebirthError {
        RebirthError::Intervention {
            reason: format!(
                "Interventions could not be verified on this model (architecture \
                 '{arch}'): the residual stream at layer {layer} was not observable during \
                 the probe (no 'l_out-{il}' tensor), so it cannot be confirmed that an \
                 intervention there takes effect. Interventions are refused rather than \
                 applied unverified.",
                arch = self.architecture(),
                layer = il + 1,
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ablation_pin_check_discriminates_the_sentinel_from_a_natural_value() {
        // An exact pin passes; a small fusion slack passes; a natural activation
        // (the no-op case) fails — so the check is not "always true".
        assert!(ablation_pin_ok(SENTINEL_ABLATE, SENTINEL_ABLATE));
        assert!(ablation_pin_ok(SENTINEL_ABLATE + 0.005, SENTINEL_ABLATE));
        assert!(!ablation_pin_ok(0.0, SENTINEL_ABLATE)); // no-op: natural value
        assert!(!ablation_pin_ok(3.2, SENTINEL_ABLATE));
        assert!(!ablation_pin_ok(-17.0, SENTINEL_ABLATE)); // close but outside tol
    }

    #[test]
    fn steer_shift_check_requires_the_exact_shift() {
        // A shift of exactly eps passes (at various base magnitudes); a no-op
        // (shift 0) and a wrong-magnitude shift both fail.
        for base in [0.0f32, 5.0, -12.3, 40.0] {
            assert!(steer_shift_ok(base, base + SENTINEL_STEER, SENTINEL_STEER));
            assert!(!steer_shift_ok(base, base, SENTINEL_STEER)); // no-op
            assert!(!steer_shift_ok(base, base + 1.0, SENTINEL_STEER)); // wrong shift
        }
        // f32 rounding of base + eps stays inside the tolerance.
        let base = 33.0f32;
        assert!(steer_shift_ok(
            base,
            base + SENTINEL_STEER + 0.002,
            SENTINEL_STEER
        ));
    }

    #[test]
    fn deliberately_wrong_sentinel_expectations_fail() {
        // Mutation discipline (D-021): if the probe checked against the WRONG
        // expected value, a correct pin/shift would fail — so the checks are keyed to
        // the real sentinels, never a constant that makes them vacuously true.
        assert!(!ablation_pin_ok(SENTINEL_ABLATE, SENTINEL_ABLATE + 5.0));
        assert!(!steer_shift_ok(
            2.0,
            2.0 + SENTINEL_STEER,
            SENTINEL_STEER + 5.0
        ));
    }

    #[test]
    fn probe_cache_reports_only_unproven_layers_and_records_passes() {
        let mut cache = ProbeCache::default();
        // Nothing proven yet: every requested layer is to-do.
        let (steer, ablate) = cache.todo(&[2, 5], &[0, 3]);
        assert_eq!(steer, vec![2, 5]);
        assert_eq!(ablate, vec![0, 3]);
        // After marking, those layers are skipped; a new one is still to-do, and the
        // two mechanisms are cached independently (a steer-proven layer is not
        // ablate-proven).
        cache.mark(&[2, 5], &[0, 3]);
        let (steer, ablate) = cache.todo(&[2, 5, 7], &[0, 2]);
        assert_eq!(steer, vec![7]);
        assert_eq!(
            ablate,
            vec![2],
            "layer 2 is steer-proven but not ablate-proven"
        );
    }
}
