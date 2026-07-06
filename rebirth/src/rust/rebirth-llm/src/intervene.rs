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

/// Architectures whose graphs call `build_cvec` — the residual choke point both
/// steering and ablation hook — so interventions are supported. Seeded with the
/// verified set; an unlisted architecture raises `rebirth_error_intervention`,
/// never a silent no-op (D-012/D-014). Tiering (D-016): `llama` + `qwen2` are
/// fixture-covered; `gemma3` is source-verified at b9726 (`models/gemma3.cpp`
/// L194 calls `build_cvec`), its runtime fixture chartered for WP6b/thesis-era.
const INTERVENTION_SUPPORTED_ARCHS: &[&str] = &["llama", "qwen2", "gemma3"];

/// Whether `arch` supports interventions (free function so the arch gate is
/// unit-testable without a loaded model).
fn intervention_arch_supported(arch: &str) -> bool {
    INTERVENTION_SUPPORTED_ARCHS.contains(&arch)
}

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

    /// Whether this spec carries no intervention at all.
    pub fn is_empty(&self) -> bool {
        self.steer.is_none() && self.ablate_mask.is_none()
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
    /// `Ok(())` if this model's architecture has the `build_cvec` residual choke
    /// point interventions hook, else `rebirth_error_intervention` (never a silent
    /// no-op, D-012/D-014).
    pub fn check_intervention_supported(&self) -> Result<(), RebirthError> {
        let arch = self.architecture();
        if intervention_arch_supported(&arch) {
            Ok(())
        } else {
            Err(RebirthError::Intervention {
                reason: format!(
                    "Interventions (steering and ablation) are not supported for the \
                     '{arch}' architecture: it does not have the residual choke point \
                     the mechanism hooks. Supported architectures: {}.",
                    INTERVENTION_SUPPORTED_ARCHS.join(", ")
                ),
            })
        }
    }

    /// Build a NEW handle sharing this model's weights (a cloned `Arc<Model>`, no
    /// reload) with `spec` applied to a fresh context. The source handle is only
    /// read, so the original reproduces its outputs bit-for-bit (D-016). Works
    /// identically on a base or an already-derived handle (the caller passes the
    /// FULL accumulated spec, so the result is base-weights + all interventions).
    pub fn derive_with_interventions(
        &self,
        spec: &InterventionSpec,
    ) -> Result<LoadedModel, RebirthError> {
        self.check_intervention_supported()?;

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

        let derived = self.clone_with_fresh_context()?;

        if let (Some(steer), Some((il_start, il_end))) = (&spec.steer, spec.steer_il_range) {
            // The native cvec buffer has no layer-0 row: pass a view starting at
            // engine layer 1 (`&steer[n_embd..]`, length `n_embd*(n_layer-1)`), so
            // engine layer `il` lands at the native offset `n_embd*(il-1)`. For a
            // 1-layer model this view is empty (steering is then a no-op).
            let native = &steer[n_embd.min(steer.len())..];
            // SAFETY: `derived.ctx_ptr()` is a live context on this (R main) thread.
            // `native` is a Rust-owned f32 slice that outlives this synchronous
            // call; the engine copies the data before returning. The `(ptr, len)`
            // pair is exactly the "from layer 1" cvec buffer the engine expects.
            let status = unsafe {
                ffi::llama_set_adapter_cvec(
                    derived.ctx_ptr(),
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
            (&spec.ablate_mask, &spec.ablate_add, spec.ablate_il_range)
        {
            // SAFETY: live context on this thread; `mask`/`add` are Rust-owned f32
            // buffers of `n_embd*n_layer` (full coverage from layer 0) that outlive
            // this synchronous call; the engine copies them before returning.
            let status = unsafe {
                ffi::rebirth_set_intervene(
                    derived.ctx_ptr(),
                    mask.as_ptr(),
                    add.as_ptr(),
                    mask.len(),
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

        Ok(derived)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const N_EMBD: usize = 4;
    const N_LAYER: usize = 3;

    #[test]
    fn supported_archs_are_exactly_the_pinned_set() {
        // Reviewer nit 1: pin the FULL list. R's INTERVENTION_SUPPORTED_ARCHS
        // (intervene.R) pins the identical set in its own unit test, so a one-sided
        // addition (e.g. adding "gemma2" here but not in R) breaks one of the two
        // tests. The engine's arch gate stays authoritative; this only catches
        // R<->Rust drift.
        assert_eq!(INTERVENTION_SUPPORTED_ARCHS, &["llama", "qwen2", "gemma3"]);
    }

    #[test]
    fn arch_gate_accepts_supported_and_rejects_others() {
        for arch in ["llama", "qwen2", "gemma3"] {
            assert!(
                intervention_arch_supported(arch),
                "{arch} must be supported"
            );
        }
        for arch in ["bert", "nomic-bert", "mamba", ""] {
            assert!(
                !intervention_arch_supported(arch),
                "{arch} must not be supported"
            );
        }
    }

    #[test]
    fn empty_spec_is_empty() {
        let spec = InterventionSpec::new(N_EMBD, N_LAYER);
        assert!(spec.is_empty());
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
