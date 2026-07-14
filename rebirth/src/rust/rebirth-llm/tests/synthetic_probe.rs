//! Model-backed tests for the runtime sentinel intervention probe (WP7.5a, D-021),
//! on the in-repo synthetic 2-layer llama GGUF. Runs in the `cargo test -p
//! rebirth-llm` CI job on the CPU backend, download-free.
//!
//! The synthetic model has `build_cvec` (it is a standard-residual llama), so the
//! probe PASSES on it: every `derive_with_interventions` below implicitly runs the
//! probe first (it replaces the removed hard arch allow-list). These tests prove:
//!
//! 1. the probe passes and interventions still derive on a supported model;
//! 2. it is NOT gameable — a steer at a layer the native control vector cannot reach
//!    (engine layer 0) is caught as a silent no-op and rejected with the classed
//!    `RebirthError::Intervention`, while the ablation-pin at that same layer (which
//!    the intervene adapter DOES cover) passes — so the probe discriminates
//!    per-mechanism, never reducing to "always true";
//! 3. the probe leaves the source handle bit-for-bit unchanged (it runs on throwaway
//!    contexts over the shared, read-only weights).
//!
//! The exact numerical effect + oracle agreement of the interventions themselves is
//! proven separately in `synthetic_intervene.rs`.

use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, InterventionSpec, LoadRequest, LoadedModel, RebirthError};

/// The fixed golden input (`synthetic_model.INPUT_TOKENS`) — reused so the
/// reversibility check compares against the same teacher-forced logits.
const INPUT_TOKENS: [i32; 8] = [1, 7, 13, 22, 5, 31, 44, 2];

fn synthetic_gguf() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../..")
        .join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf")
}

fn load_synthetic() -> LoadedModel {
    let gguf = synthetic_gguf();
    assert!(
        gguf.exists(),
        "synthetic GGUF missing at {} (run build_synthetic.py)",
        gguf.display()
    );
    load(LoadRequest {
        path: gguf,
        context_length: 512,
        gpu_layers: None,
        // CPU so the probe runs identically on every CI platform.
        backend: BackendKind::Cpu,
        mmap: true,
        projector: None,
    })
    .expect("synthetic model loads")
}

/// A one-hot steer vector `eps * e_k`, `n_embd` wide.
fn onehot(n_embd: usize, k: usize, eps: f32) -> Vec<f32> {
    let mut v = vec![0.0f32; n_embd];
    v[k] = eps;
    v
}

#[test]
fn probe_passes_and_interventions_derive_on_a_supported_model() {
    let model = load_synthetic();
    let meta = model.metadata();
    let n_embd = meta.hidden_size.max(0) as usize;
    let n_layer = meta.layers.max(0) as usize;
    assert_eq!(n_layer, 2, "synthetic model is 2 layers (engine il 0, 1)");

    // A steer at engine layer 1 (the cvec's only reachable layer here): the probe's
    // steer-shift check passes, so the handle derives.
    let mut steer = InterventionSpec::new(n_embd, n_layer);
    steer.add_steer(1, &onehot(n_embd, 0, 1.0));
    model
        .derive_with_interventions(&steer)
        .expect("steer at engine layer 1 passes the probe and derives");

    // An ablation at engine layer 0 (the intervene adapter covers every layer): the
    // ablation-pin check passes, so the handle derives.
    let mut ablate = InterventionSpec::new(n_embd, n_layer);
    ablate.add_ablation(0, &[2], 0.0);
    model
        .derive_with_interventions(&ablate)
        .expect("ablation at engine layer 0 passes the probe and derives");
}

#[test]
fn probe_rejects_a_steer_where_the_mechanism_silently_no_ops() {
    // NON-GAMEABILITY (D-021): the native control vector has no engine-layer-0 row
    // (`llama-adapter.cpp`: "there's never a tensor for layer 0"), so a steer there
    // silently does NOTHING. The probe must catch this and refuse with the classed
    // error — proving it is not "always true" and that it flags the exact
    // silent-no-op class the D-016 hard list used to guard by architecture.
    let model = load_synthetic();
    let meta = model.metadata();
    let n_embd = meta.hidden_size.max(0) as usize;
    let n_layer = meta.layers.max(0) as usize;

    let mut steer_l0 = InterventionSpec::new(n_embd, n_layer);
    steer_l0.add_steer(0, &onehot(n_embd, 1, 5.0)); // engine layer 0 — unreachable
    match model.derive_with_interventions(&steer_l0) {
        Err(RebirthError::Intervention { reason }) => {
            assert!(
                reason.contains("steering"),
                "the rejection must name the steering probe: {reason}"
            );
            assert!(
                reason.contains("did not shift"),
                "the rejection must state the residual did not shift: {reason}"
            );
        }
        Err(e) => panic!("expected a steer-probe Intervention error, got {e:?}"),
        Ok(_) => panic!("a steer at engine layer 0 silently no-ops but was NOT rejected"),
    }

    // The SAME layer 0 is reachable by ABLATION (full coverage), so its probe passes
    // — the probe discriminates per mechanism, it does not blanket-reject layer 0.
    let mut ablate_l0 = InterventionSpec::new(n_embd, n_layer);
    ablate_l0.add_ablation(0, &[1], -3.0);
    model
        .derive_with_interventions(&ablate_l0)
        .expect("ablation at engine layer 0 is reachable and passes the probe");
}

#[test]
fn a_wrong_sentinel_ablation_would_fail_the_probe_but_the_real_one_passes() {
    // A deliberately-wrong ablation VALUE still pins the neuron to that value, which
    // the pin check reads back exactly — so ablation always registers on a supported
    // model. This complements the pure-logic mutation tests in probe.rs (a wrong
    // EXPECTED value fails): here we confirm a genuine ablation on real weights is
    // observed at the residual and accepted.
    let model = load_synthetic();
    let meta = model.metadata();
    let n_embd = meta.hidden_size.max(0) as usize;
    let n_layer = meta.layers.max(0) as usize;

    for &il in &[0usize, 1usize] {
        let mut spec = InterventionSpec::new(n_embd, n_layer);
        spec.add_ablation(il, &[0, 5, 17], 2.5);
        model
            .derive_with_interventions(&spec)
            .unwrap_or_else(|e| panic!("ablation at engine layer {il} must pass the probe: {e:?}"));
    }
}

#[test]
fn the_probe_leaves_the_source_handle_bit_for_bit_unchanged() {
    // The probe runs on throwaway contexts over the shared, read-only weights, so it
    // must not perturb the source: its teacher-forced logits reproduce bit-for-bit
    // after several probed derivations (the reversibility guarantee, D-016).
    let model = load_synthetic();
    let meta = model.metadata();
    let n_embd = meta.hidden_size.max(0) as usize;
    let n_layer = meta.layers.max(0) as usize;

    let before = model
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("base logits before any derivation");

    // Several probed derivations (steer engine 1, ablate engine 0, both).
    let mut steer = InterventionSpec::new(n_embd, n_layer);
    steer.add_steer(1, &onehot(n_embd, 3, 1.0));
    model
        .derive_with_interventions(&steer)
        .expect("steer derives");

    let mut ablate = InterventionSpec::new(n_embd, n_layer);
    ablate.add_ablation(0, &[7], 0.0);
    model
        .derive_with_interventions(&ablate)
        .expect("ablate derives");

    let mut both = InterventionSpec::new(n_embd, n_layer);
    both.add_steer(1, &onehot(n_embd, 3, 1.0));
    both.add_ablation(0, &[7], 0.0);
    model
        .derive_with_interventions(&both)
        .expect("both derives");

    let after = model
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("base logits after probed derivations");
    assert_eq!(
        before.values, after.values,
        "the sentinel probe perturbed the source handle (reversibility broken)"
    );
}
