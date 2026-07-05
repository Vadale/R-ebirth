# vendor/ — provenance records only

Per **DECISIONS.md D-006** the build-consumed llama.cpp snapshot lives *inside the
package* at `rebirth/src/llama.cpp/` (self-containment for `R CMD build`/`R CMD
check` and CRAN — D-005). This top-level `vendor/` directory is **not a build
input**; it is a provenance record that mirrors the pin so the canonical
tag + digest live next to the repo-root `NOTICE`. The authoritative record (with
the full prune manifest and reproduction steps) is
`rebirth/src/llama.cpp/VENDORING.md`.

## Pinned llama.cpp

| Field | Value |
|---|---|
| Upstream | https://github.com/ggml-org/llama.cpp |
| Tag | `b9726` (released 2026-06-19) |
| License | MIT (reproduced in the repo-root `NOTICE`) |
| Release tarball SHA256 | `117e95a59967e91b097d1bfdf62c3d10e8d08aec01be8548a093dcceecf9f2e0` |
| Pruned tree SHA256 | `49422544bd37aad88f5f379b6e0f34d435529a858645249fed8e49cc291a5a92` |

The same pinned tag feeds the WP6a harness B "unpatched reference" build
(ARCHITECTURE.md §11), so the pin recorded here and in `VENDORING.md` is the
single canonical record both the package build and the reference build consume.

## Patches

The activation-tap patch set (WP4) lives with the source it patches, at
`rebirth/src/llama.cpp/patches/`. **WP1 applies zero patches.**
