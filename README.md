# R-ebirth

**R-ebirth** aims to make R a first-class environment for scientific research on
data and AI — mechanistic interpretability ("AI neuroscience"), machine learning
including topic modelling, and the life sciences — while staying simple for
researchers.

It is delivered as **`rebirth`**: an R package with a Rust native core that
embeds a patched `llama.cpp`, exposing local LLMs (loading, generation,
embeddings, activation tracing, steering, and ablation) as base-R-idiom functions
returning plain `data.frame`s and `matrix`es.

> **Using the package?** Install from [r-universe](https://vadale.r-universe.dev/rebirth)
> and start with the [package README](rebirth/README.md) — quickstart, examples,
> and the two worked demos. This page is the repository/developer overview.

## Status: v0.1.0 (text-only)

The first public release is here. `rebirth` loads local GGUF models and exposes,
as base-R objects:

- **`llm()`** model loading, **`llm_tokens()`** tokenization;
- **`llm_generate()`** text generation, **`llm_logits()`** next-token distributions;
- **`llm_embed()`** text embeddings;
- **`llm_trace()`** activation tracing, **`llm_steer()`** steering, **`llm_ablate()`**
  ablation — the mechanistic-interpretability core;
- **`llm_download()`** checksum-verified fetch of pinned models.

Every numerical feature is validated value-for-value against an independent
reference (harness B). Vision (image inputs) is the next release (v0.2.0); v0.1.0
is text-only. The full plan is in `ROADMAP.md`.

## Repository layout

```
rebirth/            the R package (R/, src/ + src/rust/ extendr crate, tests/, vignettes/)
rust/               Cargo workspace: rebirth-ffi (R <-> Rust boundary), rebirth-llm (engine)
rebirth/src/llama.cpp/   pinned, patched llama.cpp (vendored; see its VENDORING.md)
tests/llm-golden/   Harness B numerical goldens
tests/demos/        the two reference demos (anatomy lab; topics without Python)
```

## Planning documents (the single source of truth)

`CLAUDE.md`, `SOLO-PHASE-PLAN.md`, `ROADMAP.md`, `API-GRAMMAR.md`,
`ARCHITECTURE.md`, `DECISIONS.md`, and `THESIS-PLAN.md`. If anything else
disagrees with these files, the files win.

## Building from source (developers)

End users install prebuilt binaries from r-universe (no toolchain required).
Building from source requires R (>= 4.5), a C toolchain, a Rust toolchain
(`rustup`; the pinned channel is in `rust-toolchain.toml`), and CMake (>= 3.28)
for the vendored engine.

```sh
# native workspace
cd rust && cargo test && cargo clippy --all-targets -- -D warnings

# R package
R CMD build rebirth && R CMD check rebirth_0.1.0.tar.gz
```

## License

Dual-licensed **MIT OR Apache-2.0** — see [LICENSE.md](LICENSE.md). The vendored
`llama.cpp` is MIT (see `NOTICE`). The name is protected: modified redistributions
must rename (see [TRADEMARK.md](TRADEMARK.md)).
</content>
