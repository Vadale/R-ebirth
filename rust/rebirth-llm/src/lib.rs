//! `rebirth-llm` — the safe inference-engine wrapper for R-ebirth.
//!
//! WP0 status: placeholder. The vendored, patched llama.cpp engine and the
//! model/context lifecycle (loading, generation, embeddings, tap orchestration,
//! spill writer) arrive in WP1 and later. This crate must never contain R
//! types: keeping it R-free is what makes it independently testable with
//! `cargo test` and reusable under a permissive licence (ARCHITECTURE.md §2).

/// Placeholder marker until the engine lands in WP1.
///
/// Exists only so the workspace has something to build and test before any
/// real engine code is written.
pub fn engine_placeholder() -> &'static str {
    "rebirth-llm: engine not yet wired (arrives in WP1)"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_mentions_wp1() {
        assert!(engine_placeholder().contains("WP1"));
    }
}
