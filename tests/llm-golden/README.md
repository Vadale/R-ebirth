# tests/llm-golden/

Harness B goldens — the project's numerical crown jewel:

- **logit goldens** vs an unpatched reference `llama.cpp` at the vendored tag;
- **activation goldens** vs PyTorch / TransformerLens fp32 references;
- the in-repo **synthetic 2-layer GGUF** for exact-value tests with no download.

Built in **WP6a** (first slice: structure, Python fixtures, synthetic model,
logit goldens in CI) and **WP6b** (activation goldens, nightly tolerance suite,
mutation test). Regeneration is governed **solely** by the `golden-update`
skill — never hand-edit goldens.

Empty until WP6a.
