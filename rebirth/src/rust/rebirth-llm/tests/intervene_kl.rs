//! WP5 acceptance fixture 2 of 2: ABLATION MEANINGFULLY SHIFTS THE NEXT-TOKEN
//! DISTRIBUTION (measured as KL divergence). [MODEL]-gated on
//! REBIRTH_TEST_MODEL_QWEN (docs/wp5-intervention-plan.md sections 7.2/9, Fable-5
//! addendum #13: the KL honesty fixture is a Rust integration test because
//! `llm_logits` is not yet an R entry point).
//!
//! The exact numerical effect of an ablation and its bit-for-bit reversibility are
//! proven on the synthetic model against the numpy oracle (`synthetic_intervene.rs`).
//! This fixture proves the SEMANTIC claim on a real model: ablating a small set of
//! residual neurons *chosen for impact* measurably moves the next-token distribution,
//! whereas random neurons and a no-op barely move it -- the statistical-honesty
//! evidence that keeps the ablation claim ("audit / localize", CLAUDE.md) honest.
//!
//! The synthetic in-repo GGUF is no_vocab (no tokenizer), so this fixture is
//! [MODEL]-gated: it SKIPS cleanly in CI (`cargo test` compiles it and it returns
//! early with no model) and runs on the founder's Mac / nightly. `logits_for_tokens`
//! is teacher-forced and deterministic, so the KLs reproduce run to run.
//!
//! [MODEL] PIN (provenance; no committed model registry exists yet -- that is
//! Phase 3): the calibration model is Qwen2.5-0.5B-Instruct Q8_0, SHA256
//! ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e -- the same
//! pinned file TARGETED_NEURONS below were calibrated against.
//!
//! ADVERSARIAL DESIGN -- this fixture must FAIL on a no-op ablation. The `noop`
//! measurement below derives a handle from an EMPTY spec (a fresh context with no
//! adapter): its next-token distribution equals base, so KL is ~0. If deriving a
//! handle (or the intervene adapter's identity path) perturbed the logits, or if the
//! KL metric were inflated by comparing two contexts, that guard fails. The matched-
//! RANDOM control is the second guard: if "ablation" moved the distribution merely
//! because *any* neurons were forced to zero, random neurons would shift it as much
//! as the targeted ones -- so the targeted effect must dominate the random one.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use rebirth_llm::{
    available_backends, load, BackendKind, InterventionSpec, LoadRequest, LoadedModel,
};

/// Committed prompts: short factual/relational completions whose next-token
/// distribution is sharply peaked, so an ablation's effect on it is clearly
/// measurable. Version-controlled with this test (the "committed prompt set").
const PROMPTS: &[&str] = &[
    "The capital of France is",
    "The opposite of hot is",
    "Two plus two equals",
    "The sun rises in the",
    "Water is made of hydrogen and",
    "A group of wolves is called a",
    "The first president of the United States was",
    "Roses are red, violets are",
];

/// Engine-native (0-based) transformer block to ablate -- the `InterventionSpec`
/// layer convention (as in `synthetic_intervene.rs`). Engine il 20 is API layer 21
/// of Qwen2.5-0.5B's 24 blocks (a late layer, where residual ablation strongly
/// shapes the next token).
const ABLATE_LAYER: usize = 20;

/// TARGETED residual neurons (0-based): the eight highest next-token-KL neurons of
/// `ABLATE_LAYER`, selected by the one-time full per-neuron scan in `calibrate_kl`
/// (below, run with `--ignored`) on the pinned Qwen2.5-0.5B-Instruct Q8_0. This is
/// a committed golden: regenerating it (a new/changed pinned model) means re-running
/// `calibrate_kl` and pasting the new top-8. Calibrated 2026-07-06: ablating this
/// set to zero gives mean KL ~1.07; the single strongest neuron (first below) ~0.68.
const TARGETED_NEURONS: &[usize] = &[62, 490, 208, 570, 757, 591, 337, 800];

/// The ablated value (API-GRAMMAR section 4 default; "forced to value").
const ABLATE_VALUE: f32 = 0.0;

// --- calibrated thresholds (2026-07-06; wide margins so the fixture is not flaky) --
/// The targeted ablation must clear this. Observed 1.07 (>5x this floor), while a
/// no-op is 0 and matched-random sets are ~0.01 -- so this cleanly separates a
/// meaningful shift from noise. This is the task's "KL >> floor".
const TARGETED_KL_FLOOR: f64 = 0.20;
/// The single strongest targeted neuron alone must clear this ("ablate a residual
/// neuron"). Observed 0.68.
const SINGLE_NEURON_KL_FLOOR: f64 = 0.10;
/// A no-op (empty-spec) derivation must be at or below this. Observed exactly 0.
const NOOP_KL_CEIL: f64 = 1e-6;
/// Each matched-random ablation (same size as the targeted set) must stay below
/// this. Observed ~0.010. A random ablation barely moves the distribution.
const RANDOM_KL_CEIL: f64 = 0.10;
/// The targeted effect must exceed the mean matched-random effect by this factor.
/// Observed ~100x; require 5x for slack (the honesty threshold, plan section 7.2).
const TARGETED_OVER_RANDOM: f64 = 5.0;
/// Fixed seeds for the matched-random neuron sets (deterministic, reproducible).
const RANDOM_SEEDS: &[u64] = &[1, 2, 3];

fn qwen_model_path() -> Option<PathBuf> {
    match std::env::var("REBIRTH_TEST_MODEL_QWEN") {
        Ok(p) if !p.is_empty() && Path::new(&p).exists() => Some(PathBuf::from(p)),
        _ => None,
    }
}

fn pick_backend() -> BackendKind {
    // First available in preference order (Metal on the founder's Mac, CPU in CI /
    // on a non-Metal host). The KL is teacher-forced and backend-deterministic.
    available_backends()
        .into_iter()
        .next()
        .unwrap_or(BackendKind::Cpu)
}

fn load_qwen(path: PathBuf) -> LoadedModel {
    load(LoadRequest {
        path,
        context_length: 512,
        gpu_layers: None,
        backend: pick_backend(),
        mmap: true,
    })
    .expect("load Qwen2.5-0.5B")
}

/// Softmax of a logit row into a probability distribution (float64, max-shifted).
fn softmax(logits: &[f32]) -> Vec<f64> {
    let max = logits.iter().cloned().fold(f32::NEG_INFINITY, f32::max) as f64;
    let exps: Vec<f64> = logits.iter().map(|&l| ((l as f64) - max).exp()).collect();
    let sum: f64 = exps.iter().sum();
    exps.into_iter().map(|e| e / sum).collect()
}

/// KL(p || q) in nats. Terms with `p_i == 0` contribute 0 (the limit); `q_i` is
/// floored away from zero so a log is always finite (softmax q is strictly > 0).
fn kl_divergence(p: &[f64], q: &[f64]) -> f64 {
    assert_eq!(p.len(), q.len(), "KL operands must share support");
    p.iter()
        .zip(q.iter())
        .filter(|(&pi, _)| pi > 0.0)
        .map(|(&pi, &qi)| pi * (pi.ln() - qi.max(1e-300).ln()))
        .sum()
}

/// The next-token distribution given `prompt`: softmax over the last position's
/// teacher-forced logits (`logits_for_tokens`, the WP2 oracle path).
fn next_token_dist(model: &LoadedModel, prompt: &str) -> Vec<f64> {
    let enc = model.encode(prompt, true, false).expect("tokenize prompt");
    assert!(
        !enc.ids.is_empty(),
        "prompt tokenized to nothing: {prompt:?}"
    );
    let logits = model
        .logits_for_tokens(&enc.ids)
        .expect("teacher-forced logits");
    softmax(logits.row(logits.seq_len - 1))
}

/// Mean over the committed prompts of KL(base || derived), where `derived` applies
/// `spec` to a fresh context on the shared weights.
fn mean_kl_vs_base(base: &[Vec<f64>], model: &LoadedModel, spec: &InterventionSpec) -> f64 {
    let derived = model
        .derive_with_interventions(spec)
        .expect("derive intervened handle");
    let total: f64 = PROMPTS
        .iter()
        .enumerate()
        .map(|(i, p)| kl_divergence(&base[i], &next_token_dist(&derived, p)))
        .sum();
    total / PROMPTS.len() as f64
}

/// A deterministic distinct-index set (SplitMix64), so "random" neuron selections
/// are reproducible with no RNG dependency.
fn pseudo_random_set(seed: u64, n: usize, k: usize) -> Vec<usize> {
    let mut state = seed;
    let mut next = || {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    };
    let mut set = BTreeSet::new();
    while set.len() < k {
        set.insert((next() as usize) % n);
    }
    set.into_iter().collect()
}

#[test]
fn ablation_shifts_next_token_distribution_kl() {
    let Some(path) = qwen_model_path() else {
        eprintln!("SKIP ablation_shifts_next_token_distribution_kl: REBIRTH_TEST_MODEL_QWEN unset");
        return;
    };
    let model = load_qwen(path);
    let meta = model.metadata();
    let n_embd = meta.hidden_size.max(0) as usize;
    let n_layer = meta.layers.max(0) as usize;
    assert!(
        ABLATE_LAYER < n_layer,
        "ABLATE_LAYER within the model's blocks"
    );
    assert!(
        TARGETED_NEURONS.iter().all(|&k| k < n_embd),
        "targeted neurons within hidden size"
    );

    let base: Vec<Vec<f64>> = PROMPTS.iter().map(|p| next_token_dist(&model, p)).collect();

    // Metric self-check: KL of a distribution with itself is exactly 0 and KL is
    // non-negative (guards against a broken KL implementation inflating the effect).
    for dist in &base {
        assert_eq!(kl_divergence(dist, dist), 0.0, "KL(p||p) must be 0");
    }

    // --- adversarial guard 1: a no-op (empty spec) does not move the distribution --
    // A derived handle with NO adapter must reproduce base, so KL ~ 0. If this fails,
    // deriving a handle itself perturbs generation and every effect below is suspect.
    let noop_kl = mean_kl_vs_base(&base, &model, &InterventionSpec::new(n_embd, n_layer));
    assert!(
        noop_kl <= NOOP_KL_CEIL,
        "no-op (empty spec) shifted the distribution: mean KL = {noop_kl:.3e} > {NOOP_KL_CEIL:.0e}"
    );

    // --- the acceptance: a targeted residual ablation shifts the distribution ------
    // A single impact-selected neuron already clears its floor ("ablate a residual
    // neuron"); the top-8 set clears the larger floor by a wide margin.
    let mut single = InterventionSpec::new(n_embd, n_layer);
    single.add_ablation(ABLATE_LAYER, &TARGETED_NEURONS[..1], ABLATE_VALUE);
    let single_kl = mean_kl_vs_base(&base, &model, &single);
    assert!(
        single_kl > SINGLE_NEURON_KL_FLOOR,
        "single targeted neuron {} barely moved the distribution: mean KL = {single_kl:.4} <= {SINGLE_NEURON_KL_FLOOR}",
        TARGETED_NEURONS[0]
    );

    let mut targeted = InterventionSpec::new(n_embd, n_layer);
    targeted.add_ablation(ABLATE_LAYER, TARGETED_NEURONS, ABLATE_VALUE);
    let targeted_kl = mean_kl_vs_base(&base, &model, &targeted);
    assert!(
        targeted_kl > TARGETED_KL_FLOOR,
        "targeted ablation did not measurably shift the distribution: mean KL = {targeted_kl:.4} <= floor {TARGETED_KL_FLOOR}"
    );

    // --- adversarial guard 2: matched-random ablation is ~null vs targeted ---------
    // Same-size random neuron sets barely move the distribution; the targeted effect
    // must dominate their mean by TARGETED_OVER_RANDOM. This is the honesty control:
    // it is WHICH neurons are ablated, not how many, that matters.
    let random_kls: Vec<f64> = RANDOM_SEEDS
        .iter()
        .map(|&seed| {
            let neurons = pseudo_random_set(seed, n_embd, TARGETED_NEURONS.len());
            let mut spec = InterventionSpec::new(n_embd, n_layer);
            spec.add_ablation(ABLATE_LAYER, &neurons, ABLATE_VALUE);
            mean_kl_vs_base(&base, &model, &spec)
        })
        .collect();
    let mean_random_kl = random_kls.iter().sum::<f64>() / random_kls.len() as f64;
    for (&seed, &rkl) in RANDOM_SEEDS.iter().zip(random_kls.iter()) {
        assert!(
            rkl < RANDOM_KL_CEIL,
            "matched-random ablation (seed {seed}) moved the distribution too much: mean KL = {rkl:.4} >= {RANDOM_KL_CEIL} (is the targeted selection meaningless?)"
        );
    }
    assert!(
        targeted_kl > TARGETED_OVER_RANDOM * mean_random_kl,
        "targeted ablation did not dominate matched-random: targeted {targeted_kl:.4} vs {TARGETED_OVER_RANDOM}x mean-random {mean_random_kl:.4}"
    );

    eprintln!(
        "KL(base||ablated) mean over {} prompts: noop={noop_kl:.3e} single(neuron {})={single_kl:.4} \
         targeted(top-{})={targeted_kl:.4} random(mean of {})={mean_random_kl:.4} -> targeted/random={:.1}x",
        PROMPTS.len(),
        TARGETED_NEURONS[0],
        TARGETED_NEURONS.len(),
        RANDOM_SEEDS.len(),
        targeted_kl / mean_random_kl.max(1e-12),
    );
}

/// Provenance / regeneration for `TARGETED_NEURONS` (run with `--ignored`): a full
/// per-neuron scan of `ABLATE_LAYER` ranking each residual neuron by its next-token
/// KL, then the targeted-vs-random set comparison. Not part of the CI/nightly gate
/// (it takes minutes); it documents and reproduces how the pinned set was chosen.
#[test]
#[ignore = "provenance scan for TARGETED_NEURONS; run explicitly with --ignored"]
fn calibrate_kl() {
    let Some(path) = qwen_model_path() else {
        eprintln!("SKIP calibrate_kl: REBIRTH_TEST_MODEL_QWEN unset");
        return;
    };
    let model = load_qwen(path);
    let meta = model.metadata();
    let n_embd = meta.hidden_size.max(0) as usize;
    let n_layer = meta.layers.max(0) as usize;
    eprintln!(
        "n_embd={n_embd} n_layer={n_layer} backend={} il={ABLATE_LAYER}",
        meta.backend
    );

    let base: Vec<Vec<f64>> = PROMPTS.iter().map(|p| next_token_dist(&model, p)).collect();
    eprintln!(
        "noop(empty spec) mean KL = {:.3e}",
        mean_kl_vs_base(&base, &model, &InterventionSpec::new(n_embd, n_layer))
    );

    let mut ranked: Vec<(usize, f64)> = (0..n_embd)
        .map(|k| {
            let mut s = InterventionSpec::new(n_embd, n_layer);
            s.add_ablation(ABLATE_LAYER, &[k], ABLATE_VALUE);
            (k, mean_kl_vs_base(&base, &model, &s))
        })
        .collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    eprintln!("top-12 single-neuron KL at il={ABLATE_LAYER}:");
    for (k, d) in ranked.iter().take(12) {
        eprintln!("  neuron {k:3} KL={d:.4}");
    }
    let top8: Vec<usize> = ranked.iter().take(8).map(|(k, _)| *k).collect();
    eprintln!("-> paste as TARGETED_NEURONS: {top8:?}");

    let mut targeted = InterventionSpec::new(n_embd, n_layer);
    targeted.add_ablation(ABLATE_LAYER, &top8, ABLATE_VALUE);
    eprintln!(
        "TARGETED top-8 set KL = {:.4}",
        mean_kl_vs_base(&base, &model, &targeted)
    );
    for &seed in RANDOM_SEEDS {
        let neurons = pseudo_random_set(seed, n_embd, 8);
        let mut s = InterventionSpec::new(n_embd, n_layer);
        s.add_ablation(ABLATE_LAYER, &neurons, ABLATE_VALUE);
        eprintln!(
            "RANDOM-8 seed{seed} set KL = {:.4}",
            mean_kl_vs_base(&base, &model, &s)
        );
    }
}
