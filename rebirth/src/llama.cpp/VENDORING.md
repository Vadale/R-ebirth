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
| Tag | `b9726` |
| Tag release date | 2026-06-19 |
| ggml version | 0.15.2 (per `ggml/CMakeLists.txt`) |
| Upstream release tarball | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/b9726.tar.gz` |
| Release tarball SHA256 | `117e95a59967e91b097d1bfdf62c3d10e8d08aec01be8548a093dcceecf9f2e0` |
| Pruned tree SHA256 (pre-patch) | `1c8148f33e03bf07b9b8e1e56a0599a5197f4b1069f4dcd28c310e29d47d1289` |
| Pruned tree SHA256 (post-patch) | `6aa56d8432ec0c2d67673ef549adbbf2df658e876b77a678d6ffb779bc7f8781` |

Both tree SHAs were recomputed for WP-V1 (D-026): the prune manifest was
widened with the mtmd library sources (see "Kept" below) and patch 0002 landed.
The tarball SHA is unchanged — same upstream tag, no vendor bump.

The **release tarball SHA256** is the digest of the unmodified upstream
`b9726.tar.gz` as downloaded from GitHub — verifiable by anyone against upstream.

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
| `0002-rebirth-wp-v1-mtmd-library-build.diff` | 2 files, 3 hunks | Library-only libmtmd build path: a root option `LLAMA_BUILD_MTMD` (default OFF) adds `tools/mtmd` even with `LLAMA_BUILD_COMMON`/`LLAMA_BUILD_TOOLS` OFF, and `tools/mtmd/CMakeLists.txt` guards the CLI/debug executables + the `llama-common` FATAL_ERROR check behind `LLAMA_BUILD_TOOLS`, so only the `mtmd` static archive builds. Build files only — zero engine-source change. | D-026 |

The two patches touch disjoint file sets (0001: engine sources; 0002: two
CMake build files), so the coherence reverse-apply is order-independent.

WP4 (activation observation) added **zero** patches (the eval-callback tap is
zero-patch, D-012); WP5's ablation hook above is the project's first vendored
patch. **The un-intervened path is unchanged:** the WP2/WP3/WP4 synthetic goldens
pass byte-identically after the patch (engine-vs-oracle max |Δ|: logits 1.99e-3,
embeddings 2.92e-3, activations 3.73e-3 — the pre-patch values).

`vendor-bump`: fetch upstream b9726 → re-apply `patches/*.diff` → re-run harness B
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
- `ggml/src/` core (`ggml.c`, `ggml.cpp`, `ggml-alloc.c`, `ggml-backend*.{cpp,h}`,
  `ggml-common.h`, `ggml-impl.h`, `ggml-opt.cpp`, `ggml-quants.{c,h}`,
  `ggml-threading.{cpp,h}`, `gguf.cpp`).
- `ggml/src/ggml-cpu/` (full, all `arch/` subdirs), `ggml/src/ggml-metal/`
  (including `ggml-metal.metal`), `ggml/src/ggml-blas/`.
- `tools/mtmd/` **library** inputs only (WP-V1, D-026): `clip.{cpp,h}`,
  `clip-impl.h`, `clip-model.h`, `clip-graph.h`, `mtmd.{cpp,h}`,
  `mtmd-image.{cpp,h}`, `mtmd-audio.{cpp,h}`, `mtmd-helper.{cpp,h}`,
  `models/*.cpp` + `models/models.h`, `debug/mtmd-debug.h` (the debug
  *functions* live in `mtmd.cpp`; only the header is a library input), and
  `CMakeLists.txt` (carries the patch-0002 library-only guards). libmtmd links
  only `ggml` + `llama` — it is explicitly forbidden from linking
  `llama-common`, which is why `common/` stays pruned.
- `vendor/stb/stb_image.h` (image decode) and `vendor/miniaudio/miniaudio.h`
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
  `tools/CMakeLists.txt` — the patch-0002 root option adds `tools/mtmd`
  directly).
- llama.cpp's in-repo `vendor/` except `stb` and `miniaudio` (above):
  `cpp-httplib`, `nlohmann`, `sheredom` (used only by `common/`/tools/server
  and the `MTMD_VIDEO`-guarded video path, none of which we build; `build.rs`
  sets `MTMD_VIDEO=OFF`).
- Non-CPU/non-Metal ggml backend source dirs under `ggml/src/`:
  `ggml-cann`, `ggml-cuda`, `ggml-hexagon`, `ggml-hip`, `ggml-musa`,
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
curl -L -o b9726.tar.gz \
  https://github.com/ggml-org/llama.cpp/archive/refs/tags/b9726.tar.gz
# verify: shasum -a 256 b9726.tar.gz == 117e95a5...f2e0
tar xzf b9726.tar.gz
# apply the "Removed" list above to llama.cpp-b9726/
# the result matches the pruned tree SHA256 above.
```
