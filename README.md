# R-ebirth

**R-ebirth** aims to make R a first-class environment for scientific research on
data and AI — mechanistic interpretability ("AI neuroscience"), machine learning
including topic modelling, and the life sciences — while staying simple for
researchers.

It is delivered as **`relm`**: an R package with a Rust native core that
embeds a patched `llama.cpp`, exposing local LLMs (loading, generation,
embeddings, activation tracing, steering, and ablation) as base-R-idiom functions
returning plain `data.frame`s and `matrix`es.

![relm topic map: eight clusters of scientific abstracts, each named by the model](rebirth/man/figures/topic-map.png)

*Topic modelling with no Python: `llm_embed()` → UMAP → HDBSCAN → the model names
each cluster. One of two runnable demos — see the [package README](rebirth/README.md).*

> **Using the package?** Start with the [package README](rebirth/README.md)
> (quickstart, examples, the worked demos) and
> [docs/getting-started.md](docs/getting-started.md) (install options — binaries
> or from source — a first run, and troubleshooting). This page is the
> repository/developer overview.

## Status: v0.2.0 — vision (text + image input), pending tag

v0.1.0 (text-only) shipped in July 2026; v0.2.0 adds **vision** — a
vision-language model loaded with its projector answers questions about
images and embeds them — and is release-prepared on `main`, pending the tag.
`relm` loads local GGUF models and exposes, as base-R objects:

- **`llm()`** model loading (now also with `projector =` for image input),
  **`llm_tokens()`** tokenization;
- **`llm_generate()`** text generation, **`llm_logits()`** next-token distributions;
- **`llm_embed()`** embeddings;
- **`llm_trace()`** activation tracing, **`llm_steer()`** steering, **`llm_ablate()`**
  ablation — the mechanistic-interpretability core;
- **`llm_download()`** checksum-verified fetch of pinned models.

v0.2.0 exports **no new function**: the same surface gains new arguments
(`llm(projector =)`, `llm_generate(images =)`, `llm_embed(images =)`), with
text-only behavior byte-identical to 0.1.0. Every numerical feature is
validated value-for-value against an independent reference (harness B).
Vision-tower interpretability (tracing or steering inside the image encoder)
is **not** part of this release. The full plan is in `ROADMAP.md`.

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
R CMD build rebirth && R CMD check relm_0.2.0.tar.gz
```

## License

Dual-licensed **MIT OR Apache-2.0** — see [LICENSE.md](LICENSE.md). The vendored
`llama.cpp` is MIT (see `NOTICE`). The name is protected: modified redistributions
must rename (see [TRADEMARK.md](TRADEMARK.md)).
</content>
