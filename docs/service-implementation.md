# WP12b — Local service implementation and acceptance

Date: 2026-09-28. **Implementation in progress; runtime acceptance not yet established.**
D-034 approved; WP12a PR #50 merged at `95066c7` with all nine checks passing.
The [frozen contract](service-contract.md) remains binding. No relm export or
core dependency changes are part of this work.

**Acceptance (verbatim, execution plan):** Normal load, overload, failed requests
and forced worker exit meet the WP12a limits. Run the selected path for 1,000
cycles and report memory growth and recovery. Validate Mac and declared Linux
CPU deployment.

The application is in `examples/funding-service/`. It reuses D2's literal JSON,
prompt/schema, output validation and persistence primitives. Dependency
preparation is explicit; execution uses a fingerprinted separate library and an
existing checksummed model. The personal R library is unchanged.

## Evidence ledger

| Check | Current evidence |
|---|---|
| Exact application pins | All 23 approved versions installed in an isolated library; principal namespaces load on Mac R 4.5.1 |
| Offline contract consistency | 23 pins, three D2 inputs, JSON overflow bounds and 11 negative mutations pass |
| Environment/operator boundary checks | 11 fresh-process cases pass on Mac: modified/missing packages, foreign environment/model/source identities, changed prompt and supervisor argument escaping; no model loaded |
| D2 helper regression | 466 existing process/canonical/identity assertions pass after correcting source-file provenance for nested imports |
| G1–G4 actual HTTP/process/persistence | G1 HTTP and G2 concurrent admission pass locally; the retained combined run is explicitly partial because a later harness assertion failed. Standalone G3 passes in 199.94 s including the unchanged 120 s deadline. G4 passes all 64 checks, including all four rename crash boundaries, corruption/ownership refusal, overflow and bounded storage. Zombie-stop regression fixed without changing process-identity checks |
| Offline isolation mechanism | Mac loopback-only sandbox allows local roundtrip and rejects direct non-loopback TCP with EPERM; native G6 execution separate |
| G5 native isolation | Mac Qwen Metal: 53 checks pass in 62.90 s, including A/B/A, validator/context failures, hard worker restart and independent worker comparison; peak measured process-tree RSS 1.06 GiB. Linux Qwen CPU also passes all53checks in197.78s |
| G6 native operating envelope | Mac Qwen Metal passes: 30 ordinary requests, explicit worker crash/reload, normal stop and actual offline OS boundary; 286 checks in 122.02 s, peak process-tree RSS 1.05 GiB. Spark Metal also passes all 286 checks in 350.86 s (30 ordinary requests plus crash/recovery), peak RSS 4.97 GiB against the 8 GiB bound; Linux pending |
| G7 1,000 native Qwen requests on each Mac/Linux | First Mac run failed after106 committed results: request107 remained unresolved and the service faulted below its RSS/storage limits. Report retained; concurrent IPC stat/disappearance race reproduced and fixed; nine focused regressions plus independent review pass, native rerun active after a passing1,000-request deterministic HTTP/callr regression. Linux stress not yet run |
| G8 actual launchd/systemd user lifecycle | Mac launchd passes all 27 checks: real crash/restart, stop, unrelated/PID-reuse refusal, occupied-port and changed-config failures with actual HTTP readiness probes and measured restart intervals. Linux systemd pending |
| Independent integrated review | Complete with no unresolved P1/P2 findings; focused confirmation also passed for the zombie-stop fix. Runtime acceptance remains separate |

Retained local receipts and native request timings are in
[`tests/funding-service/measurements/macos-metal-2026-09-28/`](../tests/funding-service/measurements/macos-metal-2026-09-28/).
Detailed transient process/RSS logs remain in the recorded local evidence directories;
Linux workflow artifacts retain the corresponding full reports.

The existing four Mac/Linux R CI legs will run model-free HTTP/process gates.
A separate manually dispatched Linux workflow runs the native, supervisor and
stress gates; it does not run on every PR. Local Mac runs use the existing
Spark and Qwen models. Missing required hardware/managers leave a gate
unexecuted rather than passing by skip.

Approval, source inspection, parsable configuration and successful startup are
not substitutes for the declared operating tests. Resource limits and numerical
thresholds have not been relaxed. Extraction quality is not promoted by
operational acceptance; D1's negative result and deferred stronger-model
comparison remain unchanged.

## Development failures retained

Initial execution exposed a zombie-stop lifecycle bug, corrected by distinguishing
terminated processes from live owners while retaining PID/birth matching. The
independent review confirmed the narrow fix. Early harness runs also exposed an
invalid process API, an Rscript source-edit race and a fixture-output shape
assertion mismatch. Those runs remain failed; the saved HTTP/admission report
contains only the separately passed G1/G2 gates, with its later failure intact.
Native G5/G6 passed with frozen sampler source. A later teardown inspection race was
corrected with a bounded recheck that permits only confirmed death/PID reuse; an
actual-process guard proves persistent live-process inspection denial still fails.
G4 also corrected a test assertion to measure durable storage separately from
the explicitly separate 64 MiB IPC budget. These are operational checks,
not evidence of improved extraction accuracy.

Linux run `36449874945` passed environment boundaries and native G5, then
failed before G6 startup because the offline guard enumerated the host-mounted
sysfs interface view. The guard now uses `socket.if_nameindex()` to inspect the
calling network namespace; namespace identity, actual external-socket denial and
loopback roundtrip remain mandatory. This is a harness correction; Linux G6–G8
remain pending until a successful actual run.

A separate explicit restart using an isolated copy of the original `69e986e`
service source recovered admission107 as `interrupted`, with zero new dispatches
and byte-identical hashes for all106 earlier results. The first G7 remains failed;
its store now contains that separately recorded recovery, not a repaired stress
pass. The recovery service was stopped after the check.

The scanner fix is limited to confirmed disappearance in a live owned IPC tree.
Durable record scans still fail on missing/stat errors, and file/directory symlinks
are refused. Nine independently written base-R regressions pass; a focused review
found no unresolved material issue. Fault status now exposes bounded reason/class
values without raw condition text.

After the IPC fix, G3 passes97checks including the unchanged120-second deadline,
and G4 passes64checks. A separate1,000-request deterministic HTTP/callr sequence
also passes without replacing the worker; its private10ms fixture polling makes
it a transport regression, not nativeG7 or a throughput claim. The two Mac CI
legs previously reached an arbitrary30-second harness wait before completing the
three startup-failure attempts; the harness now uses the frozen300-second restart
window and still requires actual faulted/non-ready state and all three failures.
Both Linux model-free CI legs passed on the first candidate.
