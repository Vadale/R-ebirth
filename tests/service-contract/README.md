# WP12a contract artifacts and WP12b acceptance plan

**Status: D-034 approved on 2026-09-28; WP12b implementation active.** These files specify the frozen contract; runtime implementation lives in
`examples/funding-service/` and acceptance in `tests/funding-service/`.
`verify.py` remains an offline specification check. It validates
pins, limits, state consistency, source links and preserved D2 fixtures, and
rejects deliberate contract mutations. It also checks worst-case JSON expansion for the bounded overflow record.
It proves no runtime behavior. The existing Rust workflow runs this inexpensive
checker in its Python golden self-check job, without starting a service.

```sh
python3 tests/service-contract/verify.py --self-test
```

No R/native build, model load, package installation or port binding is needed.
The direct and mandatory transitive application dependencies are in
`dependencies.csv`; `dependency-provenance.json` binds the exact CSV to the
queried official CRAN metadata. This is not a complete installed-library receipt:
WP12b setup must also fingerprint actual packages, relm/nanoarrow, R/native build,
model and platform. No version is silently floated during setup.

## Operator command contract

The filenames below are WP12b deliverables. Their execution evidence is separate
from this specification; see [the implementation report](../../docs/service-implementation.md). Prepare a
trusted installed library with the approved pins first; only explicit preparation
may install/download. The setup command snapshots it, verifies the existing model
and writes a private service configuration/environment receipt.

```sh
Rscript --vanilla examples/funding-service/setup.R \
  --source-library /absolute/checked/library \
  --model /absolute/model.gguf --model-alias spark-x2.5-4b-q8_0 \
  --backend metal --environment /absolute/service/environment
Rscript --vanilla examples/funding-service/start.R \
  --environment /absolute/service/environment --store /absolute/service/store
Rscript --vanilla examples/funding-service/status.R \
  --environment /absolute/service/environment --store /absolute/service/store
Rscript --vanilla examples/funding-service/stop.R \
  --environment /absolute/service/environment --store /absolute/service/store
```

The foreground `start.R` process is the frontend. Supervisor templates use the
same command with absolute paths: user LaunchAgent on Mac, systemd user unit on
Linux. Default port 8765; tests allocate a free loopback port while keeping all
other limits fixed. New configuration/model/build requires a new store. Status
reports ownership, readiness, active ID and terminal counts, not source content.

```sh
curl --fail-with-body http://127.0.0.1:8765/health/ready
curl --fail-with-body -H 'Content-Type: application/json' \
  --data-binary @request.json http://127.0.0.1:8765/v1/extractions
curl --fail-with-body http://127.0.0.1:8765/v1/extractions/ace22-total
```

`request.json` has the shape of one entry in the D2 development corpus. A 202 is
an admission/ticket, not a successful extraction. A 200 result still requires
inspection of `state`. Client disconnection never cancels admitted work.

## Future executable gates

**Gate definitions are frozen here; actual run outcomes are recorded separately.** WP12b supplies
`tests/funding-service/accept.py` (Python standard library for HTTP/process
orchestration) and controlled R worker fixtures. Python is test tooling, not a
runtime requirement. All suites must fail if the real service/required fixture
is missing; they cannot fall back to the offline checker or an injected engine
for a native gate.

Common invocation:

```sh
python3 tests/funding-service/accept.py --suite SUITE \
  --contract tests/service-contract/contract.json \
  --environment /absolute/prepared/service/environment \
  --work-dir /absolute/disposable/acceptance
```

The harness starts an isolated instance, uses a fresh private store and port,
records source/package/model/OS/backend identities, and writes `acceptance.json`
plus per-request statuses and time/RSS CSVs. It cleans only processes/directories
it created. Store receipts/results survive each crash scenario for byte checks.
Runtime gates use both supported R lines where available; model-free gates enter
the existing four Mac/Linux PR legs after WP12b. Native/stress gates reuse pinned
models in a dedicated workflow/manual host run, not per-commit large downloads.

| Gate / suite | Fixture and method | Required result | Owner |
|---|---|---|---|
| G1 `http` | Real pinned Plumber/httpuv with deterministic worker; raw-socket CL missing/duplicate/negative/nondecimal/overflow, TE with/without CL, compressed bodies, truncated bodies, oversized bodies, invalid UTF-8/JSON/NUL/surrogates, unknown keys, bad ID/seed, Host/Origin, GET body; exact limit and limit+1 | Reject with documented code or transport rejection before dispatch; no accepted receipt or model call; valid UTF-8 and escaped literals preserved; static/docs/WS/eval routes unavailable | Test engineer |
| G2 `admission` | Hold one actual worker call open; submit 20 distinct clients simultaneously, plus same-ID/same-body and conflicting replays; poll both health routes during native-equivalent blocking | Exactly one active job, no queue, other distinct requests 429; replay 202/200 or conflict 409; recorded calls prove no duplicate dispatch; latency meets contract p95/max | Test engineer |
| G3 `recovery` | Actual supervised callr child: request deadline, worker SIGKILL, frontend SIGKILL, late result from retired epoch, init failure, unreapable-worker injection, three failures in 300 s; stdout/stderr/message flood during startup and inference; inherited shared temp variables | Request terminal accounting; no fresh worker before old death; death≤5s/recovery≤125s when recoverable, otherwise faulted; parent SIGKILL leaves no old worker; stale result cannot change new slot/result; bounded output draining meets health latency; all IPC files private and inside the owned epoch; IPC overflow closes admission | Test engineer |
| G4 `persistence` | SIGKILL frontend immediately before/after admission rename and before/after terminal rename; lost client response; concurrent owner; PID reuse; altered payload/config/build/model; corrupt admission/result/digest; simulated disk-full/read-only publication; 64 KiB control-character output whose JSON exceeds 128 KiB; UTF-8 prefix boundary; orphan IPC after frontend SIGKILL | Published records byte-identical; no false completion/automatic retry/overwrite; foreign/stale/corrupt data refuses reuse; storage failure closes admission and exposes recoverable receipt; all accepted IDs accounted after repair; overflow is a bounded error with explicit prefix/length/digest, never silent truncation; owned IPC reclaimed only after confirmed death, no foreign files removed | Test engineer |
| G5 `isolation` | A/B/A with fixed seeds; inserted invalid output, context failure and worker restart; compare native A with independently initialized worker using same build/backend | Identical output for seeded A within one machine/build; no previous-source/context leakage; condition classes preserved; invalid/error records count, never hidden retries | Implementation owner |
| G6 `native` | 30 sequential requests cycling frozen D2 development cases; one crash/reload, normal stop and offline setup/run checks; Mac Spark Metal + Mac Qwen Metal + Linux Qwen CPU | Each admitted ID has exactly one terminal record; startup≤120s, request≤120s or explicit interruption; no ordinary-run timeout/crash, peak RSS within profile; stop≤15s and zero residual workers | Implementation owner |
| G7 `stress` | 1,000 unique Qwen requests through real HTTP→persistent native worker→validation→commit, alternating the 3 D2 cases; no automatic worker recycling; same seed per case, same prompt/schema/settings; failures retained | Worker PID/epoch constant; no generation/protocol errors or restarts; invalid domain outputs allowed and counted; 1,000 immutable terminal records; max RSS, tail-minus-warmup≤256MiB and post-warmup slope≤256KiB/request; native first/last output isolation | Implementation owner |
| G8 `supervisor` | Real user LaunchAgent/systemd instance: start/status/stop, frontend crash, repeat restart failures, occupied port, changed config and unowned live PID | Tested startup/recovery bounds, correct backoff/fault behavior, no overlapping model ownership, no residual worker; invalid config never reports ready | Implementation owner |

Native/stress commands additionally take `--profile mac_spark`, `mac_qwen` or
`linux_qwen`; G7 is required on both Qwen profiles. G8 takes
`--supervisor launchd` or `systemd-user`; absence of the required service manager
is an **unexecuted gate**, not a passing skip. Use a declared Linux VM/host if
GitHub's runner cannot execute its user unit. Windows/CUDA is outside the matrix.

G1–G4 can use a tiny deterministic R fixture and short injected durations to
exercise faults quickly, but must also test the default 120 s deadline once per
OS against an uninterruptible/long-running child. Do not replace process kills
with mocked exceptions. G5–G7 use actual relm and the registry pins; use no D1
held-out examples. G6/G7 measure finite real runtime rather than imposing a
throughput target not justified by existing data. A 1,000-call run may take hours.

Measure elapsed times with the harness monotonic clock. For latency, compute
nearest-rank p95 plus maximum over all attempts, including rejected ones; report
startup separately. For RSS, sample frontend/worker/owned-supervisor by PID plus
creation time every 100 ms; record peak sum and post-request idle samples. G7 uses
requests 1–100 as the warm baseline and 901–1000 as the tail; fit an ordinary
least-squares slope to samples 101–1000 versus request index. Do not force extra
GC or restart the worker during measurement. Missing samples/process identity
or fewer than 1,000 terminal records fail, never shrink the denominator.

Acceptance reports distinguish domain `invalid` from infrastructure `error` and
`interrupted`; D1's quality result is not promoted by service reliability. If a
threshold fails, preserve the report and fix or explicitly reconsider the
contract; do not tune limits against the failing run and call the original gate
passed.
