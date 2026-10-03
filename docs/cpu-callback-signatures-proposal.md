# D-040 proposal — exact CPU trait callback signatures

2026-10-03. Approved by the founder ("si si correggi") and applied. This is a second bounded vendor
correction within pre-Phase-6 maintenance, separate from approved D-039.

## Observed failure and bounded source audit

Linux ASan/UBSan run `37086505519` at `e280868` passes the D-039 graph layout
control and compiled-instrumentation audit, then stops in the first selected
embedding test at `ggml-cpu.c:1244`. `ggml_vec_dot_f32`, whose inputs are typed
float pointers, is called through `ggml_vec_dot_t`, whose inputs are generic
pointers. The cast in the CPU trait table does not make those function types
compatible. The actual report identifies an incorrect-function-type call;
this is not evidence of a numerical deviation, leak or race. Zero product tests
completed in that run. The raw report and source scope are retained under
`tests/sanitizers/evidence/linux-37086505519`.

A bounded audit of that table finds **seven** such explicit casts: dot callbacks
for F32/F16/BF16 and conversion callbacks from F32 to F32/F16/BF16/I32. Only
the F32 dot callback is demonstrated by the Linux runtime failure. The other six
are established by source signatures and compiler type diagnostics, not claimed
as separately observed runtime failures.

## Exact proposed change

[Candidate patch](../tests/sanitizers/proposals/cpu-callbacks/candidate.patch)
adds seven static adapters in `ggml-cpu.c` and assigns them directly to the CPU
trait table. Each adapter has exactly the generic callback signature and makes
a normal typed call to the existing function, forwarding every argument.
Exact patch SHA256:
`77db30621368302672f5ab1a3b06a1dc3f9b0b058f3beea3cc1a2b3a250a3db2`.

The numerical kernels, conversion implementations, vector instructions, backend
selection, allocated layouts, model inputs and tolerances are unchanged. There
is no new public symbol, R/Rust dependency, engine version upgrade or sanitizer
suppression. Existing F16/BF16 target signatures retain their pointer qualifiers;
this proposal does not refactor their implementations.

Application records separate annotated patch0004 and updated post-patch
digest under D-015. Preserve b10828, upstream/pre-patch identity and D-039.
No other callback family or unrelated vendor change is authorized by this scope.

## Verification so far and required gates

- Apple Clang21 rejects all seven original casts with strict function-type
  diagnostics and accepts all seven proposed direct assignments without errors.
- A small C/C++ forwarding harness exercises all seven adapters with typed stub
  targets. It checks pointer identity, counts, strides, scalar outputs and buffer
  writes. All seven contracts pass. It does **not** execute the numerical kernels.
- The attempted local runtime reproducer **did not reproduce** the Linux error:
  the original cast returned successfully, and the local object contains no
  function-type-mismatch runtime hook. That negative control is retained as a
  failed reproduction; the Mac run is not runtime type-sanitizer acceptance.
- `git apply --check` accepts the exact patch, without applying it. Sources,
  commands, compiler identity and lossless logs are in the
  [proposal evidence](../tests/sanitizers/proposals/cpu-callbacks/README.md).

Acceptance first requires the short positive/negative callback controls with
the pinned Linux Clang19 compiler, then the existing full 15-test instrumented
native gate. Current-source numerical goldens, R boundaries, both vision runners,
G4/reverse coherence and all nine final CI checks remain required. No numerical
reference may be regenerated to make this change pass. A further distinct finding
must be diagnosed separately.

Clang documents the purpose of its function-type check in the
[UBSan manual](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html).
Platform acceptance here is determined by the recorded controls, not the mere
presence of a compiler flag.

## Approved decision

The founder approved exactly these seven CPU trait adapters and D-015 bookkeeping, followed
by the unchanged gates. This separate decision is required by
`.claude/agents/coder.md:21`: “any other vendored change needs founder approval”.
D-039 authorized only graph-storage sizing and remains approved and applied;
full native acceptance is still open.


## Application record

The founder approved the exact scope on 2026-10-03. Patch0004 applies the candidate
above without additional vendor edits. G4/reverse coherence pass at post-patch
SHA256 `f131eca9a917a5c3bff5cfc4a80d4f88c24597747f9298a7e021cf7586955db7`.
The source-derived regression is `tests/sanitizers/cpu_callbacks.py`; the required
Linux invocation uses `--require-runtime`. Its positive typed-stub contracts do
not replace the full engine's unchanged numerical and sanitizer gates.
