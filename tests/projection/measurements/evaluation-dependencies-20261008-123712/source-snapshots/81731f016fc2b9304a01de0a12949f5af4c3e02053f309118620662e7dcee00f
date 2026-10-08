//! Exact-value engine-vs-oracle check on the synthetic 2-layer llama model, for
//! interventions (WP5 Step 3, the numerical de-risking gate).
//!
//! The engine derives a steered / ablated / composed handle (a fresh context on the
//! shared weights, with the native control vector and/or the `rebirth_set_intervene`
//! ablation patch applied) and computes teacher-forced logits for the fixed
//! `INPUT_TOKENS`; the pure-numpy oracle in `tests/llm-golden/synthetic/` computes
//! the same logits independently (`reference_forward.py`, the `intervene` hook at
//! the `build_cvec` site). As in `synthetic_logits.rs`, both read the same seeded
//! F32 weights but the oracle accumulates in float64, so they are compared within a
//! documented F32-vs-F64 tolerance (never bit-equality vs the oracle).
//!
//! Four things are proved here (D-016): (1) steered and ablated logits MATCH the
//! oracle within `ATOL`; (2) they DIFFER from the un-intervened base by `>> ATOL`
//! (a silent no-op fails loudly); (3) the source handle's base logits are
//! BITWISE-unchanged after every derivation (reversibility); (4) ablation OVERRIDES
//! a co-located steer bit-for-bit (the mandated compose order `(x+steer)⊙mask+add`).
//! Runs in the `cargo test -p rebirth-llm` CI job on the CPU backend, download-free.

use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, InterventionSpec, LoadRequest, Logits};

/// The fixed golden input (`synthetic_model.INPUT_TOKENS`).
const INPUT_TOKENS: [i32; 8] = [1, 7, 13, 22, 5, 31, 44, 2];

/// The intervention spec, engine-native (0-based), mirroring the module constants
/// in `reference_forward.py` (STEER_LAYER / ABLATE_LAYER / ABLATE_NEURON /
/// ABLATE_VALUE). The steer VECTOR is read from `intervene_steer_vector.csv` so the
/// engine applies the byte-for-byte identical vector the oracle used.
const STEER_LAYER: usize = 1; // engine il; the native cvec cannot reach il = 0
const ABLATE_LAYER: usize = 0; // engine il; the intervene adapter covers all layers
const ABLATE_NEURON: usize = 2; // chosen by reference_forward.py --select
const ABLATE_VALUE: f32 = 0.0;

/// Tolerance for the F32 engine vs the float64 oracle — the same `1e-2` the sibling
/// `synthetic_logits`/`synthetic_trace` gates use (the intervened logits carry the
/// same F32/F64 op-order gap as the base pass; observed max |Δ| is printed at the
/// end of the run, ~2e-3, well within this band and far below a real regression).
const ATOL: f64 = 1e-2;

/// Effect-size floor: each intervention must move the logits vs the base by more
/// than this (>> ATOL), so a silent no-op fails loudly. The measured effects are
/// ~1.5-2.4 (recorded as intervene_*_max_abs_delta in the golden metadata), far
/// above this floor.
const MIN_EFFECT: f64 = 0.1;

fn repo_root() -> PathBuf {
    // rebirth-llm is at rebirth/src/rust/rebirth-llm; the repo root is 4 up.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .join("..")
}

fn golden_dir() -> PathBuf {
    repo_root().join("tests/llm-golden/synthetic/goldens")
}

fn synthetic_gguf() -> PathBuf {
    repo_root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf")
}

/// Parse a logits CSV (`position,logit_0,...`; one row per position) into a
/// `seq_len x n_vocab` float64 matrix (the same reader as `synthetic_logits.rs`).
fn read_logits_csv(name: &str) -> Vec<Vec<f64>> {
    let path = golden_dir().join(name);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "cannot read golden {} ({e}); run reference_forward.py",
            path.display()
        )
    });
    let mut rows = Vec::new();
    for line in text.lines().skip(1) {
        if line.trim().is_empty() {
            continue;
        }
        let row: Vec<f64> = line
            .split(',')
            .skip(1) // drop the position column
            .map(|s| s.trim().parse::<f64>().expect("golden logit parses as f64"))
            .collect();
        rows.push(row);
    }
    rows
}

/// Read `intervene_steer_vector.csv` (`neuron,value`) into the exact F32 vector the
/// oracle applied: parse the value column as f64 (its exact-F32 decimal) and cast
/// back to f32, recovering the original float32 bit-for-bit.
fn read_steer_vector() -> Vec<f32> {
    let path = golden_dir().join("intervene_steer_vector.csv");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "cannot read {} ({e}); run reference_forward.py",
            path.display()
        )
    });
    text.lines()
        .skip(1)
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            l.split(',')
                .nth(1)
                .expect("steer csv has a value column")
                .trim()
                .parse::<f64>()
                .expect("steer value parses as f64") as f32
        })
        .collect()
}

/// Max absolute deviation of engine (f32) logits from the float64 oracle over every
/// position and vocab entry; panics past `ATOL` (the gate must not be loosened).
fn assert_logits_match_oracle(name: &str, engine: &Logits, oracle: &[Vec<f64>]) -> f64 {
    assert_eq!(oracle.len(), engine.seq_len, "{name}: golden row count");
    assert_eq!(oracle[0].len(), engine.n_vocab, "{name}: vocab width");
    let mut max_abs = 0.0f64;
    for (pos, oracle_row) in oracle.iter().enumerate() {
        for (j, (&e, &o)) in engine.row(pos).iter().zip(oracle_row.iter()).enumerate() {
            let d = (e as f64 - o).abs();
            max_abs = max_abs.max(d);
            assert!(
                d <= ATOL,
                "{name} logit[{pos}][{j}] engine={e} oracle={o} |Δ|={d:.3e} > {ATOL:.1e}"
            );
        }
    }
    max_abs
}

/// Max absolute difference between two engine (f32) logit sets — the intervention's
/// effect size vs the base.
fn max_abs_diff(a: &Logits, b: &Logits) -> f64 {
    a.values
        .iter()
        .zip(b.values.iter())
        .map(|(&x, &y)| (x as f64 - y as f64).abs())
        .fold(0.0, f64::max)
}

fn load_synthetic() -> rebirth_llm::LoadedModel {
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
        // CPU so the exact-value path runs identically on every CI platform.
        backend: BackendKind::Cpu,
        mmap: true,
        projector: None,
    })
    .expect("synthetic model loads")
}

#[test]
fn engine_interventions_match_numpy_oracle_and_are_reversible() {
    let model = load_synthetic();
    let meta = model.metadata();
    let n_embd = meta.hidden_size.max(0) as usize;
    let n_layer = meta.layers.max(0) as usize;

    let base_golden = read_logits_csv("logits.csv");
    let steer_golden = read_logits_csv("intervene_steer_logits.csv");
    let ablate_golden = read_logits_csv("intervene_ablate_logits.csv");
    let both_golden = read_logits_csv("intervene_both_logits.csv");
    let steer_vec = read_steer_vector();
    assert_eq!(steer_vec.len(), n_embd, "steer vector width == n_embd");

    // 1) Base: the un-intervened engine matches the committed base golden. Keep the
    //    exact f32 values for the reversibility check (step 5).
    let base = model
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("base teacher-forced logits");
    let base_delta = assert_logits_match_oracle("base", &base, &base_golden);

    // 2) Steering (engine il = STEER_LAYER by the golden vector, coef = 1): matches
    //    the steer golden AND moves the logits vs the base by >> ATOL.
    let mut steer_spec = InterventionSpec::new(n_embd, n_layer);
    steer_spec.add_steer(STEER_LAYER, &steer_vec);
    let steered = model
        .derive_with_interventions(&steer_spec)
        .expect("derive steered handle")
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("steered logits");
    let steer_delta = assert_logits_match_oracle("steer", &steered, &steer_golden);
    let steer_effect = max_abs_diff(&steered, &base);
    assert!(
        steer_effect > MIN_EFFECT,
        "steering had no effect: max |Δ| vs base = {steer_effect:.3e} <= {MIN_EFFECT} (silent no-op?)"
    );

    // 3) Ablation (engine il = ABLATE_LAYER neuron ABLATE_NEURON -> ABLATE_VALUE, the
    //    full-coverage layer the native cvec cannot reach): matches the ablate golden
    //    AND differs from the base by >> ATOL.
    let mut ablate_spec = InterventionSpec::new(n_embd, n_layer);
    ablate_spec.add_ablation(ABLATE_LAYER, &[ABLATE_NEURON], ABLATE_VALUE);
    let ablated = model
        .derive_with_interventions(&ablate_spec)
        .expect("derive ablated handle")
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("ablated logits");
    let ablate_delta = assert_logits_match_oracle("ablate", &ablated, &ablate_golden);
    let ablate_effect = max_abs_diff(&ablated, &base);
    assert!(
        ablate_effect > MIN_EFFECT,
        "ablation had no effect: max |Δ| vs base = {ablate_effect:.3e} <= {MIN_EFFECT} (silent no-op?)"
    );

    // 4) Composition (steer il = STEER_LAYER + ablate il = ABLATE_LAYER): matches the
    //    composed golden -- two interventions at different layers both apply.
    let mut both_spec = InterventionSpec::new(n_embd, n_layer);
    both_spec.add_steer(STEER_LAYER, &steer_vec);
    both_spec.add_ablation(ABLATE_LAYER, &[ABLATE_NEURON], ABLATE_VALUE);
    let both = model
        .derive_with_interventions(&both_spec)
        .expect("derive composed handle")
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("composed logits");
    let both_delta = assert_logits_match_oracle("both", &both, &both_golden);
    assert!(
        max_abs_diff(&both, &base) > MIN_EFFECT,
        "composition had no effect vs base (silent no-op?)"
    );

    // 5) Reversibility (D-016): the SOURCE handle's context was never touched, so
    //    re-running the base forward pass reproduces step 1's logits BIT-FOR-BIT --
    //    the strongest form of the "outputs reproduce bit-for-bit" acceptance.
    let base_again = model
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("base logits after derivations");
    assert_eq!(
        base.values, base_again.values,
        "the source handle changed after deriving interventions (reversibility broken)"
    );

    // 6) Compose order (D-016, addendum #6): ablation runs AFTER the steer, so a
    //    jointly steered+ablated neuron is forced to `value` regardless of the steer.
    //    A one-hot steer on the ablated neuron must be completely overridden ->
    //    logits BITWISE-equal to ablate-only. Same layer/neuron (unlike step 4), so
    //    this is what exercises the C++ apply-order at the numerical level.
    let compose_layer = STEER_LAYER; // both interventions on the same layer/neuron
    let compose_neuron = 5usize;
    let compose_value = 3.0f32;
    let mut onehot = vec![0.0f32; n_embd];
    onehot[compose_neuron] = 1000.0; // a large steer the ablation must override

    let mut ablate_only = InterventionSpec::new(n_embd, n_layer);
    ablate_only.add_ablation(compose_layer, &[compose_neuron], compose_value);
    let a = model
        .derive_with_interventions(&ablate_only)
        .expect("derive ablate-only")
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("ablate-only logits");

    let mut steer_then_ablate = InterventionSpec::new(n_embd, n_layer);
    steer_then_ablate.add_steer(compose_layer, &onehot);
    steer_then_ablate.add_ablation(compose_layer, &[compose_neuron], compose_value);
    let b = model
        .derive_with_interventions(&steer_then_ablate)
        .expect("derive steer-then-ablate")
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("steer-then-ablate logits");
    assert_eq!(
        a.values, b.values,
        "ablation must override a co-located steer bit-for-bit (compose order broken)"
    );

    eprintln!(
        "intervene engine-vs-oracle max |Δ|: base={base_delta:.3e} steer={steer_delta:.3e} \
         ablate={ablate_delta:.3e} both={both_delta:.3e} (atol {ATOL:.1e}); effects vs base: \
         steer={steer_effect:.3e} ablate={ablate_effect:.3e}"
    );
}
