# tests/llm-golden/vision/ — the harness-B vision golden category (WP-V2, D-026)

The **same-implementation leg** for T1 (`llm(projector=)` + `llm_generate(images=)`,
D-026 point 6): the reference is the **unpatched upstream `llama-mtmd-cli` at the
pinned tag b9726**, built CPU-only, run greedy on the committed test image. The
engine (CPU backend, for comparability with the CPU-only reference build) must
reproduce the reference continuation **exactly**. No HF cross-check exists for T1
(that would be a vision-tower check — T3, out of scope, D-026).

Regeneration is governed solely by the `golden-update` skill
(`.claude/skills/golden-update/SKILL.md`). Reason for this golden's creation
(2026-07-14): the T1 vision feature is new and merges golden-first (Hard rule 4);
no vision golden existed before WP-V2.

## Files

```
goldens/greedy-red-square.txt   the reference continuation, byte-exact, no
                                trailing newline (18 bytes: "The square is red.")
```

## The reference run (exact reproduction)

Reference build — the **pristine upstream b9726 tarball** (SHA256
`117e95a59967e91b097d1bfdf62c3d10e8d08aec01be8548a093dcceecf9f2e0`, the same pin
as `rebirth/src/llama.cpp/VENDORING.md`), extracted OUTSIDE the repository and
configured CPU-only with the tools enabled:

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_OPENMP=OFF \
      -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_COMMON=ON \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF
cmake --build build --target llama-mtmd-cli -j 4
```

Reference command (greedy, temperature 0; the image is the committed
`tests/vision/red-square.png`, SHA256
`0f0791f704392f0ad330857b782c65ae8369b9d44d98e6fe2b6d1eb58c914db4`):

```sh
./build/bin/llama-mtmd-cli \
  -m Qwen2-VL-2B-Instruct-Q4_K_M.gguf \
  --mmproj mmproj-Qwen2-VL-2B-Instruct-f16.gguf \
  --image tests/vision/red-square.png \
  -p "What color is the square?" --temp 0 -n 32
```

Model artifacts (from `https://huggingface.co/ggml-org/Qwen2-VL-2B-Instruct-GGUF`,
branch `main`, Apache-2.0; SHA256 observed at download on 2026-07-14 — the
fail-closed registry pin is WP-V4):

```
5745685d2e607a82a0696c1118e56a2a1ae0901da450fd9cd4f161c6b62867d7  Qwen2-VL-2B-Instruct-Q4_K_M.gguf
ecb20cabcdd8dbc277de06bd6eb980aeb2adfaaba9f199a434e328d205675d03  mmproj-Qwen2-VL-2B-Instruct-f16.gguf
```

Tooling used for the recorded run (2026-07-14): macOS 26.5.2 (arm64), Apple
clang 21.0.0 (clang-2100.1.1.101), CMake 4.3.4. The reference stdout was
exactly the golden text (framed by the CLI's own blank log lines, which are not
generation output).

## Why the CLI and the engine are comparable prompt-for-prompt

Both sides build the identical token stream by construction, verified against
the b9726 sources:

- **Marker:** the CLI prepends `mtmd_default_marker()` to a prompt that carries
  none (`tools/mtmd/mtmd-cli.cpp` L437-441); the engine prepends one marker per
  image before the text (grammar: images-before-text).
- **Template:** the CLI formats a single user turn through the legacy
  (non-Jinja) common-chat path, which routes into the same
  `llama_chat_apply_template` detection the engine uses; Qwen2-VL's embedded
  template is detected as chatml on both sides, producing identical text.
- **BOS:** the CLI tokenizes with `add_special = true`, the engine with
  `add_special = false` (D-021: an embedded template carries its own BOS) —
  identical tokens for this model because Qwen2-VL's GGUF sets
  `add_bos_token = false`, so neither side adds one.
- **Decode:** both ingest through `mtmd_helper_eval_chunks`-equivalent code
  chunked by the same default `n_batch = 2048`, then sample greedy (argmax,
  first-max tie-break on both sides) on the same CPU kernels — bit-identical
  logits, hence identical tokens.

## What the golden gates (and what it does not)

- **Gate:** the engine's greedy continuation text on the CPU backend equals
  `goldens/greedy-red-square.txt` **byte-for-byte** (the `[MODEL]` test
  `test-llm-vision.R` — "the CPU greedy continuation matches the unpatched
  upstream reference"). With greedy sampling on identical CPU code, byte-exact
  text is the observable equivalent of a token-for-token match; the raw token
  ids are NOT recorded because the upstream CLI does not expose them — the
  strongest reproducible equality its output supports is exact text, stated
  honestly.
- **Not per-commit:** no synthetic in-repo vision model exists, so this golden
  is a `[MODEL]`/nightly gate, never per-commit CI (D-026 point 6). The nightly
  workflow wiring is WP-V4.
- **Deferred (BINDING at WP-V4):** the D-026 image-embedding tolerance leg
  (`mtmd_get_output_embd` vs the reference within ATOL 1e-3) is not part of
  this WP's golden — the T1 surface deliberately does not declare
  `mtmd_get_output_embd` (the helper path never needs it). Per the D-026
  addendum (founder-approved 2026-07-14) it lands with the WP-V4 nightly
  wiring as a **binding requirement**: the phase does not close and v0.2.0
  is not tagged without it.
