//! `rebirth-llm` — the safe inference-engine wrapper for R-ebirth.
//!
//! This crate wraps the vendored llama.cpp engine (built by `build.rs`, D-006)
//! behind safe Rust APIs. It must never contain R types: staying R-free is what
//! keeps it independently testable with `cargo test` and reusable under a
//! permissive licence (ARCHITECTURE.md §2, §13).
//!
//! WP1 Steps 1–2 wire the engine and prove it links: the backend can initialize
//! and report build/system info with no model file. The model/context lifecycle
//! (loading, metadata, generation) and its `RebirthError` type arrive in the
//! later WP1 steps; the engine FFI declared here grows with them.

use std::ffi::CStr;

/// Hand-written FFI to the vendored llama.cpp C API at the pinned tag (`b9726`).
///
/// No bindgen (DECISIONS.md D-006): the surface is small and reviewed by hand
/// against `src/llama.cpp/include/llama.h` at this exact tag. This module is the
/// only place `rebirth-llm` touches the C engine; every safe wrapper below is the
/// sole caller of its declaration, so the linker verifies each symbol name.
mod ffi {
    use std::os::raw::c_char;

    extern "C" {
        /// Initialize the llama + ggml backend. Call once before other engine use.
        pub fn llama_backend_init();
        /// Tear down the backend. Call once at process end.
        pub fn llama_backend_free();
        /// Static, NUL-terminated string of enabled backends / CPU features.
        pub fn llama_print_system_info() -> *const c_char;
        /// Whether this build can offload compute to a GPU backend.
        pub fn llama_supports_gpu_offload() -> bool;
        /// Whether this build supports memory-mapping model files.
        pub fn llama_supports_mmap() -> bool;
        /// Whether this build supports locking model pages in RAM.
        pub fn llama_supports_mlock() -> bool;
        /// Maximum number of devices this build can address.
        pub fn llama_max_devices() -> usize;
    }
}

/// Initialize the process-global llama.cpp + ggml backend.
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
