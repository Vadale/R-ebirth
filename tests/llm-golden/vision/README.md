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
goldens/greedy-red-square.txt      the reference continuation, byte-exact, no
                                   trailing newline (18 bytes: "The square is red.")
goldens/greedy-red-square-ids.txt  the ENGINE token ids for the same greedy run
                                   (engine-vs-engine secondary pin, WP-V4; the
                                   text leg above stays the upstream-reference
                                   primary gate)
goldens/embed-red-square-mean.csv  the T2 pooled-embedding REGRESSION PIN
                                   (1536 values, %.8e, one per line) — see the
                                   "T2 pooled-embedding pin" section for what
                                   this is and, honestly, what it is not
goldens/encode-red-square-f32.txt  the BINDING embd-ATOL leg's reference: the
                                   raw image-encoder output from the UNPATCHED
                                   upstream b9726 build (line 1 = "n_tokens
                                   n_embd", then one %.8e float per line,
                                   token-major; 64 x 1536 for the pinned pair)
tools/dump-encode.c                the reference harness that produced it —
                                   upstream C API only, built against the
                                   pristine tarball, never the vendored tree
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
Apache-2.0; SHA256 observed at download on 2026-07-14). WP-V4 pinned these same
two files fail-closed in `rebirth/inst/models.csv` (aliases
`qwen2-vl-2b-instruct-q4_k_m` + `qwen2-vl-2b-instruct-mmproj-f16`), at the
immutable revision `bb307c036e8a1ed7b663bbd0c35b41c4c9294cfd` rather than
`main`, so the reference run above and `llm_download()` fetch identical bytes:

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
  is a `[MODEL]`/nightly gate, never per-commit CI (D-026 point 6). It runs in
  `.github/workflows/nightly-vision-golden.yaml`, which asserts this test
  actually ran rather than skipped.

## The T2 pooled-embedding pin (WP-V3) — what it is and what it is not

`goldens/embed-red-square-mean.csv` pins the `llm_embed(images=)` pooled
vector for a fixed input. **It is a same-implementation determinism /
regression pin, NOT an independent oracle** — stated per the golden-update
honesty rule, because no independent reference for this object exists at the
pinned tag:

- the upstream `llama-mtmd-cli` emits **no embeddings** at b9726;
- the upstream server's `/embeddings` accepts multimodal input but computes
  its pooled value **in-graph per ubatch**, i.e. over the final decoded
  segment only (server-context.cpp L1995-2035 + the chunked mtmd decode) — a
  different object from relm's all-text-rows pooling, so a numeric comparison
  would be comparing definitions, not implementations.

What anchors T2 numerically instead (the decomposition argument): the image
encode+decode path is gated by the WP-V2 **byte-exact generation golden**
(same clip encode, same helper decode); the per-token rows and every pooling
reduction are gated by the WP3 **synthetic numpy-oracle goldens** (exact);
new in T2 is only their composition, which this pin freezes against
regression. The cross-build `mtmd_get_output_embd` ATOL leg — the BINDING
WP-V4 item (D-026 first addendum) — extends nightly coverage to the encoder
output itself; it is delivered, and documented in the section below.

**Running it (D-026 fourth addendum).** The pin holds bit-for-bit only on the
machine that recorded it, so it skips unless you say you are on that machine:

```sh
RELM_VISION_RECORDING_MACHINE=1 Rscript -e 'devtools::test(filter = "vision")'
```

"Other ISAs may differ in the last decimals" — the original wording here — turned
out to understate it by two orders of magnitude: a *non-M4 arm64* runner (same
OS, same arch) measured `max |d| = 6.05e-3` against this pin, 600× the tolerance,
while the byte-exact text golden passed in the same run. The old
`Darwin && arm64` gate was therefore never right: it named a platform where a
**machine** was meant. Unlike the encoder leg, this pin cannot be regenerated on
another machine — no upstream reference exists for a pooled multimodal embedding
at b9726 (D-026 second addendum), so there is nothing to regenerate *from*. The
nightly's T2 coverage is the cat-vs-car semantic gate instead, which holds
anywhere.

Reproduction (macOS arm64, CPU backend — the values are deterministic on the
recording machine; see above for what "other platforms" really costs):

```r
m <- llm("Qwen2-VL-2B-Instruct-Q4_K_M.gguf",
         projector = "mmproj-Qwen2-VL-2B-Instruct-f16.gguf", backend = "cpu")
e <- llm_embed(m, "What color is the square?",
               images = "tests/vision/red-square.png",
               pooling = "mean", normalize = TRUE)
writeLines(sprintf("%.8e", e[1, ]), "embed-red-square-mean.csv")
```

Recorded 2026-07-14: relm WP-V3 branch, macOS 26.5.2 arm64, the same model
artifacts (SHA256s above); vector L2-norm = 1 (normalized), 1536 dims.

## The BINDING embd-ATOL leg (WP-V4, D-026 first addendum — DELIVERED)

`goldens/encode-red-square-f32.txt` is an **unpatched-upstream reference** for
the raw image-encoder output (`mtmd_encode_chunk` → `mtmd_get_output_embd`) of
the committed red-square image under the pinned projector — the one recorded on
the founder's M4.

**It is not the only reference, and it is not the one the nightly uses**
(D-026 fourth addendum). A float reference belongs to the machine that produced
it: this file is bit-exact on the M4 and *cannot* pass anywhere else, because
the same pristine upstream build disagrees with its own arm64 self by up to
`8.71` across ISAs — and by different amounts on different runners of the same
label. So the nightly rebuilds the pristine b9726 tarball on its own runner,
produces the reference *there*, and points `RELM_VISION_ENCODER_REFERENCE` at
it. The gate then stays **exact everywhere**, with no tolerance to tune:

```
relm vs upstream, SAME machine  ->  max |d| = 0.0   (M4 and x86_64 alike)
```

This committed file remains the fast path on the recording machine — no
12-minute pristine build for a local check — and the honest, loud failure
anywhere else.

Reproduction, exactly as run on 2026-07-15 (macOS 26.5.2 arm64,
Apple clang 21.0.0; `$REF` = the pristine b9726 tree extracted from the
SHA-verified tarball and built CPU-only with the same cmake line as the
mtmd-cli section above). The nightly runs these same two commands on its runner:

```sh
cc -O2 -o dump-encode tests/llm-golden/vision/tools/dump-encode.c \
   -I$REF/include -I$REF/ggml/include -I$REF/tools/mtmd \
   -L$REF/build/bin -lmtmd -lllama -lggml -Wl,-rpath,$REF/build/bin
./dump-encode Qwen2-VL-2B-Instruct-Q4_K_M.gguf \
              mmproj-Qwen2-VL-2B-Instruct-f16.gguf \
              tests/vision/red-square.png \
              tests/llm-golden/vision/goldens/encode-red-square-f32.txt
```

The engine gate is the `[MODEL]` cargo test
`rebirth-llm/tests/vlm_golden.rs::encoder_output_matches_the_unpatched_reference_within_atol`
(CPU backend): every one of the 64 x 1536 values within **ATOL 1e-3**.
Observed at delivery: **max |Δ| = 0.0 exactly** (same code, same CPU backend;
`%.8e` round-trips f32 exactly) — the full 1e-3 tolerance is headroom for
future cross-machine/threading variation, per D-018 same-implementation
logic.

## The T1 token-ids pin (WP-V4)

`goldens/greedy-red-square-ids.txt` records the ENGINE's greedy token ids for
the T1 golden run (5 ids for "The square is red." + EOG handling) as an
engine-vs-engine secondary pin; the byte-exact TEXT leg vs the upstream CLI
remains the primary gate. Gate + sanctioned regeneration seam:
`rebirth-llm/tests/vlm_golden.rs::greedy_generation_reproduces_the_committed_token_ids`
(regenerate deliberately with `RELM_UPDATE_VISION_IDS=1`, then commit with
the stated reason — the golden-update discipline).
