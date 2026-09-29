# WP12b — Local service implementation and acceptance

Date: 2026-09-29. **Operational acceptance complete; final PR checks and integration pending.**
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

The earlier product correction at `a8a6ab3` has runtime SHA256
`8e458534ccf171e4fa3ed85dab51743a5c821c47526aa634e116ca20ae973ed3`.
Parent candidate `721dbd4` passed all nine ordinary PR checks; its runtime digest
is `e87bce0f36defbcd6ff992abc4b184740a827148a83d232828c3032dfc6cc8f7`.
Candidate `30ca035` also passed all nine ordinary PR checks. Each receipt records
source digests; earlier measurements are not relabelled as final-source runs.
The latest Linux ownership correction has runtime SHA256
`fc539b55cc6b20f0d0af0ce79d4f68716a3b79efaad8adc4c070429e3236b4a0`;
its nine ordinary CI checks and Linux native lifecycle confirmation pass.
The reviewed parent-source G7 carry-forward scope is explained below.

| Gate or prerequisite | Evidence and remaining work |
|---|---|
| Exact environment and operator boundaries | All 23 approved pins installed; 11 fresh-process cases pass on Mac and Linux, including changed packages, model/source identity and supervisor argument escaping. No model needed for these checks. |
| Offline contract consistency | 23 pins, three D2 development inputs, overflow bounds and 11 negative mutations pass. |
| D2 helper regression | 466 existing process/canonical/identity assertions pass after correcting source-file provenance for nested imports. |
| G1–G4 HTTP, admission, recovery and persistence | Earlier candidates passed 305 checks in each of four Mac/Linux R-release/oldrel environments, including deadline, overload, death/recovery, persistence and ownership controls. At `74cc156` Linux oldrel passed all assertions but failed cleanup, so its overall result failed. Current-source CI at `7c9505a` passes all nine checks, including the four 305-assertion suites and 12 Mac/13 Linux process regressions. Earlier local G3 passed 97 checks. |
| G5 native request isolation | Mac Qwen Metal passes 53 checks on runtime `8e458534`, including A/B/A, validation/context failure recovery, hard restart and an independent worker baseline. Linux CPU also passes 53 checks on that runtime (run 36490558522). Current-source Linux run `36524582952` also passes this gate without cleanup errors. |
| G6 native operating envelope | Mac runtime `8e458534` passes 286 checks each for Qwen and Spark: 30 ordinary requests, actual offline OS isolation, worker crash/reload and stop. Linux CPU run 36490558522 also passes all 286 on that runtime. Current-source Linux run `36524582952` also passes this gate without cleanup errors. |
| G7 same-worker memory stress | Mac Metal parent-source run passes 1,000 unique Qwen requests with one worker and zero infrastructure errors. Linux parent-source `74cc156` run 36506438374 also passes 1,000 unique requests: 334 success, 666 invalid, zero infrastructure errors; peak RSS 1,518,149,632 bytes, growth 28,315,648 bytes and slope 39,993.854184 bytes/request. Independent verification confirms 116,194 consecutive samples and maximum gap 186 ms. Preserve the separately explained post-measurement teardown marker and original source; current-source G7 was not rerun. |
| G8 actual service-manager lifecycle | Mac runtime `8e458534` passes 27 launchd checks, including actual HTTP readiness, crash/restart, stop, ownership/PID-reuse refusal, occupied-port and changed-config failures with observed restart intervals. Linux systemd run 36490558522 passes 24 checks on that runtime. Current-source Linux run `36524582952` also passes this gate without cleanup errors. |
| Independent review | Integrated correctness/security review complete with no unresolved material finding. Focused confirmations cover lifecycle/ownership fixes, the live IPC scanner race, observer scheduling and parent-source G7 provenance, including its post-measurement teardown marker. |

The model-free reports are retained in
[`measurements/ci-2026-09-28/final/`](../tests/funding-service/measurements/ci-2026-09-28/final/)
and the [earlier R matrix workflow](https://github.com/Vadale/R-ebirth/actions/runs/36463177499).
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
separately; the successful Linux G7 result and source scope are recorded below.

## Failures and retained evidence


Native run `36506438374` at `74cc156` passed both preflight evaluation and all
G5/G6/G8/G7 gates. Its 1,000 unique requests have one worker creation identity and
epoch, with 334 validator successes, 666 invalid records and zero infrastructure
errors. Independent base-R regression reproduces 28,315,648-byte median growth
and 39,993.854184-byte/request slope; peak RSS is 1,518,149,632 bytes. All remain
below the unchanged limits. An independent raw-stream scan and focused review
confirm 116,194 consecutive samples with maximum gap 186 ms and no worker-identity
break during the workload. [Receipts, lossless streams and verification](../tests/funding-service/measurements/linux-cpu-2026-09-28/observer-priority-bootstrap/)
retain exact parent source and harness hashes.

The raw `rss.error` records a process disappearance during teardown and is kept.
The exact harness checks marker absence after all 1,000 terminal records and fresh
post-request samples, before closing the service; its observer stops afterward.
Only row 116193 marks the frontend not alive, after worker removal at 116192.
First-error preservation rules out a prior marker being overwritten. The marker
has no timestamp; this scope rests on control-flow ordering and raw terminal rows,
independently reviewed, not the workflow's green status alone. It does not invalidate
the completed measurement interval. Do not claim no sampler errors anywhere.

The same runner reproduced old-bootstrap permission denial at RLIMIT_NICE `[0,0]`
and passed the corrected `[30,30]` bootstrap, with unprivileged observer nice -10
and workload/controller 0. Earlier preflight failure still lacks direct causal proof.
All nine ordinary checks at `7c9505a` pass, including four 305-assertion HTTP/control
runs; [their receipts](../tests/funding-service/measurements/ci-2026-09-28/owner-identity/)
remain separate from the historical failure below. Current-source Linux native
lifecycle [run 36524582952](https://github.com/Vadale/R-ebirth/actions/runs/36524582952)
passed G5=53, G6=286 and G8=24 assertions without cleanup errors. Exact runtime
and all recorded source/harness hashes match `7c9505a`; preflights, environment,
unprivileged observer scheduling and normal workload priorities also pass.
[Separate lifecycle receipts](../tests/funding-service/measurements/linux-cpu-2026-09-28/owner-lifecycle/)
include `scope.json` and independent source verification. Current-source G7 is
explicitly unexecuted; it retains the reviewed parent-source evidence above.

R CI `36506421298` at `74cc156` failed only in the Linux oldrel leg: all 305
G1–G4 assertions passed, but final cleanup exceeded the unchanged 15-second
frontend-stop bound. The admission fixture's status stayed ready, its lock owner
survived and the sampler observed it alive until forced cleanup. No stop request
was retained and the operator command did not report an error. The stop command's
identity observations were not recorded, so the precise cause remains inferred.
The failed overall receipt, passing assertions and bounded process evidence are
retained in [`bootstrap-candidate/`](../tests/funding-service/measurements/ci-2026-09-28/bootstrap-candidate/).
The other three R legs and all Rust checks passed; this is not a green CI result.

Inspection found a real cross-process identity defect: `svc_alive()` compared
freshly formatted absolute creation times with exact six-decimal string equality.
The pinned [ps 1.9.3 source](https://cran.r-project.org/src/contrib/ps_1.9.3.tar.gz),
`src/api-linux.c:287–350`, caches a separately measured realtime-minus-monotonic
boot offset in each R process. Its supported persisted handles verify process
identity using native clock resolution, not equality of those absolute strings.
The failed stop is consistent with premature classification of both owned
processes as absent, but that particular timestamp mismatch is not directly proven.

On Linux the adapter now retains the fresh-handle access check, reconstructs a
handle from the saved creation time, and delegates identity/liveness to `ps`.
Keeping the first read matters: supplying a time bypasses the initial stat read,
so replacing it outright could misclassify an unreadable live process. Unknown
access still raises the ownership condition. Host, nonce, durable ownership and
PID-reuse guards remain; no new numeric tolerance is invented. Identity guarantees
are bounded by the pinned library's native clock resolution. Mac retains its
existing comparison. Cleanup errors now identify the affected service.

The regression suite includes real persisted identity and wrong-birth checks,
live read-denial refusal, a separate R reader of a live process's saved identity,
and a Linux-only 2-microsecond reader-offset fixture using actual `ps` handles.
That fixture makes the old string comparator reject a handle that `ps` identifies
as live. Twelve applicable Mac process regressions and nine Python checks pass;
Linux passed 13 process cases, including the offset fixture, in ordinary CI.
The new runtime SHA256 is `fc539b55cc6b20f0d0af0ce79d4f68716a3b79efaad8adc4c070429e3236b4a0`.
No core engine, dependency or resource bound changes. Final-source Linux control
and lifecycle validation now pass. Parent G7 source and all failed results remain
explicit in the combined acceptance record.

Focused review confirms that `svc_alive()` participates in startup, ownership,
recovery and operator controls; the successful steady request/status/RSS path
does not call it. The completed G7 has one worker and epoch, so its evidence
supports that unchanged path with original source/harness hashes and the passing
current-source Linux G5/G6/G8 and ordinary controls. Mac keeps its existing identity
branch and accepted parent-source evidence. This reviewed carry-forward does not
claim that the latest source ran G7.

An explicit `service_lifecycle_only=true` dispatch mode retains native preparation,
preflight, G5/G6/G8 and ownership regressions while skipping G7. It writes
`scope.json` with G7 marked unexecuted and requires separately reviewed G7 evidence;
individual receipts remain authoritative for outcomes. Full acceptance remains
the default. The final-source lifecycle-only run passed after parent G7 and
current ordinary CI; its explicitly partial receipt is combined with those results.


Run `36490558522` confirms the child-discovery correction: the Linux regression
reproduces the original error, then passes the adapter; G5=53, G6=286 and actual
systemd G8=24 pass on runtime `8e458534`. All nine ordinary checks at
`8c57b85` also pass. That run's G7 remains **failed**: a 204 ms sample interval at elapsed
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

The controlled priority experiment changed only the diagnostic observer's Linux
nice value to -10; its controller and four-thread workload remained at 0.
A separate unprivileged child launcher records PID, UID, requested/actual priority
and inherited limit before exec; inability to apply the requested value fails
closed. The disposable runner step grants its shell an inherited `RLIMIT_NICE`
ceiling of 30 via `prlimit`; only the observer launcher changes actual priority.
[Linux documents the ceiling as 20 minus the soft limit](https://man7.org/linux/man-pages/man2/getrlimit.2.html),
so 30 permits -10. Neither R nor the workload runs as root. Full discovery,
100 ms sampling, the 200 ms guard and all resource bounds remain unchanged.
Higher observer priority may affect workload throughput; that measurement
condition is explicit in the native receipt format. Initial validation included
eight Python regressions and a four-second R launcher smoke at default priority;
that smoke retains the exact source hashes tested before the metadata-error guard.

[Priority diagnostic 36499565142](https://github.com/Vadale/R-ebirth/actions/runs/36499565142)
completed all 1,800 seconds without reproducing a gap: 17,998 matching sequential
RSS/timing rows, maximum interval **169 ms**, maximum GC elapsed 66 ms and GC CPU
63 ms. Observer UID/EUID were 1001, actual/requested nice -10; controller and
workload remained at 0. No observed cgroup throttling occurred. Compressed raw
measurements and independent exact-decimal analysis are in
[`priority-diagnostic/`](../tests/funding-service/measurements/linux-cpu-2026-09-28/priority-diagnostic/).
The two diagnostics used different runners, so this is supporting operational
evidence, not a same-host causal A/B experiment or a guarantee against future
gaps. It justifies native validation; **it does not pass G7**. All nine ordinary
checks at `3cd463b` pass, with four 305-check R receipts retained.

Native acceptance now uses the same launcher, records source hashes and observer
metadata, and verifies normal harness/frontend/worker priority against current
service process identities. Supervisor-owned frontends use status identity rather
than a Popen handle; priority assertions also cover recovered workers. The real
G6 sudo/network-namespace boundary preserves the explicit priority request.
Before any native build or model download, Linux runs `test_priority.py` through
that actual boundary to prove unprivileged nice -10, unchanged controller priority,
and refusal to execute when the inherited permission is removed. A failed preflight
stops the workflow. The first execution stopped at this preflight (see below); local validation
passes nine focused Python regressions (including supervisor readiness, unexpected
workload priority and stale identity refusal) and 100 actual HTTP/process checks
using the new launcher at the Mac's unchanged default priority. Neither product
code, process discovery, request denominator nor acceptance bounds change.

[Native dispatch 36504143336](https://github.com/Vadale/R-ebirth/actions/runs/36504143336)
failed in the short priority preflight. **No native build, model preparation or
G5–G8 workload ran.** The offline namespace passed its loopback and outside-access
denial checks, and the explicit priority request and normal unprivileged controller
checks passed. The observer launcher exited with status 1 before writing metadata.
The original preflight discarded its child stderr and did not record the inherited
nice limit, so the precise cause is not established by this receipt. The failed
report and skipped workflow steps are retained under
[`observer-priority-preflight-failed/`](../tests/funding-service/measurements/linux-cpu-2026-09-28/observer-priority-preflight-failed/).
All nine ordinary checks at `6aa1c14` pass, including all four 305-check R legs.

The old bootstrap assumed that the outer shell's resource ceiling survived sudo.
[Upstream sudo documents target-user resource-limit initialization, usually via PAM on Linux](https://github.com/sudo-project/sudo/blob/main/docs/sudoers.man.in).
The corrected bootstrap establishes the same fixed `RLIMIT_NICE=30:30` **after**
that boundary and before dropping root privileges with `setpriv`. It does not
change actual workload priority. The new preflight compares the original and
corrected bootstrap on the same runner, retains inherited limits and full child
stdout/stderr, and distinguishes a reproduced permission denial from an original
path that retains permission. Any different error stops the workflow. Only the
corrected positive/denied-permission checks can allow native work to begin.
Both successful native workflows reproduce permission denial on the original
bootstrap and pass the corrected bootstrap. The earlier failed run is not
retrospectively relabelled as a directly confirmed sudo/PAM reset. Local sampler regressions and Python compilation pass; no changed
Mac runtime path or repeat of its native stress is required.




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
The regression passes on Mac and in Linux run `36490558522`; that run's G7
remains failed. No service source, resource bound or sampling criterion was changed.



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

The runtime used for these Mac lifecycle checks has SHA256
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

WP12b operational acceptance is complete on the declared Mac and Linux profiles,
with reviewed source provenance: native stress on its recorded parent sources,
separate final-source lifecycle/control checks, and all nine ordinary checks at
`7c9505a`. Integration still requires all nine checks on the final evidence and
documentation commit; no service or harness code changes in that milestone. Operational acceptance does
not promote extraction quality: D1's negative result and the deferred
stronger-model comparison remain unchanged. Windows/CUDA and the broader
trace/generate stress obligations remain outside this service acceptance.
