//! Spill-path de-risking gate on the synthetic 2-layer llama model (WP4 Step 5,
//! D-013). Proves the predictive decision (in memory / spill / OOM) and that the
//! Arrow-IPC file the writer thread produces round-trips back to exactly the same
//! values as the in-memory capture — independent of the R/nanoarrow reader (which
//! the `test-llm-trace-spill.R` round-trip covers separately).
//!
//! Runs in the `cargo test -p rebirth-llm` CI job (download-free, synthetic only),
//! on the CPU backend. The model is `no_vocab`, so the raw-id spill entry
//! (`trace_token_batch_spill`) is used — no tokenizer needed.
#![cfg(feature = "spill")]

use std::collections::HashMap;
use std::path::PathBuf;

use arrow_array::{Float32Array, StringArray, UInt32Array};
use arrow_ipc::reader::StreamReader;
use rebirth_llm::{
    load, BackendKind, CaptureSpec, Component, LoadRequest, LoadedModel, Positions, SpillPlan,
    TraceOutput,
};

const INPUT_TOKENS: [i32; 8] = [1, 7, 13, 22, 5, 31, 44, 2];
const N_EMBD: usize = 32;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .join("..")
}

fn load_synthetic() -> LoadedModel {
    let gguf = repo_root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf");
    assert!(
        gguf.exists(),
        "synthetic GGUF missing at {} (run build_synthetic.py)",
        gguf.display()
    );
    load(LoadRequest {
        path: gguf,
        context_length: 512,
        gpu_layers: None,
        backend: BackendKind::Cpu,
        mmap: true,
    })
    .expect("synthetic model loads")
}

fn all_components_spec() -> CaptureSpec {
    CaptureSpec {
        layers: None,
        positions: Positions::All,
        components: vec![Component::Residual, Component::AttnOut, Component::MlpOut],
    }
}

fn plan(spill: bool, budget_bytes: u64, path: &str) -> SpillPlan {
    SpillPlan {
        spill,
        budget_bytes,
        spill_path: path.to_string(),
        model: "synthetic".to_string(),
        trace_id: "test-trace".to_string(),
        spec_key: "all/all/residual+attn_out+mlp_out".to_string(),
    }
}

fn tmp_spill_path(tag: &str) -> String {
    let mut p = std::env::temp_dir();
    p.push(format!("rebirth-spill-{tag}-{}.arrow", std::process::id()));
    p.to_string_lossy().to_string()
}

#[test]
fn over_budget_without_spill_is_oom_before_capture() {
    let model = load_synthetic();
    let path = tmp_spill_path("oom");
    // estimate = f32 bytes x the materialized-object expansion factor (D-017):
    // (8 pos x 2 layers x 3 comps x 32 embd x 4) x TRACE_MATERIALIZED_EXPANSION,
    // well over the 1 KB budget. The reported estimate is the materialized cost the
    // user would pay, not the f32 host bytes (the H-1 fix).
    let out = model.trace_token_batch_spill(
        &[&INPUT_TOKENS],
        &all_components_spec(),
        &plan(false, 1024, &path),
    );
    match out {
        Err(rebirth_llm::RebirthError::Oom {
            estimate_bytes,
            budget_bytes,
            ..
        }) => {
            assert_eq!(budget_bytes, 1024);
            assert_eq!(
                estimate_bytes,
                8 * 2 * 3 * N_EMBD as u64 * 4 * rebirth_llm::TRACE_MATERIALIZED_EXPANSION
            );
        }
        other => panic!("expected Oom, got {other:?}"),
    }
    // No file is created on the OOM path.
    assert!(!std::path::Path::new(&path).exists(), "OOM must not spill");
}

#[test]
fn in_budget_captures_in_memory() {
    let model = load_synthetic();
    let path = tmp_spill_path("mem");
    // A generous budget keeps it in memory (no file written).
    let out = model
        .trace_token_batch_spill(
            &[&INPUT_TOKENS],
            &all_components_spec(),
            &plan(true, 1 << 30, &path),
        )
        .expect("in-memory capture");
    match out {
        TraceOutput::Memory { rows, .. } => {
            assert_eq!(rows.len(), 48, "2 layers x 3 comps x 8 tokens");
        }
        TraceOutput::Spilled(_) => panic!("a generous budget must stay in memory"),
    }
    assert!(
        !std::path::Path::new(&path).exists(),
        "in-budget must not spill"
    );
}

#[test]
fn explicit_positions_recycled_across_differing_lengths_is_reported() {
    // REV-2 / API-GRAMMAR §4: an explicit positions vector recycled across prompts
    // of differing lengths, where a position is out of range for a shorter prompt,
    // is reported on the TraceOutput so the R boundary can warn once.
    let model = load_synthetic();
    let spec = CaptureSpec {
        layers: Some(vec![0]),
        // pos 7 (0-based) is valid for the 8-token prompt, out of range for a 3-token one.
        positions: Positions::Explicit(vec![0, 7]),
        components: vec![Component::Residual],
    };
    let short: [i32; 3] = [INPUT_TOKENS[0], INPUT_TOKENS[1], INPUT_TOKENS[2]];

    // Differing lengths with a dropped position -> reported (a generous budget keeps
    // it in memory, so no file is written).
    let out = model
        .trace_token_batch_spill(
            &[&INPUT_TOKENS, &short],
            &spec,
            &plan(true, 1 << 30, &tmp_spill_path("recycled")),
        )
        .expect("in-memory capture");
    match out {
        TraceOutput::Memory {
            positions_recycled, ..
        } => assert!(
            positions_recycled,
            "pos 7 is out of range for the 3-token prompt -> recycling reported"
        ),
        TraceOutput::Spilled(_) => panic!("a generous budget must stay in memory"),
    }

    // Same explicit vector, all prompts long enough -> not reported.
    let out2 = model
        .trace_token_batch_spill(
            &[&INPUT_TOKENS, &INPUT_TOKENS],
            &spec,
            &plan(true, 1 << 30, &tmp_spill_path("norecycle")),
        )
        .expect("in-memory capture");
    match out2 {
        TraceOutput::Memory {
            positions_recycled, ..
        } => assert!(
            !positions_recycled,
            "all positions in range for both prompts -> not reported"
        ),
        TraceOutput::Spilled(_) => panic!("a generous budget must stay in memory"),
    }
}

#[test]
fn over_budget_spills_and_the_file_equals_the_in_memory_capture() {
    let model = load_synthetic();
    let spec = all_components_spec();

    // Ground truth: the exact same capture, in memory.
    let mem = model
        .activations(&INPUT_TOKENS, &spec)
        .expect("in-memory capture");
    // Key each in-memory (layer, component, token, neuron) -> value.
    let mut truth: HashMap<(u32, String, u32, u32), f32> = HashMap::new();
    for row in &mem {
        for (k, &v) in row.values.iter().enumerate() {
            truth.insert(
                (
                    row.layer,
                    row.component.as_str().to_string(),
                    row.token_pos,
                    k as u32,
                ),
                v,
            );
        }
    }

    // Force spill with a tiny budget.
    let path = tmp_spill_path("roundtrip");
    let out = model
        .trace_token_batch_spill(&[&INPUT_TOKENS], &spec, &plan(true, 1024, &path))
        .expect("spill capture");
    let report = match out {
        TraceOutput::Spilled(report) => report,
        TraceOutput::Memory { .. } => panic!("a tiny budget must spill"),
    };
    assert_eq!(report.n_rows, 48 * N_EMBD as u64, "long-format rows");
    assert_eq!(report.n_positions, 8);
    assert_eq!(report.layers, vec![0, 1]);
    assert_eq!(report.positions, (0..8).collect::<Vec<u32>>());
    assert_eq!(report.components.len(), 3);
    assert!(std::path::Path::new(&path).exists(), "spill file exists");

    // Read the Arrow-IPC stream back and assert every value equals in-memory.
    let file = std::fs::File::open(&path).expect("open spill file");
    let reader = StreamReader::try_new(file, None).expect("arrow stream reader");
    let mut seen = 0usize;
    for batch in reader {
        let batch = batch.expect("read batch");
        let token_pos = col_u32(&batch, "token_pos");
        let layer = col_u32(&batch, "layer");
        let component = col_str(&batch, "component");
        let neuron = col_u32(&batch, "neuron");
        let value = col_f32(&batch, "value");
        for i in 0..batch.num_rows() {
            let key = (
                layer.value(i),
                component.value(i).to_string(),
                token_pos.value(i),
                neuron.value(i),
            );
            let expected = truth
                .get(&key)
                .unwrap_or_else(|| panic!("spilled row {key:?} not in the in-memory capture"));
            assert_eq!(value.value(i), *expected, "value mismatch at {key:?}");
            seen += 1;
        }
    }
    assert_eq!(seen as u64, report.n_rows, "read back every written row");
    let _ = std::fs::remove_file(&path);
}

fn col_u32<'a>(batch: &'a arrow_array::RecordBatch, name: &str) -> &'a UInt32Array {
    batch
        .column_by_name(name)
        .unwrap()
        .as_any()
        .downcast_ref::<UInt32Array>()
        .unwrap()
}

fn col_f32<'a>(batch: &'a arrow_array::RecordBatch, name: &str) -> &'a Float32Array {
    batch
        .column_by_name(name)
        .unwrap()
        .as_any()
        .downcast_ref::<Float32Array>()
        .unwrap()
}

fn col_str<'a>(batch: &'a arrow_array::RecordBatch, name: &str) -> &'a StringArray {
    batch
        .column_by_name(name)
        .unwrap()
        .as_any()
        .downcast_ref::<StringArray>()
        .unwrap()
}
