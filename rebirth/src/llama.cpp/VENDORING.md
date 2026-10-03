# Vendored llama.cpp — provenance and prune manifest

This directory is a **pinned, pruned** source snapshot of upstream
[llama.cpp](https://github.com/ggml-org/llama.cpp), vendored inside the package
per **DECISIONS.md D-006** so that `R CMD build`/`R CMD check` and CRAN/r-universe
builds are self-contained (no submodule, no build-time download). It is compiled
from `../rust/rebirth-llm/build.rs` via the `cmake` build-dependency.

## Pin

| Field | Value |
|---|---|
| Upstream | https://github.com/ggml-org/llama.cpp |
| Tag | `b10828` |
| Tag release date | 2026-09-06 |
| ggml version | 0.23.0 (per `ggml/CMakeLists.txt`) |
| Upstream release tarball | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/b10828.tar.gz` |
| Release tarball SHA256 | `da0a960b36505081df726d35552ae71e84c5b7da313d41d9c52055f0d85b0247` |
| Pruned tree SHA256 (pre-patch) | `fd1b8327ef675dc91de4b9fde547d8afb7d4c6b2aa63a8f989e421cf59edd7ac` |
| Pruned tree SHA256 (post-patch) | `68a7959e27e6e115fdac028aa65c097ce00cf32cc07116a9280ce563c6c78ceb` |

D-032 advances b9726 to b10828 (commit
`3ad1ba7336986d98592d3e28cafd1a406715351f`) for native Spark 2.5 support.
All three digests are new. Patch 0001 applies with offset-only changes; upstream
now provides the library-only mtmd build, so patch 0002 is retired.

The native port revalidates every mirrored C layout against a compiled header
oracle. New loading enums explicitly preserve relm's mmap/eager behavior;
context output limits and mtmd text lengths/options are mapped without new R API.
The Qwen2, Qwen2-VL, Llama and Gemma3 architecture files are unchanged from the
old tag; shared graph/loader/backend code changes, so their numerical gates still
apply. Gemma4 adds lazy-tensor metadata and non-causal SWA handling; relm keeps
lazy loading off. Spark uses the existing graph operations and `build_cvec` hook;
this bump does not broaden relm's validated trace-component allow-lists.

The **release tarball SHA256** is the digest of the unmodified upstream
`b10828.tar.gz` as downloaded from GitHub — verifiable by anyone against upstream.

The tree is committed with the **rebirth patch set applied** (DECISIONS.md
D-015). Three SHAs pin it (D-015 strengthening #1):

- **Pruned tree SHA256 (pre-patch)** — the pristine upstream tree after the prune
  below (provenance). Reverse-applying `patches/*.diff` to the committed tree must
  reproduce this (the coherence check).
- **Pruned tree SHA256 (post-patch)** — the digest of *this* committed tree (with
  the patches applied). **This is the value D-008 gate G4 asserts in CI.**

Both are reproducible digests of the tree, computed from the sorted per-file
SHA256 manifest, excluding this file and the `patches/` directory:

```sh
# run from this directory (rebirth/src/llama.cpp)
find . -type f -not -path './VENDORING.md' -not -path './patches/*' \
  | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256
```

`patches/verify_vendored_tree.sh` runs both assertions (G4 + coherence); CI wires
it as the `vendored-tree` job (`.github/workflows/rust.yaml`).

## Patches

The tree is committed **with the rebirth patch set applied** (DECISIONS.md D-015:
patches land in the committed tree, not at build time — `build.rs` compiles it
as-is, which is CRAN/`R CMD INSTALL`-robust and needs no diff-applier dependency).
`patches/` holds the human-readable, `vendor-bump`-reappliable delta.

| Patch | Files / hunks | Why | ADR |
|---|---|---|---|
| `0001-rebirth-wp5-ablation-intervene.diff` | 7 files, 14 hunks | `llm_ablate()`: a sibling `llama_adapter_intervene` applied inside `build_cvec` **after** the control vector (`cur * mask + add`, forcing masked neurons to `value`). No-op (no graph node) when no ablation is registered, so the un-intervened forward pass is byte-identical to the unpatched build. | D-012 / D-016 |
| `0003-ggml-graph-size-offsets.diff` | `ggml/src/ggml.c`, one function | Defined integer arithmetic for graph-storage sizing; real-buffer advancement and numerical operations unchanged. | D-039 |

The patches touch engine sources only; all CMake inputs are pristine upstream.
D-039 changes only the post-patch digest; the b10828 upstream and pre-patch
identities above are unchanged. It does not add general overflow handling for
arbitrary graph sizes. Its source-derived layout and native gates are separate
from the historical b10828 numerical acceptance below.

WP4 (activation observation) added **zero** patches (the eval-callback tap is
zero-patch, D-012); WP5's ablation hook above is the project's first vendored
patch. The ablation hook adds no graph nodes on an un-intervened path. At its
original b9726 introduction, the measured engine-vs-oracle maxima stayed at
logits 1.99e-3, embeddings 2.92e-3 and activations 3.73e-3. Those are historical
measurements, not evidence of cross-version bitwise equality. The b10828 port
passes the existing synthetic reference assertions without updating any golden;
same-version pristine/model comparison gates are recorded separately.

`vendor-bump`: fetch upstream b10828 → re-apply `patches/*.diff` → re-run harness B
→ re-record the pre- and post-patch SHAs above. Two integrity checks guard drift
(run by `patches/verify_vendored_tree.sh`, wired in CI):

- **G4 (D-008):** the committed tree's digest equals the post-patch SHA (a silent
  engine change fails CI).
- **Coherence (D-015 strengthening #2):** reverse-applying `patches/*.diff`
  reproduces the pre-patch SHA (the tree and the diff cannot silently diverge).

## Prune manifest

The snapshot keeps what a static CPU + Metal (with embedded shaders) build of
`libllama` + `ggml` + `libmtmd` (the multimodal library, WP-V1/D-026) needs.
"When unsure, keep" — the prune is conservative and still builds. Non-CPU/
non-Metal ggml backends return per-backend when their phase arrives (CUDA at
Phase 8).

### Kept (build inputs)

- `CMakeLists.txt` (root), `cmake/` (build-info, common, license, git-vars,
  toolchain files, `llama-config.cmake.in`, `llama.pc.in`).
- `include/` (`llama.h`, `llama-cpp.h`).
- `src/` — the `libllama` sources, including `src/models/`.
- `ggml/CMakeLists.txt`, `ggml/cmake/`, `ggml/include/` (all public headers).
- All non-directory core build inputs directly under `ggml/src/`, including
  `CMakeLists.txt`, `ggml-version.h.in`, the ggml/gguf core files and headers.
- `ggml/src/ggml-cpu/` (full, all `arch/` subdirs), `ggml/src/ggml-metal/`
  (including `ggml-metal.metal`), `ggml/src/ggml-blas/`.
- `tools/mtmd/` **library** inputs only (WP-V1, D-026): `clip.{cpp,h}`,
  `clip-impl.h`, `clip-model.h`, `clip-graph.h`, `mtmd.{cpp,h}`,
  `mtmd-image.{cpp,h}`, `mtmd-audio.{cpp,h}`, `mtmd-helper.{cpp,h}`,
  `models/*.cpp` + `models/models.h`, `debug/mtmd-debug.h` (the debug
  *functions* live in `mtmd.cpp`; only the header is a library input), and
  `CMakeLists.txt` (upstream library-only guards). New b10828 library inputs
  include `mtmd-internal.h`, `mtmd-helper-gen.cpp` and `mtmd-helper-common.h`. libmtmd links
  only `ggml` + `llama` — it is explicitly forbidden from linking
  `llama-common`, which is why `common/` stays pruned.
- `vendor/CMakeLists.txt`, `vendor/hash/` (the upstream SHA/xxHash library),
  `vendor/{hash,stb,miniaudio,nlohmann,sheredom}/CMakeLists.txt`,
  `vendor/stb/stb_image.h` (image decode) and `vendor/miniaudio/miniaudio.h`
  (compiled into `mtmd-helper.cpp` unchanged — audio Option A, D-026; the R API
  never reaches the audio decoder: the Rust image FFI gates input on an image
  magic-byte allow-list, WP-V2).
- `LICENSE` (llama.cpp MIT — required at configure time by `cmake/license.cmake`
  and reproduced in the repo-root `NOTICE`).

### Removed (not needed for the static CPU + Metal libraries)

- Top-level dirs: `examples/`, `tests/`, `models/`, `docs/`, `media/`,
  `scripts/`, `ci/`, `app/`, `benches/`, `pocs/`, `grammars/`, `conversion/`,
  `gguf-py/`, `requirements/`, `common/` (verified unneeded: libmtmd must not
  link `llama-common`), `licenses/`.
- `tools/` except the `tools/mtmd/` library inputs above: `tools/mtmd/{tests/,
  legacy-models/, mtmd-cli.cpp, deprecation-warning.cpp, debug/mtmd-debug.cpp,
  debug/mtmd-debug.md, tests.sh, requirements.txt, README.md, README-dev.md,
  test-1.jpeg, test-2.mp3, test-3.mp4}` (executables/tests/fixtures, not
  library inputs) and every other `tools/` subdirectory (including
  `tools/CMakeLists.txt` — the upstream root option adds `tools/mtmd`
  directly).
- llama.cpp's in-repo `vendor/` except the inputs listed above. The `nlohmann`
  and `sheredom` interface-target CMake declarations are kept because upstream
  configures them unconditionally; their headers remain pruned. `cpp-httplib`,
  tool/server JSON parsing and subprocess video decoding are not built;
  `build.rs` sets `MTMD_VIDEO=OFF` and disables common/tools.
- Non-CPU/non-Metal ggml backend source dirs under `ggml/src/`:
  `ggml-cann`, `ggml-cuda`, `ggml-et`, `ggml-hexagon`, `ggml-hip`, `ggml-musa`,
  `ggml-opencl`, `ggml-openvino`, `ggml-rpc`, `ggml-sycl`, `ggml-virtgpu`,
  `ggml-vulkan`, `ggml-webgpu`, `ggml-zdnn`, `ggml-zendnn`.
  (The matching `ggml/include/ggml-*.h` headers are kept — they are tiny and are
  listed in `ggml/CMakeLists.txt`'s install set; keeping them avoids a broken
  install step and lets a backend return by restoring only its source dir.)
- CI/dev config: `.github/`, `.devops/`, `.gemini/`, `.pi/`, `build-xcframework.sh`,
  `flake.nix`, `CMakePresets.json`, and dotfiles (`.clang-format`, `.clang-tidy`,
  `.editorconfig`, `.gitignore`, `.gitmodules`, etc.).
- Project docs/metadata not needed to build: `README.md`, `AUTHORS`, `CLAUDE.md`,
  `AGENTS.md`, `CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`, `Makefile`,
  Python packaging/config files.

## How to reproduce this snapshot

```sh
curl -L -o b10828.tar.gz \
  https://github.com/ggml-org/llama.cpp/archive/refs/tags/b10828.tar.gz
# verify: shasum -a 256 b10828.tar.gz == da0a960b...b0247
tar xzf b10828.tar.gz
# apply the "Removed" list above to llama.cpp-b10828/
# the result matches the pruned tree SHA256 above.
```
