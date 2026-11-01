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
| Pruned tree SHA256 (pre-patch) | `e89c0d0b00b6d31cccf55ff5463a06455617341c15b966d5daeda89fb03b27b5` |
| Pruned tree SHA256 (post-patch) | `e769cc030d2377f56270fd6394bab5a19983b2073a6bc60bcbdd07bcba215601` |

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

D-050 restores the unchanged b10828 CUDA source directory for the optional Linux
backend. The version and existing patches are unchanged; both tree digests above
include the restored files. This also corrects the obsolete post-patch mirror.

D-058 adds the direct `<cerrno>` include for the existing GGUF error diagnostic
as patch 0007. Upstream b10828 and the pre-patch tree are unchanged; the
post-patch identity above matches the build-consumed VENDORING.md.

## D-059: bounded engine safety backports

The b10828 pin, upstream archive and pre-patch digest are unchanged. Patch0008
backports only candidate-filter iteration from [PR31153](https://github.com/ggml-org/llama.cpp/pull/31153),
whole merge tiles from [PR31336](https://github.com/ggml-org/llama.cpp/pull/31336),
and wider Metal indices from [PR30072](https://github.com/ggml-org/llama.cpp/pull/30072).
No common/server changes or parser-depth policy are imported. API, schema bounds,
model weights, floating-point computations, taps and independent goldens remain
unchanged. See `tests/engine-boundaries/README.md` for reachability and test limits.
