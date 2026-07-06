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
| Pruned tree SHA256 (pre-patch) | `49422544bd37aad88f5f379b6e0f34d435529a858645249fed8e49cc291a5a92` |
| Pruned tree SHA256 (post-patch) | `1796dcde3b2c46e96f7ac78288c0d1e08279dada0432ada7d570dba461ee9440` |

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

The snapshot keeps only what a static CPU + Metal (with embedded shaders) build
of `libllama` + `ggml` needs. "When unsure, keep" — the prune is conservative and
still builds. Non-CPU/non-Metal ggml backends return per-backend when their phase
arrives (CUDA at Phase 8).

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
- `LICENSE` (llama.cpp MIT — required at configure time by `cmake/license.cmake`
  and reproduced in the repo-root `NOTICE`).

### Removed (not needed for the static CPU + Metal library)

- Top-level dirs: `examples/`, `tools/`, `tests/`, `models/`, `docs/`, `media/`,
  `scripts/`, `ci/`, `app/`, `benches/`, `pocs/`, `grammars/`, `conversion/`,
  `gguf-py/`, `requirements/`, `common/`, `licenses/`, and llama.cpp's in-repo
  `vendor/` (cpp-httplib, miniaudio, nlohmann, sheredom, stb — used only by
  `common/`/tools/server, which we do not build; the kept `libllama`/`ggml`
  sources include none of these headers, verified).
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
