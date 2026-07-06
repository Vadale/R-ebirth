//! Exact-value engine-vs-oracle check on the synthetic 2-layer llama model, for
//! activation tracing (WP4 Step 3/4, the numerical de-risking gate).
//!
//! The engine taps each per-layer component tensor (`attn_out`/`ffn_out`/`l_out`)
//! during a forward pass over the fixed `INPUT_TOKENS`, via the scheduler eval
//! callback (`activations`); the pure-numpy oracle in `tests/llm-golden/synthetic/`
//! computes the same intermediates independently. As in `synthetic_embed.rs`, both
//! read the same seeded F32 weights but the oracle accumulates in float64, so they
//! are compared within a documented F32-vs-F64 tolerance (never bit-equality).
//!
//! The golden `activations.csv` is laid out layer-major, then component order
//! (attn_out, mlp_out, residual), then token order, with 0-based `layer`/`token_pos`
//! (engine-native — this test does no 1-based conversion; that happens only in
//! `rebirth-ffi`). Runs in the `cargo test -p rebirth-llm` CI job (download-free,
//! synthetic only), on the CPU backend so the exact-value path is identical across
//! CI platforms.

use std::collections::HashMap;
use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, CaptureSpec, Component, LoadRequest, Positions};

/// The fixed golden input (`synthetic_model.INPUT_TOKENS`).
const INPUT_TOKENS: [i32; 8] = [1, 7, 13, 22, 5, 31, 44, 2];

/// Embedding width of the synthetic model (`synthetic_model.CONFIG.n_embd`).
const N_EMBD: usize = 32;

/// Tolerance for the F32 engine vs the float64 oracle. The observed max absolute
/// deviation across all 48 (layer, component, token) rows x 32 neurons is 3.73e-3
/// (macOS arm64 CPU; printed at the end of the run) — the same order as the sibling
/// `synthetic_embed`/`synthetic_logits` gates, since these pre-final-norm hidden
/// states carry the same F32/F64 RMSNorm + matmul op-order gap. `1e-2` matches
/// those gates (~2.7x headroom over the observed gap): tight enough to catch a real
/// regression (which moves values by >> 1e-2) while tolerating the cross-platform
/// F32 op-order differences CI's Linux CPU can introduce (which is why this is not
/// tightened to the raw macOS gap).
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

fn activations_csv() -> PathBuf {
    repo_root().join("tests/llm-golden/synthetic/goldens/activations.csv")
}

/// One golden row: its `(layer, component, token_pos)` coordinates (engine-native,
/// 0-based) and the `N_EMBD` float64 neuron values.
struct GoldenRow {
    layer: u32,
    component: String,
    token_pos: u32,
    values: Vec<f64>,
}

/// Parse `activations.csv` (header `layer,component,token_pos,neuron_0..neuron_31`).
/// The values are the columns after the first three (`skip(3)`, mirroring the
/// `read_embeddings_csv` idiom but skipping the three coordinate columns).
fn read_activations_csv(path: &PathBuf) -> Vec<GoldenRow> {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read golden {}: {e}", path.display()));
    let mut rows = Vec::new();
    for line in text.lines().skip(1) {
        if line.trim().is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split(',').collect();
        let layer = fields[0]
            .trim()
            .parse::<u32>()
            .expect("golden layer parses as u32");
        let component = fields[1].trim().to_string();
        let token_pos = fields[2]
            .trim()
            .parse::<u32>()
            .expect("golden token_pos parses as u32");
        let values: Vec<f64> = line
            .split(',')
            .skip(3)
            .map(|s| s.trim().parse::<f64>().expect("golden value parses as f64"))
            .collect();
        rows.push(GoldenRow {
            layer,
            component,
            token_pos,
            values,
        });
    }
    rows
}

/// Compare an engine (f32) vector against an oracle (f64) vector within `ATOL`,
/// returning the max absolute deviation seen. Panics with a precise message on the
/// first value that exceeds `ATOL` (the de-risking gate must not be loosened).
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
fn engine_activations_match_numpy_oracle_within_tolerance() {
    let gguf = synthetic_gguf();
    let csv = activations_csv();
    assert!(
        gguf.exists(),
        "synthetic GGUF missing at {} (run build_synthetic.py)",
        gguf.display()
    );
    assert!(
        csv.exists(),
        "activations golden missing at {} (run reference_forward.py)",
        csv.display()
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

    // Capture everything: all layers, all positions, all three components.
    let spec = CaptureSpec {
        layers: None,
        positions: Positions::All,
        components: vec![Component::Residual, Component::AttnOut, Component::MlpOut],
    };
    let rows = model
        .activations(&INPUT_TOKENS, &spec)
        .expect("activations capture");

    // 2 layers x 3 components x 8 tokens = 48 captured rows, each N_EMBD wide.
    assert_eq!(
        rows.len(),
        48,
        "captured (layer, component, token) row count"
    );

    // Index the capture by (layer, component, token_pos) for golden lookup.
    let mut captured: HashMap<(u32, String, u32), Vec<f32>> = HashMap::new();
    for row in &rows {
        assert_eq!(
            row.values.len(),
            N_EMBD,
            "captured row width for layer {} component {} token {}",
            row.layer,
            row.component.as_str(),
            row.token_pos
        );
        let key = (row.layer, row.component.as_str().to_string(), row.token_pos);
        assert!(
            captured.insert(key, row.values.clone()).is_none(),
            "duplicate capture for layer {} component {} token {}",
            row.layer,
            row.component.as_str(),
            row.token_pos
        );
    }

    let golden = read_activations_csv(&csv);
    assert_eq!(golden.len(), 48, "golden row count");

    let mut max_abs = 0.0f64;
    for g in &golden {
        let key = (g.layer, g.component.clone(), g.token_pos);
        let engine = captured.get(&key).unwrap_or_else(|| {
            panic!(
                "no captured activation for layer {} component {} token {}",
                g.layer, g.component, g.token_pos
            )
        });
        max_abs = max_abs.max(assert_within_atol(
            &format!(
                "activations[layer={},{}, token={}]",
                g.layer, g.component, g.token_pos
            ),
            engine,
            &g.values,
        ));
    }

    eprintln!("engine-vs-oracle activations max |Δ| = {max_abs:.3e} (atol {ATOL:.1e})");
}
