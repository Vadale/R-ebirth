//! Interventions (WP5): steering (`llm_steer`) via llama.cpp's native control
//! vector and ablation (`llm_ablate`) via the vendored `rebirth_set_intervene`
//! patch at `build_cvec` (D-012/D-016).
//!
//! The engine wrapper for the interventions. A new handle is a FRESH context on a
//! cloned `Arc<Model>` (shared, read-only weights) with the steering / ablation
//! adapters applied to it ([`LoadedModel::derive_with_interventions`]); the source
//! handle's context is never touched, so the original reproduces its outputs
//! bit-for-bit (the reversibility acceptance, D-016). All indices here are
//! ENGINE-native (0-based); the 1-based R API conversion happens only in
//! `rebirth-ffi` (ARCHITECTURE §4). The crate stays R-free (ARCHITECTURE §2):
//! plain Rust types in and out, C-FFI `unsafe` minimal and SAFETY-commented (D-009).
//!
//! Composition (D-016) is done by the caller as it accumulates the spec: steering
//! **sums** (control vectors compose additively) and ablation is a **union,
//! last-write-wins** per `(layer, neuron)`. At the graph the ablation runs AFTER
//! the steer (`(x + steer) ⊙ mask + add`), so a jointly touched neuron is forced
//! to `value` — the mandated, derivation-order-independent semantics.

use crate::engine::LoadedModel;
use crate::error::RebirthError;
use crate::ffi;

// The D-016 hard arch allow-list (`INTERVENTION_SUPPORTED_ARCHS = {llama, qwen2,
// gemma3}`, checked before decode) is superseded by the runtime sentinel probe in
// `probe.rs` (D-021 §1.3): `derive_with_interventions` proves on a throwaway context
// that steering and ablation actually take effect on THIS model at the requested
// layers, enabling any standard-residual decoder while still refusing (loudly) a
// silent no-op. The R-facing "behaviorally validated" tier is documentation-only
// (`INTERVENTION_VALIDATED_ARCHS` in `intervene.R`), not a gate.

/// A fully-accumulated intervention set, engine-native (0-based layers). The
/// caller ([`InterventionSpec::add_steer`] / [`add_ablation`](InterventionSpec::add_ablation))
/// sums steers and unions ablations into two dense per-layer buffers, so the
/// engine surface is stateless and trivially testable. `None` = that kind is absent.
pub struct InterventionSpec {
    pub n_embd: usize,
    pub n_layer: usize,

    /// Steering buffer, `n_embd * n_layer` F32, row `il` at offset `n_embd*il`
    /// (row 0 = engine layer 0). The NATIVE control-vector buffer has no layer-0
    /// row (`llama.h` L691 "from layer 1"; `llama-adapter.cpp` L127), so at the FFI
    /// call we pass a view starting at row 1 (`&steer[n_embd..]`) with length
    /// `n_embd*(n_layer-1)`; engine layer `il` then lands at the native offset
    /// `n_embd*(il-1)`. Steering engine layer 0 is therefore a native no-op (the R
    /// layer rejects it — API `layer = 1`; D-016). `None` = no steer.
    steer: Option<Vec<f32>>,
    /// Inclusive engine-layer range `[il_start, il_end]` the steer applies to.
    steer_il_range: Option<(i32, i32)>,

    /// Ablation mask (init `1.0`) and add (init `0.0`), each `n_embd * n_layer`
    /// F32, FULL coverage from layer 0 (row `il` at offset `n_embd*il`) — the
    /// intervene adapter reaches every layer. `mask[il,k]=0`/`add[il,k]=value`
    /// forces neuron `k` of layer `il` to `value`. `None` = no ablation.
    ablate_mask: Option<Vec<f32>>,
    ablate_add: Option<Vec<f32>>,
    /// Inclusive engine-layer range `[il_start, il_end]` the ablation spans.
    ablate_il_range: Option<(i32, i32)>,
}

impl InterventionSpec {
    /// An empty spec for a model of `n_embd` hidden size and `n_layer` blocks.
    pub fn new(n_embd: usize, n_layer: usize) -> Self {
        InterventionSpec {
            n_embd,
            n_layer,
            steer: None,
            steer_il_range: None,
            ablate_mask: None,
            ablate_add: None,
            ablate_il_range: None,
        }
    }

    /// Add a steer vector (`coef * direction`, `n_embd` wide) at engine layer `il`
    /// (0-based). Repeated steers on a layer SUM (control vectors compose
    /// additively). Panics on a width/layer mismatch — a caller contract the R
    /// validation layer enforces before the boundary.
    pub fn add_steer(&mut self, il: usize, vector: &[f32]) {
        assert_eq!(
            vector.len(),
            self.n_embd,
            "steer vector must be n_embd wide"
        );
        assert!(il < self.n_layer, "steer layer {il} out of range");
        let width = self.n_embd;
        let buf = self
            .steer
            .get_or_insert_with(|| vec![0.0; width * self.n_layer]);
        let base = il * width;
        for (j, &v) in vector.iter().enumerate() {
            buf[base + j] += v; // sum: stacking steers on a layer
        }
        self.steer_il_range = Some(widen(self.steer_il_range, il as i32));
    }

    /// Force `neurons` (0-based) of engine layer `il`'s residual to `value`
    /// (union; a later ablation of the same `(layer, neuron)` overrides its value).
    /// Panics on a layer/neuron out of range — the R validation layer's contract.
    pub fn add_ablation(&mut self, il: usize, neurons: &[usize], value: f32) {
        assert!(il < self.n_layer, "ablation layer {il} out of range");
        let width = self.n_embd;
        let n = width * self.n_layer;
        let mask = self.ablate_mask.get_or_insert_with(|| vec![1.0; n]);
        let add = self.ablate_add.get_or_insert_with(|| vec![0.0; n]);
        let base = il * width;
        for &k in neurons {
            assert!(k < width, "ablation neuron {k} out of range");
            mask[base + k] = 0.0; // last-write-wins
            add[base + k] = value;
        }
        self.ablate_il_range = Some(widen(self.ablate_il_range, il as i32));
    }

    /// The engine layers (0-based) carrying a NON-ZERO steer vector — the layers a
    /// steer actually perturbs (a zero vector, e.g. `coef = 0`, is a genuine no-op
    /// and is excluded). The sentinel probe (`probe.rs`) verifies exactly these.
    pub(crate) fn nonzero_steer_layers(&self) -> Vec<u32> {
        let Some(steer) = &self.steer else {
            return Vec::new();
        };
        (0..self.n_layer)
            .filter(|&il| {
                let base = il * self.n_embd;
                steer[base..base + self.n_embd].iter().any(|&v| v != 0.0)
            })
            .map(|il| il as u32)
            .collect()
    }

    /// The engine layers (0-based) carrying a GENUINE ablation — one that is not the
    /// identity `x*1 + 0`. Mirrors the patched engine's own "genuine" test
    /// (`llama-adapter.cpp`, `mask[k] != 1 || add[k] != 0`), so the probe verifies
    /// exactly the layers whose graph the ablation adapter touches.
    pub(crate) fn ablation_layers(&self) -> Vec<u32> {
        let (Some(mask), Some(add)) = (&self.ablate_mask, &self.ablate_add) else {
            return Vec::new();
        };
        (0..self.n_layer)
            .filter(|&il| {
                let base = il * self.n_embd;
                (0..self.n_embd).any(|j| mask[base + j] != 1.0 || add[base + j] != 0.0)
            })
            .map(|il| il as u32)
            .collect()
    }

    /// Apply this spec's steering (native control vector) and ablation (the
    /// `rebirth_set_intervene` patch) adapters to a live `ctx_ptr`. Shared by the
    /// real derivation ([`LoadedModel::derive_with_interventions`]) and the sentinel
    /// probe, so both configure a context through one reviewed code path.
    pub(crate) fn apply_to_context(
        &self,
        ctx_ptr: *mut ffi::llama_context,
    ) -> Result<(), RebirthError> {
        let n_embd = self.n_embd;
        if let (Some(steer), Some((il_start, il_end))) = (&self.steer, self.steer_il_range) {
            // The native cvec buffer has no layer-0 row: pass a view starting at
            // engine layer 1 (`&steer[n_embd..]`, length `n_embd*(n_layer-1)`), so
            // engine layer `il` lands at the native offset `n_embd*(il-1)`. For a
            // 1-layer model this view is empty (steering is then a no-op).
            let native = &steer[n_embd.min(steer.len())..];
            // SAFETY: `ctx_ptr` is a live context on this (R main) thread. `native`
            // is a Rust-owned f32 slice that outlives this synchronous call; the
            // engine copies the data before returning. The `(ptr, len)` pair is
            // exactly the "from layer 1" cvec buffer the engine expects.
            let status = unsafe {
                ffi::llama_set_adapter_cvec(
                    ctx_ptr,
                    native.as_ptr(),
                    native.len(),
                    n_embd as i32,
                    il_start,
                    il_end,
                )
            };
            if status != 0 {
                return Err(RebirthError::Intervention {
                    reason: format!(
                        "The engine rejected the steering vector (control-vector \
                         setter returned {status}); its width must equal the model's \
                         hidden size ({n_embd})."
                    ),
                });
            }
        }

        if let (Some(mask), Some(add), Some((il_start, il_end))) =
            (&self.ablate_mask, &self.ablate_add, self.ablate_il_range)
        {
            // The C API bounds-checks reads of BOTH `mask` and `add` against a single
            // `len` (llama.h), so `add` must be at least `len` long too. The two are
            // always allocated together at `n_embd*n_layer` (add_ablation), hence
            // equal; take the min defensively so a future divergence can never let the
            // engine over-read `add`, and assert the invariant in debug builds (F-2).
            debug_assert_eq!(mask.len(), add.len(), "ablation mask/add length mismatch");
            let len = mask.len().min(add.len());
            // SAFETY: live context on this thread; `mask`/`add` are Rust-owned f32
            // buffers of `n_embd*n_layer` (full coverage from layer 0) that outlive
            // this synchronous call; the engine copies them before returning.
            let status = unsafe {
                ffi::rebirth_set_intervene(
                    ctx_ptr,
                    mask.as_ptr(),
                    add.as_ptr(),
                    len,
                    n_embd as i32,
                    il_start,
                    il_end,
                )
            };
            if status != 0 {
                return Err(RebirthError::Intervention {
                    reason: format!(
                        "The engine rejected the ablation mask (intervention setter \
                         returned {status}); its width must equal the model's hidden \
                         size ({n_embd})."
                    ),
                });
            }
        }

        Ok(())
    }
}

/// Widen an inclusive range to include `il` (or start it at `il`).
fn widen(range: Option<(i32, i32)>, il: i32) -> (i32, i32) {
    match range {
        None => (il, il),
        Some((s, e)) => (s.min(il), e.max(il)),
    }
}

impl LoadedModel {
    /// Build a NEW handle sharing this model's weights (a cloned `Arc<Model>`, no
    /// reload) with `spec` applied to a fresh context. The source handle is only
    /// read, so the original reproduces its outputs bit-for-bit (D-016). Works
    /// identically on a base or an already-derived handle (the caller passes the
    /// FULL accumulated spec, so the result is base-weights + all interventions).
    ///
    /// Before returning the handle, the runtime sentinel probe (`probe.rs`, D-021)
    /// proves on a throwaway context that the steering / ablation the spec requests
    /// actually take effect on THIS model at each requested layer, replacing the
    /// removed hard arch allow-list: a standard-residual decoder is enabled, while a
    /// model where interventions would silently do nothing is refused loudly
    /// (`rebirth_error_intervention`, the D-012 worst case).
    pub fn derive_with_interventions(
        &self,
        spec: &InterventionSpec,
    ) -> Result<LoadedModel, RebirthError> {
        // Defensive: the R layer builds the spec from this model's metadata, so a
        // dimension mismatch here is an internal error, not a user error.
        let n_embd = self.hidden_size().max(0) as usize;
        let n_layer = self.num_layers().max(0) as usize;
        if spec.n_embd != n_embd || spec.n_layer != n_layer {
            return Err(RebirthError::Intervention {
                reason: format!(
                    "Internal error: the intervention spec is {} x {} but the model \
                     is {n_embd} x {n_layer}. Please report this.",
                    spec.n_embd, spec.n_layer
                ),
            });
        }

        // Prove the mechanism takes effect on this model at the requested layers
        // (D-021), replacing the hard arch gate. Refuses before any handle is built.
        self.verify_interventions_effective(spec)?;

        let derived = self.clone_with_fresh_context()?;
        spec.apply_to_context(derived.ctx_ptr())?;
        Ok(derived)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const N_EMBD: usize = 4;
    const N_LAYER: usize = 3;

    #[test]
    fn nonzero_steer_layers_lists_only_layers_with_a_nonzero_vector() {
        // The probe verifies exactly the layers a steer perturbs. A zero vector
        // (e.g. coef = 0) allocates the buffer but leaves the layer all-zero, so it
        // is a genuine no-op and must NOT be reported (nothing to verify).
        let mut spec = InterventionSpec::new(N_EMBD, N_LAYER);
        assert_eq!(spec.nonzero_steer_layers(), Vec::<u32>::new());
        spec.add_steer(2, &[1.0, 0.0, 0.0, 0.0]);
        spec.add_steer(0, &[0.0; N_EMBD]); // zero vector on layer 0 -> not a steer
        assert_eq!(spec.nonzero_steer_layers(), vec![2]);
        spec.add_steer(1, &[0.0, 0.0, 3.0, 0.0]);
        assert_eq!(spec.nonzero_steer_layers(), vec![1, 2]);
    }

    #[test]
    fn ablation_layers_lists_only_genuinely_ablated_layers() {
        // Mirrors the patched engine's "genuine" test (mask != 1 || add != 0): a
        // layer left at the identity is not reported (the graph is untouched there).
        let mut spec = InterventionSpec::new(N_EMBD, N_LAYER);
        assert_eq!(spec.ablation_layers(), Vec::<u32>::new());
        spec.add_ablation(0, &[1], 0.0); // mask[0,1]=0 -> genuine
        spec.add_ablation(2, &[3], -1.0); // mask[2,3]=0, add=-1 -> genuine
        assert_eq!(spec.ablation_layers(), vec![0, 2]);
        // A "value = 0 on an already-zeroed neuron" is still genuine (mask == 0).
        spec.add_ablation(1, &[0], 0.0);
        assert_eq!(spec.ablation_layers(), vec![0, 1, 2]);
    }

    #[test]
    fn new_spec_has_no_buffers() {
        // A freshly built spec is a no-op: both buffers stay unallocated. The
        // empty-spec derivation (a fresh context, no adapter) relies on this, and
        // intervene_kl.rs exercises that no-op path end to end.
        let spec = InterventionSpec::new(N_EMBD, N_LAYER);
        assert!(spec.steer.is_none());
        assert!(spec.ablate_mask.is_none());
    }

    #[test]
    fn steer_lands_at_the_engine_layer_row_and_the_native_view_aligns() {
        let mut spec = InterventionSpec::new(N_EMBD, N_LAYER);
        let v = [1.0f32, 2.0, 3.0, 4.0];
        spec.add_steer(1, &v); // engine layer 1

        let steer = spec.steer.as_ref().expect("steer allocated");
        assert_eq!(steer.len(), N_EMBD * N_LAYER);
        // Row 1 (offset n_embd) holds the vector; rows 0 and 2 are zero.
        assert_eq!(&steer[0..N_EMBD], &[0.0; N_EMBD]);
        assert_eq!(&steer[N_EMBD..2 * N_EMBD], &v);
        assert_eq!(&steer[2 * N_EMBD..3 * N_EMBD], &[0.0; N_EMBD]);
        assert_eq!(spec.steer_il_range, Some((1, 1)));

        // The native "from layer 1" view (&steer[n_embd..]) puts engine layer 1 at
        // its offset 0, so the engine's off = n_embd*(il-1) = 0 selects this vector
        // (addendum #10: the buffer has no layer-0 row).
        let native = &steer[N_EMBD..];
        assert_eq!(&native[0..N_EMBD], &v);
    }

    #[test]
    fn repeated_steers_on_a_layer_sum_and_range_widens() {
        let mut spec = InterventionSpec::new(N_EMBD, N_LAYER);
        spec.add_steer(2, &[1.0, 1.0, 1.0, 1.0]);
        spec.add_steer(2, &[0.5, 0.5, 0.5, 0.5]); // same layer -> sums
        spec.add_steer(1, &[9.0, 9.0, 9.0, 9.0]);
        let steer = spec.steer.as_ref().unwrap();
        assert_eq!(&steer[2 * N_EMBD..3 * N_EMBD], &[1.5; N_EMBD]);
        assert_eq!(&steer[N_EMBD..2 * N_EMBD], &[9.0; N_EMBD]);
        // Range spans both touched layers.
        assert_eq!(spec.steer_il_range, Some((1, 2)));
    }

    #[test]
    fn ablation_sets_mask_and_add_full_coverage_from_layer_zero() {
        let mut spec = InterventionSpec::new(N_EMBD, N_LAYER);
        spec.add_ablation(0, &[2], 0.0); // engine layer 0 — the full-coverage layer

        let mask = spec.ablate_mask.as_ref().unwrap();
        let add = spec.ablate_add.as_ref().unwrap();
        assert_eq!(mask.len(), N_EMBD * N_LAYER);
        // Layer 0 neuron 2 is zeroed with add 0; every other entry stays identity.
        assert_eq!(mask[2], 0.0);
        assert_eq!(add[2], 0.0);
        for (i, (&m, &a)) in mask.iter().zip(add.iter()).enumerate() {
            if i == 2 {
                continue;
            }
            assert_eq!(m, 1.0, "mask[{i}] identity");
            assert_eq!(a, 0.0, "add[{i}] identity");
        }
        assert_eq!(spec.ablate_il_range, Some((0, 0)));
    }

    #[test]
    fn ablation_union_is_last_write_wins_per_neuron() {
        let mut spec = InterventionSpec::new(N_EMBD, N_LAYER);
        spec.add_ablation(1, &[0, 1], 5.0);
        spec.add_ablation(1, &[1], -2.0); // overrides neuron 1's value
        let add = spec.ablate_add.as_ref().unwrap();
        let mask = spec.ablate_mask.as_ref().unwrap();
        let base = N_EMBD; // layer 1
        assert_eq!(mask[base], 0.0);
        assert_eq!(add[base], 5.0);
        assert_eq!(mask[base + 1], 0.0);
        assert_eq!(add[base + 1], -2.0); // last write wins
    }
}
