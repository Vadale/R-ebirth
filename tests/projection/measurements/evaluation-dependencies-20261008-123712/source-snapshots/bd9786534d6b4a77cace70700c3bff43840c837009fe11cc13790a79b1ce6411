//! Greedy-generation golden check + sampler determinism on the synthetic
//! 2-layer llama model (WP2 Step 3, golden-first).
//!
//! Greedy decoding is exact and reproducible, so it is pinned token-for-token
//! against the numpy autoregressive golden built by
//! `tests/llm-golden/synthetic/reference_forward.py` (`greedy_continuation.csv`):
//! the engine, feeding each argmax back through its own KV cache, must retrace
//! the pure-numpy continuation exactly. The synthetic vocabulary keeps the
//! top-1/top-2 margin well above the F32 noise floor, so the integer argmax path
//! is precision-stable (see the harness README). Sampling cannot be pinned to a
//! value, so it is checked for the invariant that matters: same seed + params
//! ⇒ identical tokens (the determinism contract, ARCHITECTURE.md §7).
//!
//! Runs in the `cargo test -p rebirth-llm` CI job; download-free, CPU-only.

use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, GenerateParams, LoadRequest, LoadedModel, StopReason};

/// The fixed greedy prompt (`metadata.json` `greedy_prompt`).
const GREEDY_PROMPT: [i32; 2] = [1, 7];

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

fn greedy_golden_csv() -> PathBuf {
    repo_root().join("tests/llm-golden/synthetic/goldens/greedy_continuation.csv")
}

/// Parse `greedy_continuation.csv` (header `step,token`) into the token ids.
fn read_greedy_golden(path: &PathBuf) -> Vec<i32> {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read golden {}: {e}", path.display()));
    text.lines()
        .skip(1)
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            l.split(',')
                .nth(1)
                .expect("token column")
                .trim()
                .parse::<i32>()
                .expect("golden token is an integer")
        })
        .collect()
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
        // CPU so the exact-value path runs identically on every CI platform.
        backend: BackendKind::Cpu,
        mmap: true,
        projector: None,
    })
    .expect("synthetic model loads")
}

#[test]
fn greedy_generation_matches_numpy_golden() {
    let golden = greedy_golden_csv();
    assert!(
        golden.exists(),
        "greedy golden missing at {} (run reference_forward.py)",
        golden.display()
    );
    let expected = read_greedy_golden(&golden);
    assert_eq!(expected.len(), 16, "golden continuation length");

    let model = load_synthetic();
    let params = GenerateParams {
        max_tokens: expected.len(),
        temperature: 0.0, // greedy
        top_p: 1.0,
        seed: 0,
        stop: Vec::new(),
    };
    let generation = model.generate(&GREEDY_PROMPT, &params).expect("generate");

    assert_eq!(
        generation.tokens, expected,
        "greedy continuation must retrace the numpy oracle token-for-token"
    );
    assert_eq!(
        generation.stop_reason,
        StopReason::MaxTokens,
        "the synthetic model defines no EOG token, so it runs to max_tokens"
    );
    // The synthetic model has a vocabulary but no tokenizer, so the ids carry no
    // text form; detokenization is exercised on real models ([MODEL] tests).
    assert_eq!(generation.text, "");
}

#[test]
fn sampling_is_deterministic_under_a_fixed_seed() {
    let model = load_synthetic();
    let params = GenerateParams {
        max_tokens: 12,
        temperature: 0.8,
        top_p: 0.95,
        seed: 42,
        stop: Vec::new(),
    };

    let a = model.generate(&GREEDY_PROMPT, &params).expect("gen a");
    let b = model.generate(&GREEDY_PROMPT, &params).expect("gen b");

    assert_eq!(
        a.tokens, b.tokens,
        "same seed + params must yield identical tokens (determinism contract)"
    );
    assert_eq!(a.seed, 42, "the used seed is echoed back");
    assert_eq!(a.tokens.len(), 12);
    // Every sampled id is a valid vocabulary index.
    assert!(a.tokens.iter().all(|&t| (0..48).contains(&t)));
}

#[test]
fn max_tokens_zero_yields_an_empty_generation() {
    let model = load_synthetic();
    let params = GenerateParams {
        max_tokens: 0,
        temperature: 0.0,
        top_p: 1.0,
        seed: 0,
        stop: Vec::new(),
    };
    let generation = model.generate(&GREEDY_PROMPT, &params).expect("generate");
    assert!(generation.tokens.is_empty());
    assert_eq!(generation.text, "");
}
