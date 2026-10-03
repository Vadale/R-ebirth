# D-039 proposal — defined arithmetic for graph storage sizing

Proposed 2026-10-02; founder approved on 2026-10-03 ("Ok vai" after the
concrete D-039 request). The exact patch has now been applied. This is a bounded amendment to pre-Phase-6 maintenance, not a
llama.cpp version upgrade or new public API.

## Observed failure

Linux sanitizer run `37045430641`, source `cb607eb40b83ef14343ebaa1056b9a4b7b84adb4`,
passed the mixed-language fault controls and compiled-instrumentation audit.
The first actual product test then stopped at `ggml/src/ggml.c:7368` with:

```text
runtime error: applying non-zero offset 96 to null pointer
```

`ggml_graph_nbytes` starts a pointer at zero and calls `incr_ptr_aligned` to
calculate a required byte count. Adding a nonzero offset to that null pointer is
undefined C behavior even though this size calculation does not dereference it.
The failed run does not establish a leak, exploit or numerical error; it does
establish that the required UBSan acceptance cannot pass unchanged. Raw failure
and instrumentation receipts are in `tests/sanitizers/evidence/linux-37045430641`.

## Proposed source change

Compute the size-only path with integer byte offsets and the same alignment and
component-size expressions. Leave the helper that advances pointers within the
actual allocated graph buffer unchanged. Preserve the `b10828` pin, graph layouts,
public API, dependencies, numerical thresholds and all sanitizer controls.

The exact [candidate diff](../tests/sanitizers/proposals/ggml-graph-size/candidate.patch)
changes only `ggml_graph_nbytes`. Its SHA256 is
`ea9cfc8855e64c6e91b3e5be9b70d4dbb09c01e26c26d3943664013048072beb`.
The original diff remains as proposal provenance. Applied source is recorded
as `patches/0003-ggml-graph-size-offsets.diff` under D-015. The new post-patch
digest is `68a7959e27e6e115fdac028aa65c097ce00cf32cc07116a9280ce563c6c78ceb`;
G4 and reverse application to the unchanged pre-patch digest both pass. No compiler suppression or disabled UBSan category is
part of the proposal.

## Validation and stopping rule

Bounded standalone verification has completed on this Mac with Apple Clang
21.0.0 and ASan/UBSan. An independent minimal reduction reproduces the original
null-plus-96 diagnostic (expected exit 1). The extracted candidate passes **68
layout cases**: 34 sizes from zero through 65,536, each with gradient storage
disabled and enabled. An independent remainder-based alignment oracle and an
exact-sized allocated buffer verify field offsets, alignment, endpoint writes
and total size. `git apply --check` succeeds without applying the patch.
[Sources, commands, compiler identity and lossless logs](../tests/sanitizers/proposals/ggml-graph-size/README.md)
retain the actual results. This is not Linux or full engine acceptance.

The proposal does not add general overflow validation for arbitrary `SIZE_MAX`-
scale requests. Existing hash selection, allocation alignment and supported
graph-size assumptions remain; no wider size-safety claim is made.

After approval, require the final native synthetic numerical gates, vendor hash
and reverse-patch coherence, the full scoped Linux ASan/UBSan test selection,
corrected Mac/Linux vision comparisons and all nine final CI checks. Reuse
unaffected RStudio, service and companion acceptance with honest source scope.
If another concrete upstream sanitizer finding appears, retain it and assess
its scope separately; this proposal does not authorize arbitrary vendor edits.

## Approval record

The project implementation rule in `.claude/agents/coder.md` states:
“any other vendored change needs founder approval”. D-015 authorizes the patch
application mechanism; its scope note requires each patch's content to have its
own decision. The original maintenance plan did not approve a ggml source patch.

The founder approved only this integer-size calculation correction and its
D-015 patch/digest bookkeeping, followed by the unchanged acceptance gates.
No additional vendor change or version upgrade is authorized.

The portable `tests/sanitizers/graph_size.py` now extracts the actual applied
source, rather than the frozen proposal. Its 68-case layout check and original
arithmetic rejection pass with local Apple Clang21. Linux/full-engine/vision
acceptance on this changed source remains pending.
