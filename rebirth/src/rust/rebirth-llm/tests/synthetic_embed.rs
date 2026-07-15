//! Exact-value engine-vs-oracle check on the synthetic 2-layer llama model, for
//! embeddings (WP3 Step 3, the numerical de-risking gate).
//!
//! The engine reads each token's post-final-norm hidden state via a NONE-pooling
//! embedding context (`token_embeddings`); the pure-numpy oracle in
//! `tests/llm-golden/synthetic/` computes the same `result_norm` tensor
//! independently (`reference_forward.py::hidden_states`, before the LM head). As
//! in `synthetic_logits.rs`, both read the same seeded F32 weights but the oracle
//! accumulates in float64, so they are compared within a documented F32-vs-F64
//! tolerance (never bit-equality). The mean/last pools and their L2-normalized
//! forms are checked against the oracle's `metadata.json`, pinning each pooling
//! mode and the normalize path.
//!
//! Runs in the `cargo test -p rebirth-llm` CI job (download-free, synthetic only),
//! on the CPU backend so the exact-value path is identical across CI platforms.

use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, LoadRequest, Pooling};

/// The fixed golden input (`synthetic_model.INPUT_TOKENS`).
const INPUT_TOKENS: [i32; 8] = [1, 7, 13, 22, 5, 31, 44, 2];

/// Embedding width of the synthetic model (`synthetic_model.CONFIG.n_embd`).
const N_EMBD: usize = 32;

/// Tolerance for the F32 engine vs the float64 oracle. The observed max absolute
/// deviation across the per-token hidden states, both pools, and their normalized
/// forms is 2.9e-3 (see the run log) — comparable to the logits test's ~2e-3, not
/// smaller: although these are the pre-LM-head `result_norm` states, RMSNorm's
/// divide-by-RMS is as F32-sensitive as the LM-head dot product, so the gap lands
/// in the same order. `1e-2` matches the tolerance the sibling `synthetic_logits`
/// gate uses on this model (~3.4x headroom over the observed gap): tight enough to
/// catch a real regression (which moves values by >> 1e-2) while tolerating the
/// cross-platform F32 op-order differences CI's Linux CPU can introduce.
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

fn goldens_dir() -> PathBuf {
    repo_root().join("tests/llm-golden/synthetic/goldens")
}

/// Parse `embeddings.csv` (header `position,embd_0,...`; one row per position)
/// into an `8 x n_embd` float64 matrix — same shape as `synthetic_logits.rs`.
fn read_embeddings_csv(path: &PathBuf) -> Vec<Vec<f64>> {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read golden {}: {e}", path.display()));
    let mut rows = Vec::new();
    for line in text.lines().skip(1) {
        if line.trim().is_empty() {
            continue;
        }
        // Drop the leading `position` column; keep the embedding values.
        let row: Vec<f64> = line
            .split(',')
            .skip(1)
            .map(|s| s.trim().parse::<f64>().expect("golden value parses as f64"))
            .collect();
        rows.push(row);
    }
    rows
}

/// Extract a flat JSON number array `"<key>": [ ... ]` from `metadata.json`. The
/// pooled goldens are flat number arrays (no nesting), so the first `]` after the
/// key's `[` closes it. Searching for the quoted key (`"mean_pool"`) is exact:
/// it never matches the `"mean_pool_normalized"` prefix (no closing quote there).
/// Kept tiny and hand-rolled to honor the no-new-dependency rule (no serde_json).
fn read_json_array(text: &str, key: &str) -> Vec<f64> {
    let needle = format!("\"{key}\"");
    let start = text
        .find(&needle)
        .unwrap_or_else(|| panic!("key {key} not found in metadata.json"));
    let after = &text[start + needle.len()..];
    let open = after.find('[').expect("array open bracket");
    let close = after.find(']').expect("array close bracket");
    after[open + 1..close]
        .split(',')
        .map(|s| {
            s.trim()
                .parse::<f64>()
                .expect("golden number parses as f64")
        })
        .collect()
}

/// Compare an engine (f32) vector against an oracle (f64) vector within `ATOL`,
/// returning the max absolute deviation seen. Panics with a precise message on
/// the first value that exceeds `ATOL` (the de-risking gate must not be loosened).
fn assert_within_atol(name: &str, engine: &[f32], oracle: &[f64]) -> f64 {
    assert_eq!(engine.len(), oracle.len(), "{name}: width mismatch");
    let mut max_abs = 0.0f64;
    for (k, (&e, &o)) in engine.iter().zip(oracle.iter()).enumerate() {
        let d = (e as f64 - o).abs();
        max_abs = max_abs.max(d);
        assert!(
            d <= ATOL,
            "{name}[{k}] engine={e} oracle={o} |Δ|={d:.3e} > {ATOL:.1e}"
        );
    }
    max_abs
}

#[test]
fn engine_embeddings_match_numpy_oracle_within_tolerance() {
    let gguf = synthetic_gguf();
    let embeddings_csv = goldens_dir().join("embeddings.csv");
    let metadata_json = goldens_dir().join("metadata.json");
    assert!(
        gguf.exists(),
        "synthetic GGUF missing at {} (run build_synthetic.py)",
        gguf.display()
    );
    assert!(
        embeddings_csv.exists(),
        "embeddings golden missing at {} (run reference_forward.py)",
        embeddings_csv.display()
    );

    let model = load(LoadRequest {
        path: gguf,
        context_length: 512,
        gpu_layers: None,
        // CPU so the exact-value path runs identically on every CI platform.
        backend: BackendKind::Cpu,
        mmap: true,
        projector: None,
    })
    .expect("synthetic model loads");

    let mut max_abs = 0.0f64;

    // 1) Per-token post-final-norm hidden states: the exact tensor
    //    llama_get_embeddings_ith returns under NONE pooling.
    let per_token = model
        .token_embeddings(&INPUT_TOKENS)
        .expect("per-token embeddings");
    assert_eq!(per_token.len(), INPUT_TOKENS.len(), "per-token row count");
    assert_eq!(per_token[0].len(), N_EMBD, "per-token embedding width");

    let oracle = read_embeddings_csv(&embeddings_csv);
    assert_eq!(oracle.len(), INPUT_TOKENS.len(), "golden row count");
    assert_eq!(oracle[0].len(), N_EMBD, "golden embedding width");
    for (i, oracle_row) in oracle.iter().enumerate() {
        max_abs = max_abs.max(assert_within_atol(
            &format!("embeddings[{i}]"),
            &per_token[i],
            oracle_row,
        ));
    }

    // 2) Mean / last pooling and their L2-normalized forms, against the oracle's
    //    metadata.json. Each pins one pooling mode (and the normalize path).
    let meta = std::fs::read_to_string(&metadata_json)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", metadata_json.display()));

    let mean = model
        .embed_token_batch(&[&INPUT_TOKENS], Pooling::Mean, false)
        .expect("mean pooling");
    assert_eq!(mean.n_rows, 1, "one input, one row");
    assert_eq!(mean.n_embd, N_EMBD, "pooled width");
    max_abs = max_abs.max(assert_within_atol(
        "mean_pool",
        &mean.values,
        &read_json_array(&meta, "mean_pool"),
    ));

    let last = model
        .embed_token_batch(&[&INPUT_TOKENS], Pooling::Last, false)
        .expect("last pooling");
    max_abs = max_abs.max(assert_within_atol(
        "last_pool",
        &last.values,
        &read_json_array(&meta, "last_pool"),
    ));

    let mean_norm = model
        .embed_token_batch(&[&INPUT_TOKENS], Pooling::Mean, true)
        .expect("mean pooling, normalized");
    max_abs = max_abs.max(assert_within_atol(
        "mean_pool_normalized",
        &mean_norm.values,
        &read_json_array(&meta, "mean_pool_normalized"),
    ));

    let last_norm = model
        .embed_token_batch(&[&INPUT_TOKENS], Pooling::Last, true)
        .expect("last pooling, normalized");
    max_abs = max_abs.max(assert_within_atol(
        "last_pool_normalized",
        &last_norm.values,
        &read_json_array(&meta, "last_pool_normalized"),
    ));

    eprintln!("engine-vs-oracle embeddings max |Δ| = {max_abs:.3e} (atol {ATOL:.1e})");
}

/// The crate-boundary length contract of `embed_texts_with_images` (WP-V3
/// reviewer finding): a texts/image_sets length mismatch must be a REAL
/// classed rejection in every build profile — a release build must never
/// silently truncate the pairing (which would let R's matrix() recycle values
/// into wrong rows). Model-free per-commit CI (`cargo test`, run in release
/// there — exactly the profile where a debug_assert would have vanished); the
/// check fires before the tokenizer/vision requirements, so the in-repo
/// synthetic model suffices.
#[test]
fn embed_texts_with_images_rejects_a_length_mismatch() {
    let gguf = synthetic_gguf();
    assert!(gguf.exists(), "synthetic GGUF missing");
    let model = load(LoadRequest {
        path: gguf,
        context_length: 512,
        gpu_layers: None,
        backend: BackendKind::Cpu,
        mmap: true,
        projector: None,
    })
    .expect("synthetic model loads");

    for (texts, sets) in [
        (vec!["a", "b"], vec![Vec::<String>::new()]),
        (vec!["a"], vec![Vec::<String>::new(), Vec::new()]),
        (vec!["a"], vec![]),
    ] {
        let err = model
            .embed_texts_with_images(&texts, &sets, Pooling::Mean, true, 64 * 1024 * 1024)
            .expect_err("length mismatch must reject, never truncate");
        assert_eq!(err.class(), "relm_error_internal", "{texts:?} vs {sets:?}");
        assert!(
            err.to_string().contains("image set"),
            "the message names the contract: {err}"
        );
    }
}
