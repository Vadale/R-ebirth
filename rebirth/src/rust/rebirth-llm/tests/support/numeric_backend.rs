//! The same frozen oracle runs on CPU by default and on actual CUDA in WP13.
//! No silent CPU fallback is permitted in a CUDA-feature numerical run.
use rebirth_llm::{available_backends, BackendKind};

pub fn backend() -> BackendKind {
    let backend = if cfg!(feature = "cuda") {
        BackendKind::Cuda
    } else {
        BackendKind::Cpu
    };
    assert!(
        available_backends().contains(&backend),
        "required numerical backend {backend:?} unavailable"
    );
    backend
}
