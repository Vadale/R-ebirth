# Engine boundary regressions

D-059 retains llama.cpp b10828 and backports three bounded corrections. The
public API, JSON limits, floating-point arithmetic, model weights and frozen goldens
are unchanged. These controls need no model download.

| Mechanism | Reachability and correction | Evidence and limits |
|---|---|---|
| Grammar candidates | A model vocabulary token can encode a legal 2048-scalar JSON string using 24576 escape code points. Schema depth and token-count limits do not bound native recursion per code point. Replace candidate recursion with upstream iteration. | Source-derived native regression on a 2 MiB stack; actual `CompiledSchema` and native candidate filter in Rust tests. No malformed model loading or model-quality claim. |
| M-RoPE positions | Ordinary image preprocessing aligns dimensions to patch size times merge factor. GLM/Qwen metadata can configure the merge factor, while old loops always emit 2 x 2 positions. Use whole tiles and the actual factor. Paddle retains fixed factor 2 and gains the upstream alignment assertion. | 48 aligned coordinate cases plus 2 window remappings under ASan/UBSan. Factor 1 original source overflows. This is not acceptance of arbitrary projector models or malformed metadata generally. |
| Metal indices | Separate embedding and trace contexts can exceed 32767 tokens; source truncates the MoE token index to signed 16 bits. Matrix output offsets also used signed 32-bit products. Widen those six expressions as upstream. | 8 source-derived scalar arithmetic cases include 32767/32768 and large offsets, without huge allocations. The C++ host check is not an actual Metal kernel run; platform execution remains a separate limitation. |

Upstream corrections: [grammar PR 31153](https://github.com/ggml-org/llama.cpp/pull/31153),
[M-RoPE PR 31336](https://github.com/ggml-org/llama.cpp/pull/31336),
[Metal PR 30072](https://github.com/ggml-org/llama.cpp/pull/30072). The grammar
backport excludes unrelated parser-depth/common/server changes. No performance
claim is inferred from the upstream results.

## Commands and CI routes

`python3 tests/engine-boundaries/check.py --evidence <new-directory>` compiles
source-derived units with Clang ASan/UBSan. Source hashes, commands, outputs and
exit codes are retained. Linux Rust CI and the existing native Mac host job run
this control; failure cannot become a skipped success.

`cargo test --locked -p rebirth-llm` includes the real compiled-schema candidate
regression, alongside existing numerical/security/resource coverage. macOS R CI
compiles the Metal backend; shader compilation is not GPU execution evidence.

The founder authorized these corrections for the unsubmitted 0.6.2 candidate.
The previously prepared archive remains immutable; final preparation must use a
separate production archive checked from the complete accepted source. Passing
checks authorize the requested merge, not CRAN upload or a tag/release.
