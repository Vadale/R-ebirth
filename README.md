# R-ebirth

**R-ebirth** aims to make R a first-class environment for scientific research on
data and AI — mechanistic interpretability ("AI neuroscience"), machine learning
including topic modelling, and the life sciences — while staying simple for
researchers.

It is delivered as **`rebirth`**: an R package with a Rust native core that
embeds a patched `llama.cpp`, exposing local LLMs (loading, generation,
embeddings, and — later — activation tracing, steering, and ablation) as
base-R-idiom functions returning plain `data.frame`s and `matrix`es.

## Status: early scaffold (WP0)

**No user-facing functionality exists yet.** This repository currently contains
only the project skeleton:

- the `rebirth/` R package, scaffolded with the extendr toolchain, which exports
  **nothing** (a function is added only once its `API-GRAMMAR.md` entry is
  approved — the spec-first rule);
- the `rust/` Cargo workspace with empty-but-compiling `rebirth-ffi` and
  `rebirth-llm` crates;
- dual MIT/Apache-2.0 licensing, a trademark policy, and CI.

What does **not** exist yet: model loading, generation, embeddings, tracing,
steering, ablation, the vendored `llama.cpp` engine, and any installable
release. Those arrive across the phases described in `ROADMAP.md`.

## Repository layout

```
rebirth/            the R package (R/, src/ + src/rust/ extendr crate, tests/)
rust/               Cargo workspace: rebirth-ffi (R <-> Rust boundary), rebirth-llm (engine)
vendor/             pinned, patched llama.cpp (added in WP1)
tests/llm-golden/   Harness B numerical goldens (added in WP6a)
tests/demos/        the two reference demos (added in WP7)
docs/               pkgdown site / vignettes (added in WP8)
```

## Planning documents (the single source of truth)

`CLAUDE.md`, `SOLO-PHASE-PLAN.md`, `ROADMAP.md`, `API-GRAMMAR.md`,
`ARCHITECTURE.md`, `DECISIONS.md`, and `THESIS-PLAN.md`. If anything else
disagrees with these files, the files win.

## Building from source (developers)

Requires R (>= 4.5), a C toolchain, and a Rust toolchain (`rustup`; the pinned
channel is in `rust-toolchain.toml`). CMake (>= 3.28) is additionally required
from WP1 onward for the vendored engine.

```sh
# native workspace
cd rust && cargo test && cargo clippy --all-targets -- -D warnings

# R package
R CMD build rebirth && R CMD check rebirth_0.0.0.9000.tar.gz
```

End users will eventually install prebuilt binaries from r-universe (no Rust
toolchain required); that path opens at the first release (WP8).

## License

Dual-licensed **MIT OR Apache-2.0** — see [LICENSE.md](LICENSE.md). The name is
protected: modified redistributions must rename (see [TRADEMARK.md](TRADEMARK.md)).
