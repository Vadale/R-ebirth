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
| Pruned tree SHA256 | `49422544bd37aad88f5f379b6e0f34d435529a858645249fed8e49cc291a5a92` |

The **release tarball SHA256** is the digest of the unmodified upstream
`b9726.tar.gz` as downloaded from GitHub — verifiable by anyone against upstream.

The **pruned tree SHA256** is a reproducible digest of *this* vendored tree
(after the prune below), computed from the sorted per-file SHA256 manifest,
excluding this file and the `patches/` directory:

```sh
# run from this directory (rebirth/src/llama.cpp)
find . -type f -not -path './VENDORING.md' -not -path './patches/*' \
  | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256
```

## Patches

None. **WP1 applies zero source patches** — the vendored build is behaviourally
identical to an unpatched upstream build at the same tag, which is the clean
baseline the WP4 activation-tap patch set must later leave numerically
undisturbed (ARCHITECTURE.md §5, §11). The `patches/` directory is created empty
here and populated in WP4; each hunk will be annotated with why it exists so the
quarterly `vendor-bump` skill stays mechanical.

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
