# D-040 candidate and diagnostic evidence

The [proposal](../../../../docs/cpu-callback-signatures-proposal.md) is not approved
or applied. `candidate.patch` changes seven CPU trait table entries to use seven
static exact-signature adapters in the same source file. `scope.json` lists the
original source hash and exact replacements.

`shared.h` uses actual ggml headers and the current dot-function declarations.
The C/C++ forwarding harness uses typed **stub** targets; it is not numerical
kernel acceptance. `type-checks.json` records seven original-cast errors and
successful corrected assignments. `commands.json` retains every local compile,
link and invocation. Raw stdout/stderr/symbol listings are lossless gzip files.

The local original-call runtime probe returned zero and printed
`ORIGINAL_TYPE_MISMATCH_SURVIVED`; it failed to reproduce the Linux finding.
The corresponding main object has no function-type-mismatch runtime hook.
Do not treat the seven passing forwarding cases as active runtime-type-check
acceptance. The actual Linux finding is retained separately under
`../../evidence/linux-37086505519`. The whole engine gate remains open.

`receipt.json` distinguishes these outcomes and records retained-file hashes.
Executables, object files and dSYM bundles are not included. Approval must precede
application or a new annotated vendor patch.
