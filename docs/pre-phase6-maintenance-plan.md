# Targeted maintenance before Phase 6

Date: 2026-10-02. Status: reviewed plan; implementation
not started. The founder authorized preparation of this plan after I1.
Baseline: main `ee06d30b1295f779a3f77a5a18afeff7a1896a07` (PR #56).

## Goal and boundary

Protect existing traces and make the memory-safety and reference checks reliable
before adding live introspection. This is one bounded maintenance work package,
with three implementation blocks and one final integration milestone. It does
not reopen WP9, WP10, I1 or the completed service acceptance.

No public signature, R/Rust dependency, numerical tolerance, vendor pin or
vendored patch change is planned. D-013/D-017 govern spill and materialized-memory
budgets; D-019 already tracks full native sanitizer coverage; D-026 governs
same-machine vision references. D-029 governs proportionate verification and
background monitoring. New APIs/dependencies, if actually needed, require their
own proposal before use. Internal cleanup and test infrastructure can be changed
within those contracts without inventing a new public API.

## Observed baseline

| Debt | Source inspected | Practical consequence |
|---|---|---|
| Spill cleanup uses age, not ownership | `rebirth/R/zzz.R`, `sweep_old_spill_dirs()` | Another session can delete a managed directory older than seven days even while its owner is alive. |
| Cleanup regression coverage is narrower | `rebirth/tests/testthat/test-llm-trace-spill-session.R` | Current cases prove unique names and RNG neutrality, not live-owner preservation. |
| Sanitizers remain deferred | `.github/workflows/nightly-memory-safety.yaml`, D-019, `rebirth-llm/build.rs` | Valgrind exists; full instrumented Rust/C++ ASan and C++ UBSan execution is not established. |
| Reference consumption is path-based | `.github/workflows/nightly-vision-golden.yaml`, `rebirth-llm/tests/vlm_golden.rs` | The producer verifies inputs, but the consumer/CI receipt identifies the generated dump by filename, not a digest of the consumed bytes. |
| Self-tests are in the default FFI build | `rebirth/src/rust/rebirth-ffi/Cargo.toml` and registration | Isolating them affects wrappers, package checks and distribution; it is a separate follow-up. |

These are source findings, not newly executed runtime tests. A workflow file
does not establish a successful run. The graph index helps locate native spill
code; the current R lifecycle code and workflows are authoritative for this plan.

## A. Preserve live managed spill directories

**First delivery, highest priority.** Replace age-only reclamation with evidence
that the managed directory is not owned by a live session. Keep the seven-day
minimum retention and the existing normal-exit cleanup contract.

Recommended implementation: a native lifetime lease for managed directories on
the supported macOS/Linux hosts, held until cleanup finishes. Use an OS advisory
lock through the existing native bridge; do not add a lock package or shell out
to a process-list utility. Validate its semantics with a short two-process test
before integrating it into the lifecycle. A PID alone, a heartbeat timestamp or
a directory name is not proof of ownership or death.

Required behavior:

- Create ownership state only when a managed spill is actually created. An
  in-memory trace must still leave no session directory and must not alter R RNG.
- Hold the lease across writing, lazy reads and final cleanup. A second session
  must skip a locked directory even if its modification time is older than the
  retention period. Do not add timers or periodic R callbacks.
- Reclaim only an aged directory with a valid managed-format marker and an
  exclusively acquired lease. Keep that lease while checking and deleting.
- Unknown/legacy markers, permission failures, unsupported lock semantics or
  ambiguous ownership mean **retain**, not delete. This can leave old files;
  document that tradeoff. Never automatically migrate/delete legacy directories
  just because they look old.
- Validate the root and candidate identities, reject symlink redirection, and
  refuse a replaced candidate. Two sweepers must not delete unrelated paths or
  interfere with a live owner. Do not recursively follow links outside the
  managed root. No claim of protection from an adversary controlling the account.
- Preserve caller-managed `spill_dir` contents. Normal exit/unload cleanup stays
  idempotent and best-effort, and must release resources on error paths. Preserve
  D-037's native ownership/finalizer rules; do not unmap a DLL with live finalizers.

Acceptance (new cases, not yet implemented):

1. A real child process holds an aged managed directory; a sweep in another
   process leaves both directory and bytes intact. Use a ready/release handshake,
   not a timing guess or a week-long wait.
2. After terminating that child, its valid aged directory is reclaimed; a recent
   orphan remains. Normal exit also removes only the owner's managed directory.
3. Legacy/malformed/missing metadata, permission ambiguity, symlinked roots or
   candidates, replacement and two simultaneous sweepers preserve unrelated
   sentinel files. Permission-sensitive cases must genuinely exercise denial;
   a privileged test process cannot silently pass them.
4. Existing custom-directory uniqueness, RNG, lazy allocation, Arrow readback,
   corruption rejection and memory-budget tests still pass. Add one synthetic
   spill/readback case through the actual installed lifecycle, without a model
   download. No new budget or numerical formula is introduced.

Location: extend `test-llm-trace-spill-session.R` and the relevant native boundary
tests. Run on all four existing R CI legs (macOS/Linux, release/oldrel). Unsupported
platforms must retain uncertain directories; Windows certification remains Phase 8.

## B. Complete the scoped native memory-safety gate

Implement the D-019 follow-up in the existing memory-safety workflow, as a
separate scheduled/manual job. Keep Valgrind; this adds complementary coverage.
It does not make every PR rebuild an instrumented engine.

- Use Linux CPU, the committed synthetic fixture and a pinned compatible
  Rust/Clang toolchain. The normal Rust 1.85.0 floor and package build stay intact.
- Build into a separate empty target/build directory with compiler caches
  disabled. Instrument Rust with ASan and the linked C/C++ engine and native
  bridge with ASan/UBSan. Record exact flags, compilers, runtimes and source hash.
  Validate the toolchain combination before the expensive engine build.
- Prove instrumentation reached the actual compiled objects (build commands and
  runtime linkage), including the patched `build_cvec` path. An environment
  variable or workflow name alone is insufficient evidence.
- Run download-free intervention, trace/spill, generation/embedding and selected
  async ownership/cancellation/destruction cases. Require named executed-test
  markers; an empty filter or early-return skip cannot count as acceptance.
- Fail on sanitizer findings and test failures, retain logs even on failure,
  and use bounded timeouts. Do not add blanket suppressions or retries. Diagnose
  a concrete upstream finding before considering a narrowly documented exception.

Acceptance:

1. Small isolated fault probes demonstrate that the selected ASan runtime catches
   an invalid access and C++ UBSan catches a defined test of undefined behavior;
   the harness also rejects an uninstrumented probe. Fault probes never enter
   the package or vendor tree. Record the expected nonzero outcomes separately
   from successful product tests.
2. The instrumented engine/bridge and selected real test binaries execute all
   required markers with zero unsuppressed sanitizer findings and no test failure.
3. Ordinary package and native CI still pass without sanitizer flags; cache/build
   isolation prevents instrumented archives entering release artifacts.

Scope of the result: native CPU paths exercised by these tests. It is not a
ThreadSanitizer result, a Metal/CUDA certification, a proof of all Rust UB being
detected, or instrumented coverage of R/SEXP marshalling. Normal R boundary
checks remain separate. Compiled but unexecuted vision paths are not tested.

One instrumented native rebuild is necessary here because instrumentation is
the changed behavior. It does not justify rerunning existing large-model or
service stress acceptance. If a toolchain or upstream issue blocks this gate,
record the blocker; do not describe the gate as delivered or expand into a vendor
upgrade without a separate decision.

## C. Bind the vision reference to its actual contents

Keep the existing same-runner pristine build and numerical criteria. Strengthen
the handoff between that producer and the comparison; do not manufacture a new
golden or loosen a tolerance.

- Produce a manifest beside the reference: SHA256 and dimensions of the dump,
  upstream source archive digest/tag, model/projector/image digests, producer
  source/binary digests, build configuration, platform, CI source/run/attempt/job
  and runner identities. Generate a fresh job-local nonce before production and
  require the same nonce at consumption, against independent job state. A rerun
  can reuse the source SHA, run ID and platform on a different machine; those
  identifiers alone do not establish a same-runner reference.
- Use existing CI/Python standard-library tooling for hashing; no new core
  dependency and no hand-written cryptographic implementation.
- Validate the manifest and exact reference bytes consumed by the comparison.
  Prefer a verified in-memory snapshot passed to the test comparator over a
  second unprotected path read. A printed caller-supplied digest is not validation.
  The checked digest must reach the final success receipt.
- Missing or mismatched evidence in the mandatory nightly path fails before a
  numerical pass can be recorded. Keep model-gated local skips explicit; do not
  silently substitute a committed cross-machine reference when the nightly
  producer is absent.
- Preserve the distinction between same-machine generated evidence and historical
  machine-specific pins. A digest binds bytes; it is not a signature, independent
  scientific validation or proof of cross-machine bitwise equality.

Acceptance:

1. Small model-free fixtures pass with a matching manifest and fail with changed
   bytes at the same path, stale dimensions/input identities, missing manifest,
   wrong run identity, prior-attempt evidence at the same SHA/platform, a wrong
   job nonce or a substituted snapshot. Verify failure occurs before success
   markers. Run these fast checks per PR.
2. Dispatch the affected vision nightly once on the final relevant source, on
   both supported runners. Retain actual input/output digests and comparison
   markers. Existing numerical thresholds and required-run assertions remain.
   Reuse verified caches where available; do not download another model family.

## Execution and stop conditions

Work in order A, B, C in one branch. Start each block with its failing regression
or harness control, then implement the smallest correction. Run focused checks
after changes; run the relevant integrated package/native checks once at the
final candidate. Plan one integrated independent correctness review, with
special attention to deletion and instrumentation. Revisit only concrete findings.

Expected executable surfaces: `Rscript` running the focused spill test file;
`cargo test --locked -p rebirth-llm --test synthetic_spill`; the existing fmt,
clippy, native and package CI; new model-free reference-manifest tests; and manual
dispatch of the affected memory-safety and vision workflows. The implementation
report must give the exact final commands, versions, source hashes and results;
these planned surfaces are not reported as tests already run.

Push at a reviewable milestone to enable the two affected remote workflows; use
the existing paused monitor for long runs when implementation begins. No polling
loops, duplicate runs or repeated unchanged updates. One final PR integrates the
three blocks after their acceptance, all nine ordinary checks, and review. Any
later correction reruns affected work, preserving previous failures/source scope.
Do not add a tracked commit merely to record that commit's CI results.

**Definition of done:** A's ownership/readback regressions pass on supported
hosts; B's instrumentation controls and native execution pass; C's corruption
controls and actual same-runner comparisons pass; review has no unresolved
blocking finding; documentation describes actual coverage; final ordinary CI
is green and integration is verified. An unresolved required gate keeps this
package open. Once these conditions hold, stop and proceed to Phase-6 design.

## Deferred work and the next phases

| Item | Placement and reason |
|---|---|
| Non-default `selftest` feature | Separate packaging cleanup after Phase 7, before Phase 9, unless the maintenance implementation demonstrates it is a direct blocker. Requires checking default/release registration, generated wrappers and test-enabled builds together. |
| Unpatched text-logit comparator | Separate numerical-validation follow-up; existing synthetic/HF evidence is retained. A Phase-6 capability needing a missing oracle must add that oracle as its own acceptance prerequisite. |
| 4B spill / long-session trace stress / broader model matrix | Separate resource and model acceptance. Synthetic tests do not close these gates; service stress does not substitute for trace stress. |
| Upstream failed-projector-construction leak | Retain the documented limitation and a bounded reproduction before any vendor work; do not mix an engine upgrade into this package. |
| I1 graphics portability and broader client coverage | Companion follow-up; preserve current Mac/client/scope limitations. No universal activation or marketplace claim. |
| Windows/CUDA | Phase 8, on suitable hardware. |
| Rust crate vendoring, CRAN warnings, docs/API freeze | Phase 9. Much of the preparation can run on the existing Mac; platform certification is separate. |

After maintenance, Phase 6 starts with a concrete API/ownership proposal for
selected activations and logit summaries during generation, bounded streaming
traces and callback-driven cancellation/steering. WP10's current `on_token`
contract must not be silently repurposed. A guardrail demonstration remains a
research mechanism, not a safety or detection guarantee. Phase 7 then addresses
type contracts/compile feasibility and generic typed serving; WP12a/b already
deliver the narrower local service and are not repeated.

## Planning verification

At this revision only repository sources, settled decisions, integration receipts
and documentation were inspected. One focused independent review identified the
need to distinguish a fresh runner from an earlier attempt at the same source;
the job nonce and prior-attempt negative fixture above address that finding.
No runtime change, sanitizer build, model call,
nightly dispatch or new acceptance result is claimed. Implementation evidence
will be recorded separately. No API/dependency decision is requested by this
plan; any necessary departure must be made concrete before asking the founder.
