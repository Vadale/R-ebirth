//! D-037 native handoff/numerical gates. Rust PR job, debug + release, CPU-only,
//! download-free. Scheduler fixtures run first; these exercise actual native
//! ownership. A no-vocab model cannot prove text/chat/vision generation.

use rebirth_llm::{
    load_with_batch, AsyncCompletion, BackendKind, ExecutionPermit, GenerateParams, LoadRequest,
    LoadedModel, RebirthError,
};
use std::path::PathBuf;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../..")
}
fn model() -> LoadedModel {
    load_with_batch(
        LoadRequest {
            path: root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf"),
            context_length: 64,
            gpu_layers: None,
            backend: BackendKind::Cpu,
            mmap: true,
            projector: None,
        },
        Some(1),
    )
    .expect("synthetic model loads")
}
fn params(temperature: f32) -> GenerateParams {
    GenerateParams {
        max_tokens: 16,
        temperature,
        top_p: 0.95,
        seed: 42,
        stop: vec![],
    }
}
#[test]
fn async_synthetic_owned_handoff_preserves_golden_and_sampling() {
    let mut model = model();
    let golden: Vec<i32> = std::fs::read_to_string(
        root().join("tests/llm-golden/synthetic/goldens/greedy_continuation.csv"),
    )
    .unwrap()
    .lines()
    .skip(1)
    .map(|line| line.split(',').nth(1).unwrap().trim().parse().unwrap())
    .collect();
    for temperature in [0.0, 0.8] {
        let params = params(temperature);
        // Two tokens exceed n_batch=1: real shared chunked ingest is exercised.
        let expected = model.generate(&[1, 7], &params).unwrap();
        if temperature == 0.0 {
            assert_eq!(expected.tokens, golden);
        }
        let metadata = model.metadata();
        let permit = ExecutionPermit::try_acquire("numeric handoff").unwrap();
        let mut completed = std::thread::spawn(move || {
            // Completion owns both before any assertion/native call. Its Drop
            // rebinds the reservation even if a regression panics this test.
            let mut completed = AsyncCompletion {
                model: Some(model),
                permit,
                panicked: false,
                model_invalidated: false,
                result: Err(RebirthError::Internal {
                    context: "test unfinished".into(),
                }),
            };
            {
                let _bound = completed.permit.enter();
                completed.result = completed
                    .model
                    .as_ref()
                    .unwrap()
                    .generate(&[1, 7], &params)
                    .map(|generation| vec![generation]);
            }
            completed
        })
        .join()
        .unwrap();
        assert_eq!(completed.result.as_ref().unwrap(), &vec![expected]);
        {
            let _bound = completed.permit.enter();
            assert_eq!(completed.model.as_ref().unwrap().metadata(), metadata);
            model = completed.model.take().unwrap();
        }
        drop(completed);
    }
}
