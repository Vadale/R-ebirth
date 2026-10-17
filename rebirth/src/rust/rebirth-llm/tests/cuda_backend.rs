//! Actual CUDA placement for all context kinds; one isolated logger-owning test.
#![cfg(feature = "cuda")]

use std::ffi::{c_char, c_int, c_void, CStr};
use std::path::PathBuf;
use std::sync::Mutex;

use rebirth_llm::{
    available_backends, load, BackendKind, CaptureSpec, Component, InterventionSpec, LoadRequest,
    Positions,
};

static LOG: Mutex<String> = Mutex::new(String::new());

extern "C" {
    // Same test-only declaration as llama.h b10828. No new production FFI surface.
    fn llama_log_set(
        callback: Option<extern "C" fn(c_int, *const c_char, *mut c_void)>,
        user_data: *mut c_void,
    );
}

extern "C" fn capture_log(_level: c_int, text: *const c_char, _data: *mut c_void) {
    if text.is_null() {
        return;
    }
    // SAFETY: llama.cpp lends a NUL-terminated string for the callback duration.
    let message = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    if let Ok(mut log) = LOG.lock() {
        log.push_str(&message);
    }
}

struct LogCapture;

impl Drop for LogCapture {
    fn drop(&mut self) {
        // Retain placement diagnostics even when an assertion unwinds the test.
        let log = LOG.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        eprintln!("CUDA_PLACEMENT_LOG_BEGIN\n{log}CUDA_PLACEMENT_LOG_END");
        // SAFETY: NULL restores upstream stderr logging; no borrowed data remains.
        unsafe { llama_log_set(None, std::ptr::null_mut()) };
    }
}

#[test]
fn cuda_load_and_all_context_types_use_device_buffers() {
    // Initialize the library's one-time quiet logger before installing ours.
    assert!(available_backends().contains(&BackendKind::Cuda));
    // SAFETY: the callback is static and its shared state lives for the process.
    unsafe { llama_log_set(Some(capture_log), std::ptr::null_mut()) };
    let _capture = LogCapture;
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../..")
        .join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf");
    let model = load(LoadRequest {
        path,
        context_length: 512,
        // All three layers (two blocks plus output) must really be offloaded.
        gpu_layers: None,
        backend: BackendKind::Cuda,
        mmap: true,
        projector: None,
    })
    .expect("CUDA load must use the real device");
    // Metadata retains the request sentinel; actual placement is checked below.
    assert_eq!(model.metadata().gpu_layers, -1);
    let ids = [1, 7, 13, 22];
    model.logits_for_tokens(&ids).expect("generation context");
    model.token_embeddings(&ids).expect("embedding context");
    model
        .activations(
            &ids,
            &CaptureSpec {
                layers: None,
                positions: Positions::All,
                components: vec![Component::Residual],
            },
        )
        .expect("trace context");
    let derived = model
        .derive_with_interventions(&InterventionSpec::new(32, 2))
        .expect("derived context");
    derived.logits_for_tokens(&ids).expect("derived decode");
    drop(derived);
    drop(model);

    let log = LOG.lock().expect("capture engine log");
    for receipt in [
        "offloaded 3/3 layers",
        "CUDA0 model buffer size",
        "CUDA0 KV buffer size",
        "CUDA0 compute buffer size",
    ] {
        assert!(
            log.lines().any(|line| line
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .contains(receipt)),
            "missing {receipt}:\n{log}"
        );
    }
    eprintln!("CUDA_PLACEMENT_PASS loads=1 derives=1 contexts=generation,embedding,trace,derived");
}
