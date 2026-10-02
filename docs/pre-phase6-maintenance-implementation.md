# Targeted maintenance — implementation and evidence

Date: 2026-10-02. Status: implementation, review and local acceptance complete;
remote acceptance and integration pending. Contract: [reviewed maintenance plan](pre-phase6-maintenance-plan.md),
authorized by the founder after review. No new public API, package dependency,
vendor pin/patch or numerical threshold.

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
Linux sanitizer execution and final-source Mac/Linux vision comparisons are
pending. The first dispatch at `060e5a8` was rejected before execution: GitHub
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
No instrumented product test has yet been accepted; a successful build alone
is not sanitizer acceptance. Final compiler versions, hashes, commands and receipts will be
recorded after execution.

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
