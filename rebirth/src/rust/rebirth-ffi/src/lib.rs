//! `rebirth` — the native boundary of the R package (extendr).
//!
//! WP0: nothing is exported yet — the API-GRAMMAR gate applies from the first
//! commit, so this module is intentionally empty. The real FFI surface (model
//! loading, generation, embeddings, activation tracing, steering, ablation)
//! lands from WP1 onward and is built on the `rebirth-ffi` / `rebirth-llm`
//! workspace crates under `rust/`.

// Macro to generate exports; it registers the (currently empty) set of exported
// functions with R. See the corresponding C code in `entrypoint.c`.
extendr_api::extendr_module! {
    mod rebirth;
}
