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
| Tag | `b10828` (released 2026-09-06) |
| License | MIT (reproduced in the repo-root `NOTICE`) |
| Release tarball SHA256 | `da0a960b36505081df726d35552ae71e84c5b7da313d41d9c52055f0d85b0247` |
| Pruned tree SHA256 (pre-patch) | `fd1b8327ef675dc91de4b9fde547d8afb7d4c6b2aa63a8f989e421cf59edd7ac` |
| Pruned tree SHA256 (post-patch) | `978b070a9520cd6dfdf6fe15719854dc0ff4b3a68c679102b18d696a335d74ad` |

The snapshot includes the multimodal library sources (`tools/mtmd/` +
`vendor/stb/stb_image.h` + `vendor/miniaudio/miniaudio.h` + `vendor/hash/`),
updated for native Spark 2.5 support (D-032). Native third-party license records
are in the repo-root `NOTICE`.

The same pinned tag feeds the WP6a harness B "unpatched reference" build
(ARCHITECTURE.md §11), so the pin recorded here and in `VENDORING.md` is the
single canonical record both the package build and the reference build consume.

## Patches

The rebirth patch set lives with the source it patches, at
`rebirth/src/llama.cpp/patches/` (committed applied, D-015): `0001` (WP5
ablation hook, D-012/D-016). Patch `0002` (WP-V1 library-only mtmd build)
is retired because b10828 provides that build path upstream. The pre-patch SHA above is the pristine pruned upstream tree; the
post-patch SHA is the committed tree (CI gate G4).
