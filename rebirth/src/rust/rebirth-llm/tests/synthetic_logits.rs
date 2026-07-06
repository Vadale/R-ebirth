//! Exact-value engine-vs-oracle check on the synthetic 2-layer llama model.
//!
//! STEP 1 of WP2 (the de-risking step). The engine computes teacher-forced
//! next-token logits for the fixed `INPUT_TOKENS`; the pure-numpy oracle in
//! `tests/llm-golden/synthetic/` computes the same rows independently. Because
//! both read the same seeded F32 weights but the oracle accumulates in float64,
//! the two are compared within a documented F32-vs-F64 tolerance (never
//! bit-equality — cross-implementation float differs by op order / FMA). The
//! integer greedy argmax must match exactly at every position: the synthetic
//! weights keep the top-1 vs top-2 margin ~5e-2, far above the F32 noise floor.
//!
//! This test runs in the `cargo test -p rebirth-llm` CI job (rust.yaml), which
//! builds the vendored engine; it is download-free and synthetic-model-only.

use std::path::PathBuf;

use rebirth_llm::{load, top_k_logits, BackendKind, LoadRequest};

/// The fixed golden input (`synthetic_model.INPUT_TOKENS`).
const INPUT_TOKENS: [i32; 8] = [1, 7, 13, 22, 5, 31, 44, 2];

/// Tolerance for the F32 engine vs the float64 oracle (see the harness README
/// "engine-vs-oracle" section). The observed max absolute deviation on this
/// 2-layer model is ~2e-3 (F32 accumulation vs float64 truth); a real regression
/// moves logits by >> 1e-2. `1e-2` gives ~5x headroom over the observed gap while
/// staying ~5x below the ~5e-2 top-1/top-2 margin that keeps greedy decoding
/// precision-stable, so it separates "same computation" from "regression"
/// cleanly and tolerates cross-platform F32 op-order differences.
const ATOL: f64 = 1e-2;

fn repo_root() -> PathBuf {
    // rebirth-llm is at rebirth/src/rust/rebirth-llm; the repo root is 4 up.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .join("..")
}

fn synthetic_gguf() -> PathBuf {
    repo_root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf")
}

fn golden_logits_csv() -> PathBuf {
    repo_root().join("tests/llm-golden/synthetic/goldens/logits.csv")
}

/// Parse `logits.csv` (header `position,logit_0,...`; one row per position) into
/// a `seq_len x n_vocab` float64 matrix.
fn read_golden_csv(path: &PathBuf) -> Vec<Vec<f64>> {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read golden {}: {e}", path.display()));
    let mut rows = Vec::new();
    for line in text.lines().skip(1) {
        if line.trim().is_empty() {
            continue;
        }
        // Drop the leading `position` column; keep the vocab logits.
        let row: Vec<f64> = line
            .split(',')
            .skip(1)
            .map(|s| s.trim().parse::<f64>().expect("golden logit parses as f64"))
            .collect();
        rows.push(row);
    }
    rows
}

fn argmax(row: &[f32]) -> usize {
    let mut best = 0usize;
    for (i, &v) in row.iter().enumerate() {
        if v > row[best] {
            best = i;
        }
    }
    best
}

#[test]
fn engine_logits_match_numpy_oracle_within_tolerance() {
    let gguf = synthetic_gguf();
    let golden = golden_logits_csv();
    assert!(
        gguf.exists(),
        "synthetic GGUF missing at {} (run build_synthetic.py)",
        gguf.display()
    );
    assert!(
        golden.exists(),
        "logit golden missing at {} (run reference_forward.py)",
        golden.display()
    );

    let model = load(LoadRequest {
        path: gguf,
        context_length: 512,
        gpu_layers: None,
        // CPU so the exact-value path runs identically on every CI platform.
        backend: BackendKind::Cpu,
        mmap: true,
    })
    .expect("synthetic model loads");

    let logits = model
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("teacher-forced logits");

    let oracle = read_golden_csv(&golden);
    assert_eq!(oracle.len(), INPUT_TOKENS.len(), "golden row count");
    assert_eq!(logits.seq_len, INPUT_TOKENS.len());
    assert_eq!(logits.n_vocab, oracle[0].len(), "vocab width");

    let mut max_abs = 0.0f64;
    for (pos, oracle_row) in oracle.iter().enumerate() {
        let engine_row = logits.row(pos);

        // 1) Integer greedy argmax must match exactly (precision-stable).
        assert_eq!(
            argmax(engine_row),
            argmax_f64(oracle_row),
            "greedy argmax differs at position {pos}"
        );

        // 2) Every logit within the F32-vs-F64 tolerance.
        for (j, (&e, &o)) in engine_row.iter().zip(oracle_row.iter()).enumerate() {
            let d = (e as f64 - o).abs();
            max_abs = max_abs.max(d);
            assert!(
                d <= ATOL,
                "logit[{pos}][{j}] engine={e} oracle={o} |Δ|={d:.3e} > {ATOL:.1e}"
            );
        }
    }
    eprintln!("engine-vs-oracle max |Δ| = {max_abs:.3e} (atol {ATOL:.1e})");
}

fn argmax_f64(row: &[f64]) -> usize {
    let mut best = 0usize;
    for (i, &v) in row.iter().enumerate() {
        if v > row[best] {
            best = i;
        }
    }
    best
}

/// Full-vocab softmax of a float64 row (max-shifted) — the oracle probability the
/// engine's `top_k_logits` must reproduce.
fn softmax_f64(row: &[f64]) -> Vec<f64> {
    let max = row.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let exps: Vec<f64> = row.iter().map(|&v| (v - max).exp()).collect();
    let total: f64 = exps.iter().sum();
    exps.into_iter().map(|e| e / total).collect()
}

/// The `top` highest-logit ids of `row`, descending by logit, ties by ascending id
/// — the reference ordering `top_k_logits` must match.
fn oracle_top_ids(row: &[f64], top: usize) -> Vec<usize> {
    let mut order: Vec<usize> = (0..row.len()).collect();
    order.sort_by(|&a, &b| row[b].total_cmp(&row[a]).then(a.cmp(&b)));
    order.truncate(top);
    order
}

/// How many top tokens the golden gate ranks. Well within the synthetic vocab (48)
/// and, at the final position, every consecutive gap in this prefix exceeds
/// `2 * ATOL` — asserted below — so the F32 engine cannot reorder the ranking
/// relative to the float64 oracle. A regression that scrambles the ordering or the
/// values is still caught by the id + logit + prob checks.
const TOP: usize = 8;

/// The engine's top-k next-token extraction over the synthetic model's final
/// position matches the numpy oracle: same token ordering, logit values within the
/// harness ATOL, and full-vocab softmax probabilities. This is the `llm_logits`
/// numeric gate — it exercises the exact `top_k_logits` path the FFI calls, on the
/// `no_vocab` synthetic model (no tokenizer, so the text-level path is Qwen-gated).
#[test]
fn top_k_extraction_matches_numpy_oracle_at_the_final_position() {
    let gguf = synthetic_gguf();
    let golden = golden_logits_csv();
    assert!(
        gguf.exists(),
        "synthetic GGUF missing at {}",
        gguf.display()
    );
    assert!(
        golden.exists(),
        "logit golden missing at {}",
        golden.display()
    );

    let model = load(LoadRequest {
        path: gguf,
        context_length: 512,
        gpu_layers: None,
        backend: BackendKind::Cpu,
        mmap: true,
    })
    .expect("synthetic model loads");

    let logits = model
        .logits_for_tokens(&INPUT_TOKENS)
        .expect("teacher-forced logits");
    let oracle = read_golden_csv(&golden);
    assert_eq!(oracle.len(), INPUT_TOKENS.len(), "golden row count");

    // The next-token distribution is the FINAL position's row (what llm_logits
    // returns): engine last row vs the golden's last row.
    let last = INPUT_TOKENS.len() - 1;
    let engine_row = logits.row(last);
    let oracle_row = &oracle[last];
    assert_eq!(engine_row.len(), oracle_row.len(), "vocab width");

    let picks = top_k_logits(engine_row, TOP);
    assert_eq!(picks.len(), TOP, "top-{TOP} rows");

    let oracle_ids = oracle_top_ids(oracle_row, TOP);
    let oracle_probs = softmax_f64(oracle_row);

    // Self-guard: the oracle's ranked prefix is separated by > 2*ATOL at every step,
    // so an F32 logit shift (bounded by ATOL) cannot reorder it. If a future golden
    // regeneration narrows a gap, this fires and says to lower TOP — never a flake.
    for k in 1..TOP {
        let gap = oracle_row[oracle_ids[k - 1]] - oracle_row[oracle_ids[k]];
        assert!(
            gap > 2.0 * ATOL,
            "oracle top-{TOP} gap at rank {} is {gap:.3e} <= 2*ATOL; lower TOP",
            k + 1
        );
    }

    let mut max_logit_d = 0.0f64;
    let mut max_prob_d = 0.0f64;
    let mut prev_logit = f32::INFINITY;
    let mut prev_prob = f64::INFINITY;
    for (rank, &(id, logit, prob)) in picks.iter().enumerate() {
        // 1) Ordering: the engine's k-th token id is the oracle's k-th token id.
        assert_eq!(
            id,
            oracle_ids[rank],
            "top-k token id differs at rank {}",
            rank + 1
        );
        // 2) Logit value within the F32-vs-F64 harness tolerance.
        let ld = (logit as f64 - oracle_row[id]).abs();
        max_logit_d = max_logit_d.max(ld);
        assert!(
            ld <= ATOL,
            "logit at rank {} |Δ|={ld:.3e} > {ATOL:.1e}",
            rank + 1
        );
        // 3) Full-vocab softmax probability matches the oracle's.
        let pd = (prob - oracle_probs[id]).abs();
        max_prob_d = max_prob_d.max(pd);
        assert!(
            pd <= ATOL,
            "prob at rank {} |Δ|={pd:.3e} > {ATOL:.1e}",
            rank + 1
        );
        // 4) Structure: prob in (0, 1], and both logit and prob are non-increasing
        //    with rank (rank 1 is the argmax).
        assert!(prob > 0.0 && prob <= 1.0, "prob {prob} out of (0, 1]");
        assert!(
            logit <= prev_logit,
            "logit not non-increasing at rank {}",
            rank + 1
        );
        assert!(
            prob <= prev_prob,
            "prob not non-increasing at rank {}",
            rank + 1
        );
        prev_logit = logit;
        prev_prob = prob;
    }
    // Full-vocab softmax: the retained top-TOP mass excludes the tail, so it is < 1
    // (a renormalized top-k share would sum to exactly 1 — this catches that bug).
    let kept_mass: f64 = picks.iter().map(|&(_, _, p)| p).sum();
    assert!(
        kept_mass < 1.0,
        "top-{TOP} mass {kept_mass} should exclude the tail"
    );

    eprintln!(
        "top-k gate: max |Δlogit| = {max_logit_d:.3e}, max |Δprob| = {max_prob_d:.3e} (atol {ATOL:.1e})"
    );
}
