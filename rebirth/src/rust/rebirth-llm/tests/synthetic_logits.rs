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

use rebirth_llm::{load, BackendKind, LoadRequest};

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
