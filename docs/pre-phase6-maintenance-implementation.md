# Targeted maintenance — implementation and evidence

Date: 2026-10-02. Status: implementation, review and local acceptance complete;
remote acceptance and integration pending. Contract: [reviewed maintenance plan](pre-phase6-maintenance-plan.md),
authorized by the founder after review. No new public API, package dependency,
vendor pin or numerical threshold; the separately approved D-039 and D-040 patches are documented below.

## Managed spill lifetime

The R lifecycle registers its managed path without filesystem allocation. The
first actual `SpillSink` write acquires a native lease before creating its Arrow
file. The process retains the lease after the writer finishes, protecting lazy
readers until normal session cleanup. The registry is independent of model
ownership; it stores filesystem leases, not R objects or inference handles.

The native bridge uses descriptor-relative, no-follow path operations and
nonblocking advisory locks on macOS/Linux. Cleanup requires the managed marker,
matching directory/marker identities and flat regular trace files. Unknown,
legacy, replaced, linked or permission-inaccessible paths are retained. The
minimum directory age remains seven days for crash reclamation. Neither a PID
nor a timestamp proves a session has stopped. Normal exit cleanup is best-effort;
custom directories are not registered by the public trace path.

Fourteen standalone native controls passed locally: actual live-child/crash,
recent orphan, normal/idempotent cleanup, legacy/malformed metadata, genuine
permission denial, root/candidate symlinks, replaced candidate, unknown nested
or linked content, second-owner refusal, simultaneous sweepers, exclusive file
creation and directory replacement between validation and opening. The bridge
compiled with `-std=c++17 -Wall -Wextra -Werror`; these controls exercise the
actual C++ implementation without an engine/model build. Command:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -DRELM_SPILL_TESTING -fPIC -shared \
  rebirth/src/rust/rebirth-llm/native/spill_lease.cpp -o /private/tmp/relm-maintenance/spill-lease.dylib
python3 tests/spill-lifecycle/test-native.py /private/tmp/relm-maintenance/spill-lease.dylib
```

New installed-package R controls run a real R child with the existing synthetic
fixture, verify in-memory laziness, actual Arrow slice equality while the owner
is alive, normal cleanup, and post-crash reclamation. The first fresh installed package passed 14 spill cases / 100 expectations,
with no skips, errors or test warnings. Six native spill and seven FFI tests also
passed, as did workspace clippy. The linker retained its duplicate `-lc++` warning.
Receipts are in `tests/spill-lifecycle/evidence/macos-2026-10-02`; they retain
source scope before later directory-iterator RAII and descriptor-relative writer
corrections. The final standalone controls pass all fourteen cases. Final
Mac/Linux CI remains. Final integrated local results are recorded below. The subprocess model-preparation
budget is separate from its ten-second cleanup gate; no long-model stress is
substituted for these checks.

The integrated review identified a path-reopen race after lease validation.
Managed files are now created with exclusive `openat` through the retained
directory descriptor while the registry mutex remains held. Rust adopts that
descriptor rather than reopening a pathname. The deterministic replacement test
confirms that a replacement directory is untouched and the operation fails
closed; its injection hook is compiled only into the standalone test bridge.
The follow-up review also identified an exception-path descriptor leak; both
the newly opened file and root traversal now retain RAII ownership until the
explicit successful transfer. The first final pipeline was interrupted for this
correction; its receipt is retained and is not counted as acceptance.
Final directory removal is not atomic against arbitrary same-account renames;
this design protects cooperating sessions and conservatively retains uncertain
paths, without claiming a security boundary against that account.

The unsupported-platform stub retains uncertain directories and cannot certify
managed spilling there. Windows remains a separate hardware/build milestone.
This is not protection against an adversary controlling the user's account.

## Native sanitizers and reference content binding

The separate implementation blocks add the planned Linux instrumentation
controls/job and a verified snapshot handoff for the vision reference. Actual
Linux sanitizer acceptance remains open; both Mac/Linux vision comparisons are
now verified at `e280868` (see the final verification section below). The first dispatch at `060e5a8` was rejected before execution: GitHub
does not expose the `runner` expression context in job-level `env`. The workflow
now initializes those paths from shell `RUNNER_TEMP` in its first step. No native
job ran or test passed in that rejected dispatch; the receipt is retained in
`tests/sanitizers/evidence/dispatch-2026-10-02.json`. Ten sanitizer harness controls and fourteen reference manifest/handoff
controls pass locally, along with workflow parsing/shell validation; no native
Linux sanitizer or real vision result is inferred from them. Workflow definitions
and model-free helper tests alone do not close these gates. Linux run
`37042396331` passed Valgrind but failed the sanitizer mixed-language preflight
link before any instrumented product build/test: rustc passed `-nodefaultlibs`,
leaving C++ ABI symbols in Clang's runtime unresolved. The isolated flags now
explicitly link the existing `libstdc++`; compiler pins, sanitizer settings and
all acceptance criteria are unchanged. Failed raw receipts are retained under
`tests/sanitizers/evidence/linux-37042396331`. The scoped retry skips the already
passing Valgrind job; scheduled runs still execute both.

Run `37043713389` then passed all mixed-language safe/fault and uninstrumented
controls and completed the instrumented Cargo build with exit zero. It failed
before object auditing or product-test execution because the reader attempted to
parse Cargo's `-vv` build-script lines as JSON. The corrected reader recognizes
those prefixed lines, requires one successful `build-finished` event and the
complete unique set of seven test binaries, and still rejects malformed or
unrecognized output. Replaying the retained real log passes; twelve harness
controls include missing, failed, duplicate and script-prefixed fake completion
cases. Raw evidence is under `tests/sanitizers/evidence/linux-37043713389`.
No instrumented product test was accepted in that run; a successful build alone
is not sanitizer acceptance.

Run `37045430641` passed preflight and the compiled-instrumentation audit of 269
C/C++ objects plus the `rebirth_llm`, Arrow and Rust standard-library archives,
including the patched `build_cvec` machine code. The first product test then
failed UBSan in upstream `ggml.c:7368`: `incr_ptr_aligned` applies an offset of
96 bytes to a null pointer while `ggml_graph_nbytes` calculates storage size.
This is observed undefined pointer arithmetic, not evidence of a null dereference
or allocation leak. Zero product tests completed successfully. The actual finding
and audit receipts are retained in `tests/sanitizers/evidence/linux-37045430641`.
The founder approved the exact one-function [D-039 correction](ggml-graph-sizing-proposal.md)
on 2026-10-03; it is applied and recorded as patch0003 under D-015. No suppression
or tolerance change has been made. A standalone Mac
ASan/UBSan reduction reproduces the original error; the candidate passes 68
layout cases and a dry-run patch check. These are diagnostic controls, not the
uncompleted Linux product gate. Proposal sources, commands and lossless results
are retained in `tests/sanitizers/proposals/ggml-graph-size`. The applied source
passes a new portable source-derived 68-case check; the original null arithmetic
must still be rejected as a negative control. G4 and reverse-patch coherence pass
with unchanged upstream/pre-patch identities. The post-patch SHA256 is
`68a7959e27e6e115fdac028aa65c097ce00cf32cc07116a9280ce563c6c78ceb`.

The Mac and Linux legs of vision run `37042401022` failed before producing the
reference or executing its comparator. The parent R process used `load_all`, but
async lifecycle children could not load an installed `relm` package. The workflow
now installs the checkout in a fresh job-local library before the unchanged
suite. A separate Rscript must confirm the installed package and DLL path and
record the DLL digest. Early source, installation and child-process diagnostics
are retained even when the R stage fails. YAML, seven shell scripts, two embedded
Python blocks and two R blocks pass structural/syntax checks. No corrected remote
execution is claimed; batch its retry with the final approved source. The full failure
logs and job metadata are retained in
`tests/llm-golden/vision/evidence/maintenance-37042401022`. No successful numerical
comparison or reference artifact is inferred from this run. Final compiler
versions, hashes, commands and receipts will be recorded after execution.

## Verification boundary

The earlier I1/WP9/WP10/service acceptance is retained with its own source scope;
it is not repeated or relabelled as maintenance acceptance. The final isolated
pipeline passed on macOS arm64 / R 4.5.1, with no source drift against its manifest:

- `cargo fmt --all --check`, standalone FFI formatting and locked/offline
  workspace/all-target clippy with warnings denied passed.
- `cargo test --locked --offline -p rebirth-llm`: 142 passing outcomes and one
  ignored calibration; `--no-default-features`: 134 and one respectively. Optional
  model-gated early returns are not real-model execution evidence.
- Fresh isolated `R CMD INSTALL`, followed by the whole installed-package
  model-free R suite: 312 cases, 2,851 passing expectations, zero failed/error/
  warning results, and 55 explicit model/download skips. The new real-child
  lifecycle/readback cases are included. The duplicate `-lc++` linker warning
  remains recorded, as does the startup warning that testthat was built under
  R 4.5.2 while this host runs R 4.5.1.
- Source build plus scoped `R CMD check --no-install --no-tests --no-vignettes
  --no-manual`: zero errors and two warnings solely about deliberately omitted
  vignette outputs. Examples passed; tests were executed separately above. Full
  package/vignette checks remain required on all four R CI legs.

Commands, session versions, source hashes, raw results and skip names are in
`tests/spill-lifecycle/evidence/final-macos-2026-10-02`. Raw logs are losslessly
gzip-compressed with stored raw and archive digests. The retained async responsiveness receipt records fulfilled parent and observer
promises, zero live native counts and completion in 2.053 seconds. This does not
relabel earlier CI failures. The first installed package and interrupted
pipeline remain separately scoped in `macos-2026-10-02`.

Required remote results must pass before this work is accepted and integrated.
No release, Phase-6 API or marketplace publication is part of this work package.

### Applied D-039 local validation — 2026-10-03

The final modified size function passed fmt/clippy, all 142 default engine test
outcomes (one calibration remains ignored), seven FFI tests, fresh isolated R
installation and 118 focused R cases with 1,915 passing expectations, zero
failures/errors/test warnings and 25 explicit model skips. The source manifest
has no drift. R tests cover generation, trace/spill, async and streaming at the
new package path. Linker duplicate-library and testthat patch-version warnings
remain explicit. This stage did not repeat the broader model matrix or scoped
package archive check; all four ordinary R CI legs still gate the final source.
Receipts and lossless logs are in `tests/sanitizers/evidence/d039-macos-2026-10-03`.
The older Valgrind result remains scoped to its original source; the final
ASan/UBSan acceptance remains open. Both vision comparisons and all nine ordinary
checks subsequently passed at `e280868`, as recorded below.

### Second Linux finding — 2026-10-03

Run `37086505519` at `e280868` passed the new 68-case graph-size control and
compiled-instrumentation audit, then failed during the first selected embedding
test: the generic CPU function pointer calls `ggml_vec_dot_f32` with an
incompatible function type. No product test completed. The prior graph-sizing
finding is not being relabelled; this is a distinct callback-boundary finding.
Raw logs and scope are in `tests/sanitizers/evidence/linux-37086505519`.

[D-040](cpu-callback-signatures-proposal.md) specifies seven exact-signature
adapters for the seven casted callbacks in that table. Only F32 dot has the
observed runtime failure; the other six have source/compiler type evidence.
Seven corrected assignments and stub-forwarding contracts pass locally. The
local attempted runtime reproducer did not detect the original call, and that
failed reproduction is preserved explicitly. Pinned Linux controls and full
acceptance remain required. The founder approved D-040 on 2026-10-03 with
"si si correggi" after the concrete proposal. The exact patch is applied as
`0004-cpu-callback-signatures.diff`; D-039 is unchanged. No suppression, tolerance
or numerical-kernel change.

### Ordinary CI and vision verification — 2026-10-03

All nine individual ordinary checks passed at exact source
`e280868e3cae25f244a988b08990c673af8be586`:
[R checks](https://github.com/Vadale/R-ebirth/actions/runs/37086508973) and
[Rust checks](https://github.com/Vadale/R-ebirth/actions/runs/37086508968).
The [vision run](https://github.com/Vadale/R-ebirth/actions/runs/37086507678)
passed on both macOS arm64 and Linux x64. Independent collection verifies each
reference's actual bytes, 64 by 1,536 finite values, exact source/workflow
identities, distinct job nonces and matching consumed/success comparison digests.
Both comparisons reported maximum absolute difference zero against their own
same-runner reference. Native token/comparison and async VLM markers, fresh-child
package/DLL identity and the installed R suite completed successfully.

Lossless artifacts, raw/archive hashes, the independent collector and all nine
check receipts are retained in
`tests/llm-golden/vision/evidence/maintenance-37086507678`.
Producer/model/shared-library bytes absent from the downloaded artifact retain
runtime-verified manifest identities; they were not independently rehashed
locally. Each reference remains runner-specific. These results do not certify a
D-040 source or change the failed sanitizer result. That decision is now approved;
the corrected source needs its own affected acceptance.

### Applied D-040 and focused regression — 2026-10-03

Seven exact-signature adapters and direct CPU trait assignments are applied from
the approved candidate, SHA256
`77db30621368302672f5ab1a3b06a1dc3f9b0b058f3beea3cc1a2b3a250a3db2`.
No other vendor code changed. The new post-patch digest is
`f131eca9a917a5c3bff5cfc4a80d4f88c24597747f9298a7e021cf7586955db7`;
G4 and reverse application both pass with unchanged upstream/pre-patch identities.

`tests/sanitizers/cpu_callbacks.py` extracts the live adapters and verifies their
live trait assignments. Actual headers declare the C/C++ boundary. Seven strict
original-cast rejections, corrected assignments and seven typed-stub forwarding
contracts pass locally. The unchanged uninstrumented original calls execute;
the Mac instrumented controls still have no function-type hook and are explicitly
`unavailable_not_accepted`. This does not certify Linux or numerical kernels.
Four source-mutation guards and twelve existing harness controls pass. The nightly
runs the short control with pinned Clang19, an explicit symbolizer and mandatory
runtime rejection for all seven original calls before any full instrumented build.
The corrected source's numerical/FFI/fresh R installation checks passed locally;
full Linux sanitizer and both vision gates remain required.

A focused independent review of the D-040 patch, source-derived controls and
workflow found no material blocker. It confirmed exact approved patch hunks,
unchanged typed kernel calls and fail-closed mandatory Linux controls. It did
not execute builds/models or replace the required operational acceptance.

Final local D-040 validation passed fmt/clippy, 142 native outcomes (one ignored
calibration), seven FFI tests and a fresh package installation. The focused R
suite passed 1,957 expectations in 129 cases with zero failures/errors/test
warnings and 30 explicit model skips. Native model-gated early returns do not
establish real-model acceptance. The source manifest has no drift. The duplicate
`-lc++` linker warning and testthat-built-under-R4.5.2/local-R4.5.1 warning remain
in the lossless receipts at `tests/sanitizers/evidence/d040-macos-2026-10-03`.
The exact local callback runner snapshot is retained before the subsequent
optional Linux symbolizer parameter; the local default behavior is unchanged.
