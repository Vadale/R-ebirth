# WP12b — Local service implementation and acceptance

Date: 2026-09-29. **Final acceptance pending; Linux observer-priority diagnosis next.**
D-034 approved; WP12a PR #50 merged at `95066c7`. The
[frozen contract](service-contract.md) remains binding. Draft
[PR #51](https://github.com/Vadale/R-ebirth/pull/51) contains the application and
acceptance tooling. No relm export or core dependency changes are included.

**Acceptance (verbatim, execution plan):** Normal load, overload, failed requests
and forced worker exit meet the WP12a limits. Run the selected path for 1,000
cycles and report memory growth and recovery. Validate Mac and declared Linux
CPU deployment.

## Delivered behavior

The application in [`examples/funding-service/`](../examples/funding-service/)
turns D2's fixed funding extraction workflow into a local HTTP service. One
persistent callr model worker handles one active request; there is no accepted
job queue. Admission creates a durable ticket before returning HTTP 202, and
clients retrieve an immutable terminal result. Repeated IDs replay the existing
result or report a conflict; overload is rejected explicitly.

Setup snapshots the exact 23 approved application package versions in a separate
library and fingerprints packages, source, configuration, prompt/schema and the
existing model. The personal R library is unchanged. Operator commands cover
setup, start, status, stop and recovery; generated launchd/systemd user definitions
use those same commands. Ownership uses process creation identities and nonces.
A failed worker is confirmed dead before replacement; interrupted admissions
remain accounted for. Output, diagnostics, IPC, storage and process RSS are
bounded under the contract.

## Evidence for the current candidate

The final product correction is commit `a8a6ab3`, with runtime SHA256
`8e458534ccf171e4fa3ed85dab51743a5c821c47526aa634e116ca20ae973ed3`.
Parent candidate `721dbd4` passed all nine ordinary PR checks; its runtime digest
is `e87bce0f36defbcd6ff992abc4b184740a827148a83d232828c3032dfc6cc8f7`.
The final candidate `30ca035` also passes all nine ordinary PR checks. Each receipt records
source digests; earlier measurements are not relabelled as final-source runs.
The narrowly carried-forward G7 scope is explained below.

| Gate or prerequisite | Evidence and remaining work |
|---|---|
| Exact environment and operator boundaries | All 23 approved pins installed; 11 fresh-process cases pass on Mac and Linux, including changed packages, model/source identity and supervisor argument escaping. No model needed for these checks. |
| Offline contract consistency | 23 pins, three D2 development inputs, overflow bounds and 11 negative mutations pass. |
| D2 helper regression | 466 existing process/canonical/identity assertions pass after correcting source-file provenance for nested imports. |
| G1–G4 HTTP, admission, recovery and persistence | Final candidate passes 305 checks on each of four Mac/Linux R-release/oldrel CI environments, plus nine focused process-inspection regressions per environment. This includes the unchanged 120-second request deadline, concurrent overload, worker/frontend death, rename crash boundaries, ownership/corruption refusal and bounded storage. Local final-source G3 also passes 97 checks. Final CI executes all G1–G4 gates. |
| G5 native request isolation | Mac Qwen Metal passes 53 checks on the current runtime, including A/B/A, validation/context failure recovery, hard restart and an independent worker baseline. Linux CPU also passes 53 checks on the final product runtime (run 36490558522). |
| G6 native operating envelope | Final Mac runtime passes 286 checks each for Qwen and Spark: 30 ordinary requests, actual offline OS isolation, worker crash/reload and stop, including the previously failed replacement. Linux CPU final-runtime run 36490558522 also passes all 286 checks. |
| G7 same-worker memory stress | Mac Metal parent-candidate run passes all 1,000 unique native Qwen requests: same worker, zero infrastructure errors, 1.062 GiB peak RSS, -39.625 MiB tail-minus-initial growth and -83.461 KiB/request post-warmup slope. Linux CPU completed 1,000 requests but failed the continuous-sampling guard; the latest corrected run stopped at 86 completed requests on a 204 ms sampling gap; a bounded timing diagnosis precedes any further native attempt. A separate 1,000-request deterministic HTTP/callr regression passed; it does not substitute for either native gate. |
| G8 actual service-manager lifecycle | Final Mac runtime passes 27 launchd checks, including actual HTTP readiness, crash/restart, stop, ownership/PID-reuse refusal, occupied-port and changed-config failures with observed restart intervals. Linux final-runtime systemd run 36490558522 passes 24 checks. |
| Independent review | Integrated correctness/security review complete with no unresolved material finding. Narrow confirmations cover the zombie-stop lifecycle fix and the live IPC scanner race. |

The model-free reports are retained in
[`measurements/ci-2026-09-28/final/`](../tests/funding-service/measurements/ci-2026-09-28/final/)
and the [final R matrix workflow](https://github.com/Vadale/R-ebirth/actions/runs/36463177499).
The failed Linux native execution is
[run 36453135678](https://github.com/Vadale/R-ebirth/actions/runs/36453135678).
Mac receipts and per-request native timings are in
[`measurements/macos-metal-2026-09-28/`](../tests/funding-service/measurements/macos-metal-2026-09-28/).
Compact receipts retain counts, failures, source identity and the SHA256/location
of the original full report. Full process/RSS logs remain in the recorded local
run directories or workflow artifacts.

The complete Mac G7 ran for 3,832.26 seconds and passed 9,015 assertions. Its
1,000-row CSV independently reproduces the memory growth and slope in base R.
All requests received terminal records: 334 `success`, 666 `invalid`, zero
`error` and zero `interrupted`. Validator rejection is an accounted application
outcome, not evidence of successful extraction.

The final Mac G6 peak process-tree RSS was 1.05 GiB for Qwen and 4.97 GiB for
Spark, below their respective 3 GiB and 8 GiB bounds. These are sampled host
process measurements, not complete Metal device-allocation measurements. They
do not establish a safe tier for larger models. G7 memory growth is reported
separately and still requires a successful Linux G7 run.

## Failures and retained evidence


Run `36490558522` confirms the child-discovery correction: the Linux regression
reproduces the original error, then passes the adapter; G5=53, G6=286 and actual
systemd G8=24 pass on the final product runtime. All nine ordinary checks at
`8c57b85` also pass. G7 remains **failed**: a 204 ms sample interval at elapsed
1,474.733 seconds triggered the unchanged 200 ms guard. The harness stopped after
86 completed requests (request 87 had been admitted), preserving the partial
CSV; there was no sampler crash or cleanup error. The first sampling error is
now retained so expected shutdown disappearance cannot overwrite its diagnosis.

Repeated slower samples are consistent with garbage collection or scheduler
contention, but the existing RSS CSV cannot distinguish those causes. Instead
of another multi-hour native retry, an explicit, model-free Linux diagnostic
runs for at most 30 minutes under four controlled CPU-busy threads. It retains
per-phase wall/CPU time, GC deltas, wake lateness and available cgroup CPU
throttling/pressure counters. Full process discovery and the 100 ms target /
200 ms failure guard remain unchanged. Instrumentation is opt-in and its own
write cost remains visible in the following interval. This diagnostic installs
only the already-approved `ps` and `jsonlite` pins, downloads no model, and does
not build relm or certify any G1–G8 gate. Its completion can mean that a sampling
failure was reproduced; only the diagnostic report describes the outcome.


[Diagnostic run 36496677960](https://github.com/Vadale/R-ebirth/actions/runs/36496677960)
completed successfully as an evidence-collection job, with **`sampling_failed`**
in its report after 142.34 seconds. Its 1,420 RSS/timing rows reproduce one exact
204 ms gap at sample 1419. That iteration began without wake lateness, spent
127 ms wall / 63 ms CPU in discovery, and recorded 98 ms elapsed / 49 ms CPU in
R garbage collection. Iteration totals were 128 ms wall / 64 ms CPU. All observed
cgroup levels remained unthrottled; configured CPU quotas were unlimited, with
CPU pressure under four busy threads on four cores. This supports testing whether
observer scheduling contention amplifies GC pauses in this reproduction. It does
not prove the cause of earlier uninstrumented native failures. Original reports,
compressed raw CSVs and an independently computed gap analysis are retained in
[`timing-diagnostic/`](../tests/funding-service/measurements/linux-cpu-2026-09-28/timing-diagnostic/).
All nine ordinary checks at `5a12533` also pass; their four 305-check R receipts
are retained under `ci-2026-09-28/timing-diagnostic/`.

The next controlled experiment changes only the diagnostic observer's Linux
nice value to -10; its controller and four-thread workload must remain at 0.
A separate unprivileged child launcher records PID, UID, requested/actual priority
and inherited limit before exec; inability to apply the requested value fails
closed. The disposable runner step grants its shell an inherited `RLIMIT_NICE`
ceiling of 30 via `prlimit`; only the observer launcher changes actual priority.
[Linux documents the ceiling as 20 minus the soft limit](https://man7.org/linux/man-pages/man2/getrlimit.2.html),
so 30 permits -10. Neither R nor the workload runs as root. Full discovery,
100 ms sampling, the 200 ms guard and all resource bounds remain unchanged.
Higher observer priority may affect workload throughput; that measurement
condition must be explicit in any future native receipts. Priority is currently
wired **only into the diagnostic job**, pending evidence; no native retry is
justified yet. Eight focused Python regressions and a four-second actual R
launcher smoke pass (40 RSS/timing rows, default priority unchanged). The smoke
receipt retains the source hashes tested before the metadata-error guard.
A focused review identified two boundaries to cover before any future native
integration: preserve the explicit request through `offline.py`'s sudo environment,
and inspect manager-owned frontend identity via status rather than a Popen handle.



The corrected-sampler run `36487549704` passed G5 and all 30 ordinary G6
requests plus controlled worker recovery, but failed G6 with a sampler discovery
error (281 assertions passed; cleanup failed). G7 was **not executed**. All nine
ordinary CI checks at `313b2dc` passed, including the sampler regressions; their
receipts and this failed native run are retained under `sampler-corrected/` in
the respective measurement directories.

Inspection of the exact approved [ps 1.9.3 source](https://cran.r-project.org/src/contrib/ps_1.9.3.tar.gz)
identified a different termination race: Linux `ps_handle()` can raise generic
`os_error`/ENOENT if a selected child exits after the PPID snapshot. Upstream
`ps_children()` catches only `no_such_process`/`zombie_process` at that point.
The earlier parent-death guard cannot classify a child error while its parent
remains alive. The harness now adapts only the child-handle lookup in a local
copy of the pinned public function; it does not modify the package namespace.
Only independently confirmed absence/death is converted to a typed disappearance,
which still marks that sample missing. Live or unknown denials propagate. Normal
handle creation remains unchanged. This does not establish atomic ownership
across upstream's PID-only snapshot; known sampled handles retain birth checks.

A deterministic regression captures the actual PPID map, kills and reaps a mapped
child, and supplies that stale map to both original and adapted discovery. Linux
CI must reproduce the original `os_error` and accept only the marked missing
child through the adapter; an injected denial on a live child must still fail.
The regression passes on Mac and in Linux run `36490558522`; Linux G7 remains
unaccepted. No service source, resource bound or sampling criterion was changed.



Linux run `36453135678` completed all 1,000 native requests with the same worker:
334 `success`, 666 `invalid`, zero infrastructure errors or interruptions. Its
G7 is **failed**, because the RSS sampler recorded 16 intervals above 200 ms
(maximum 216 ms) among 155,593 observations. A separate discovery error occurred
during shutdown. G5, G6 and actual systemd G8 passed (53, 286 and 24 checks).
Receipts, the failed 1,000-row CSV and gap diagnostics are retained in
[`measurements/linux-cpu-2026-09-28/`](../tests/funding-service/measurements/linux-cpu-2026-09-28/).
Base R independently confirms the same worker and observed +28,377,088-byte
growth / +38,490.2-byte-per-request slope; those observations do not certify G7
with incomplete sampling.

The harness repeatedly parsed the entire growing RSS history to obtain one fresh
row (48 MB at the end), adding unnecessary load. It now reads only the last
complete CSV row, preserves each completed request incrementally and aborts
stress before another HTTP call once a sampling error is recorded. The sampler
uses lighter CSV serialization and confirms the original parent's death/reuse
when tree discovery races shutdown; live or unknown inspection failures remain
errors. Regression checks cover partial/quoted rows, bounded read cost, fresh
observations, immediate failure, process identity and serialization equivalence.
The 100 ms target, 200 ms missing-period guard, request count and all resource
thresholds are unchanged. Product runtime source is unchanged. Reports now also
fingerprint the three harness source files. Six Python sampler regressions, the
R identity/encoding self-test, existing dead/stalled guards and 100 actual local
G1 HTTP/process checks pass; focused independent review found no blocking issue.
The removed overhead is a plausible contributor to the missed intervals, not a
proven sole cause. Only the new Linux run can establish acceptance.


The final Mac G6 confirmation (`mac-final-qwen-native`) failed after the
controlled worker exit: all 31 admissions had terminal records, but the service
remained faulted with `funding_error_ownership` and did not become ready within
125 seconds. Its failed receipt is preserved separately. Independent tests reproduce ownership
errors in both RSS and status inspection just before process death becomes
observable; the historical receipt cannot distinguish those branches. A shared
helper now allows at most two 50 ms waits, retaining the original process handle
and accepting only confirmed termination. Live or unknown denial remains an
error. All nine focused regressions pass, including actual child death and stale
creation-time identity; both delayed-death cases fail against the original source.
Independent review found no material issue. Final-source G3 passes 97 checks and
Qwen G6 passes all 286, including crash/replacement.

The final runtime SHA256 is
`8e458534ccf171e4fa3ed85dab51743a5c821c47526aa634e116ca20ae973ed3`.
The only changes from `e87bce0f` are this helper and its use in two existing
inspection-error branches. Successful status/RSS reads, generation, IPC,
persistence, sampling cadence and limits are unchanged. G7 receipts retain their
original source identity and support that unchanged ordinary-request path;
final-source fault and native lifecycle tests separately validate the correction.
No earlier failed run is converted to a pass.

The first native Mac G7 failed after 106 committed results: request 107 remained
unresolved when the service faulted. A worker temporary file disappeared between
IPC enumeration and stat; the scanner mistakenly treated this expected live-file
race as a durable filesystem failure. The corrected scanner allows only confirmed
disappearance in the owned live IPC tree. Durable record scans still fail on
missing/stat errors; file/directory symlinks and unverifiable access remain
errors. Nine focused base-R regressions and an independent review confirm this
boundary. Status exposes bounded fault reason/class values without raw condition
text.

That failed G7 remains failed. A separate explicit restart using the original
`69e986e` source recovered request 107 as `interrupted`, made zero new dispatches
and preserved all 106 earlier result hashes. Its service was then stopped. The
new native runs start fresh and retain the full 1,000-request denominator.
The passing deterministic sequence uses private 10 ms fixture controls; it is a
transport regression, not native acceptance or a production throughput claim.

Earlier execution also found a zombie-stop bug, fixed by distinguishing terminated
processes from live owners while retaining PID/birth checks. Harness corrections
addressed an invalid process API, an Rscript source-edit race, a fixture shape
assertion, sampler teardown inspection and a quota assertion that incorrectly
included the separately budgeted IPC directory. Their original failed reports
remain failed; only explicitly completed gates are cited as passed.

Linux run `36449874945` passed setup and G5, then failed the G6 offline preflight:
its sysfs mount described the host's interfaces instead of the calling network
namespace. The guard now uses `socket.if_nameindex()` and still requires a changed
namespace, actual external-socket denial and a successful loopback roundtrip.
Both Mac legs of the first PR matrix also exceeded a harness-only 30-second wait
for three startup failures. The test now uses the frozen 300-second restart
window and still requires all three failures and faulted/non-ready status. The
corrected candidate passes all four model-free CI legs. No product resource
limit, request deadline or numerical threshold was relaxed.

## Scope and completion boundary

The four ordinary R CI legs execute model-free HTTP/process gates. Native Linux
acceptance runs only in the explicitly dispatched workflow, including real
systemd and the 1,000-request workload. Mac uses the existing Qwen and Spark
models; no additional model download is needed. A missing required manager or
hardware leaves a gate unexecuted and exits nonzero.

All required local Mac checks have passed. WP12b remains unaccepted until the
corrected Linux G7 run passes and its receipts are collected. All nine
ordinary checks pass on the final product source. Source inspection, successful startup and a
passing fixture suite do not substitute for them. Operational acceptance does
not promote extraction quality: D1's negative result and the deferred
stronger-model comparison remain unchanged. Windows/CUDA and the broader
trace/generate stress obligations remain outside this service acceptance.
