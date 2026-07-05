//! `rebirth-llm` — the safe inference-engine wrapper for R-ebirth.
//!
//! This crate wraps the vendored llama.cpp engine (built by `build.rs`, D-006)
//! behind safe Rust APIs. It must never contain R types: staying R-free is what
//! keeps it independently testable with `cargo test` and reusable under a
//! permissive licence (ARCHITECTURE.md §2, §13).
//!
//! Layout:
//! - [`ffi`] — the hand-written `extern "C"` surface + `#[repr(C)]` param structs.
//! - [`error`] — [`RebirthError`], mirroring `API-GRAMMAR.md` §6.
//! - [`engine`] — the safe `Backend`/`Model`/`Context` lifecycle and [`load`].

use std::ffi::CStr;

mod engine;
mod error;
mod ffi;
mod generate;

pub use engine::{available_backends, load, BackendKind, LoadRequest, LoadedModel, ModelMetadata};
pub use error::RebirthError;
pub use generate::{Encoding, GenerateParams, Generation, Logits, StopReason};

/// Initialize the process-global llama.cpp + ggml backend.
///
/// Low-level: prefer [`engine::available_backends`] / [`load`], which manage a
/// reference-counted backend for you. Pairs with [`backend_free`].
pub fn backend_init() {
    // SAFETY: takes no arguments; only sets up global engine state.
    unsafe { ffi::llama_backend_init() }
}

/// Free the process-global backend. Pairs with [`backend_init`].
pub fn backend_free() {
    // SAFETY: takes no arguments; only tears down global engine state.
    unsafe { ffi::llama_backend_free() }
}

/// Engine build/system info: which backends and CPU features are compiled in.
///
/// Returns an owned copy of the engine's static string (empty if unavailable).
pub fn system_info() -> String {
    // SAFETY: llama_print_system_info returns a pointer to a static, NUL-
    // terminated C string owned by the engine; we only read and copy it.
    let ptr = unsafe { ffi::llama_print_system_info() };
    if ptr.is_null() {
        return String::new();
    }
    // SAFETY: `ptr` is non-null and points at a NUL-terminated engine string.
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

/// Whether this build can offload compute to a GPU backend (e.g. Metal).
pub fn supports_gpu_offload() -> bool {
    // SAFETY: takes no arguments; pure query into the ggml backend registry.
    unsafe { ffi::llama_supports_gpu_offload() }
}

/// Whether this build supports memory-mapping model files.
pub fn supports_mmap() -> bool {
    // SAFETY: takes no arguments; pure capability query.
    unsafe { ffi::llama_supports_mmap() }
}

/// Whether this build supports locking model pages in RAM.
pub fn supports_mlock() -> bool {
    // SAFETY: takes no arguments; pure capability query.
    unsafe { ffi::llama_supports_mlock() }
}

/// Maximum number of devices this build can address.
pub fn max_devices() -> usize {
    // SAFETY: takes no arguments; pure capability query.
    unsafe { ffi::llama_max_devices() }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Linkage gate (WP1 Step 2): proves the vendored engine compiles, links, and
    /// the backend initializes with NO model file — catching any C-API
    /// symbol-name mismatch at the pinned tag. A single test keeps the
    /// process-global `llama_backend_init`/`llama_backend_free` calls serial.
    #[test]
    fn backend_initializes_and_reports_system_info() {
        backend_init();

        let info = system_info();
        assert!(!info.is_empty(), "engine system info should be populated");

        // Capability queries are callable with no model loaded.
        let _ = supports_mmap();
        let _ = supports_mlock();
        let _ = max_devices();

        // On the macOS arm64 Metal build, GPU offload must be available.
        if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            assert!(
                supports_gpu_offload(),
                "Metal build should report GPU offload support; system info: {info}"
            );
        }

        backend_free();
    }
}
