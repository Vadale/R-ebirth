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
| Pruned tree SHA256 (pre-patch) | `1c8148f33e03bf07b9b8e1e56a0599a5197f4b1069f4dcd28c310e29d47d1289` |
| Pruned tree SHA256 (post-patch) | `6aa56d8432ec0c2d67673ef549adbbf2df658e876b77a678d6ffb779bc7f8781` |

The snapshot includes the multimodal library sources (`tools/mtmd/` +
`vendor/stb/stb_image.h` + `vendor/miniaudio/miniaudio.h`), re-vendored at the
same tag for WP-V1 (DECISIONS.md D-026); stb_image and miniaudio license
records are in the repo-root `NOTICE`.

The same pinned tag feeds the WP6a harness B "unpatched reference" build
(ARCHITECTURE.md §11), so the pin recorded here and in `VENDORING.md` is the
single canonical record both the package build and the reference build consume.

## Patches

The rebirth patch set lives with the source it patches, at
`rebirth/src/llama.cpp/patches/` (committed applied, D-015): `0001` (WP5
ablation hook, D-012/D-016) and `0002` (WP-V1 library-only libmtmd build,
D-026). The pre-patch SHA above is the pristine pruned upstream tree; the
post-patch SHA is the committed tree (CI gate G4).
