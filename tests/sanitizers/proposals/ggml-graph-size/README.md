# D-039 historical proposal evidence

This directory preserves the exact one-function candidate and bounded Mac
diagnosis for [D-039](../../../../docs/ggml-graph-sizing-proposal.md).
These snapshots were recorded before approval and do not change retroactively.
The founder subsequently approved D-039 on 2026-10-03; the exact candidate is
applied as patch0003. Current-source regression lives in `../../graph_size.py`.

`candidate.patch` SHA256:
`ea9cfc8855e64c6e91b3e5be9b70d4dbb09c01e26c26d3943664013048072beb`.
The original `ggml.c` SHA256 is
`683cbf1340ae08791d720045d1bc8b416b5cfa8de37484f878c03cf02de304b7`.

`null-offset.c` reproduces the original undefined null-plus-96 arithmetic and
exits 1 under ASan/UBSan as expected. `layout-check.c`, using actual b10828 types
and the extracted candidate, passes 68 size/gradient combinations against an
independent alignment oracle and the unchanged real-buffer pointer helper.
The tested compiler is Apple Clang 21.0.0 on arm64, not Linux Clang 19.

The Python scripts, command arguments and extracted headers are the original
diagnostic snapshots, including their scratch paths. They are provenance, not
yet a portable CI regression or proof of the Linux product-test gate. If approved,
the regression must extract and check the actual applied source and run on both
supported hosts. No binary, dSYM or full duplicate vendor source is retained.

All original stdout/stderr and the diagnosis report are lossless gzip files.
`retained-files.json` records hashes of raw and compressed bytes. The original
command receipt records the expected failing reproducer, successful layout
check and successful dry-run patch application separately. The observed Linux
run still has zero completed product tests; this proposal does not relabel it.
