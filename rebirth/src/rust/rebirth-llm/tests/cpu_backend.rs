//! F4: a CPU model must not select a GPU, even in a Metal-enabled build. Runs
//! download-free in the Rust CI job. This dedicated one-test executable owns the
//! process-global log callback, avoiding races with other engine tests. On macOS
//! it also runs with GPU access denied (e.g. the local execution sandbox).

use std::ffi::{c_char, c_int, c_void, CStr};
use std::path::PathBuf;
use std::sync::Mutex;

use rebirth_llm::{
    available_backends, load, BackendKind, CaptureSpec, Component, InterventionSpec, LoadRequest,
    Positions,
};

static LOG: Mutex<String> = Mutex::new(String::new());

extern "C" {
    // Same test-only declaration as llama.h b9726. No new production FFI surface.
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
        // SAFETY: NULL restores upstream stderr logging; no borrowed data remains.
        unsafe { llama_log_set(None, std::ptr::null_mut()) };
    }
}

#[test]
fn cpu_load_and_all_context_types_use_no_gpu_device() {
    // Initialize the library's one-time quiet logger before installing ours.
    let _ = available_backends();
    // SAFETY: the callback is static and its shared state lives for the process.
    unsafe { llama_log_set(Some(capture_log), std::ptr::null_mut()) };
    let _capture = LogCapture;
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../..")
        .join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf");
    let model = load(LoadRequest {
        path,
        context_length: 512,
        // CPU must ignore even an explicit nonzero GPU-layer request.
        gpu_layers: Some(99),
        backend: BackendKind::Cpu,
        mmap: true,
        projector: None,
    })
    .expect("CPU load must not require a usable GPU");
    assert_eq!(model.metadata().gpu_layers, 0);
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
    // Fail loud if the log capture ceases to observe the pinned upstream path.
    assert!(
        log.contains("CPU") && log.contains("compute buffer size"),
        "{log}"
    );
    assert!(
        !log.contains("llama_prepare_model_devices: using device"),
        "CPU model selected a GPU device:\n{log}"
    );
    assert!(
        !log.contains("ggml_metal_init"),
        "CPU initialized Metal:\n{log}"
    );
}
