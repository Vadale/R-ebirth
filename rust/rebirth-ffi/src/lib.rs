//! `rebirth-ffi` — the R <-> Rust boundary for R-ebirth.
//!
//! This crate is the ONLY place allowed to hold `unsafe`, SEXP marshalling,
//! 1-based -> 0-based index conversion, panic catching (`catch_unwind`), and
//! the mapping of `Result<T, RebirthError>` to classed R conditions
//! (ARCHITECTURE.md §2 and §4). WP0 status: placeholder — the extendr wiring
//! and the condition machinery arrive in WP1. For now it only proves the
//! workspace path dependency on `rebirth-llm` links and builds.

use rebirth_llm::engine_placeholder;

/// Placeholder boundary accessor, exercised only by the WP0 workspace build to
/// confirm the path dependency on `rebirth-llm` resolves.
pub fn boundary_placeholder() -> &'static str {
    engine_placeholder()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boundary_reaches_engine() {
        assert!(boundary_placeholder().contains("WP1"));
    }
}
