# Actual service acceptance

`accept.py` exercises the HTTP frontend and supervised worker as real processes.
It uses Python's standard library and the approved R service package closure.
The trusted R launcher injects deterministic workers only for G1–G4; the public
CLI and HTTP API have no fixture controls. No fixture, static unit inspection,
missing manager, or unavailable model counts as a native acceptance pass.

Run the deterministic suite from the repository root, with a fresh evidence
directory and the exact installed service library:

```sh
python3 tests/funding-service/accept.py --suite deterministic \
  --source-library /path/to/service-library \
  --work-dir /path/to/new-evidence --default-deadline
```

The suite requires loopback networking, process-tree inspection, and permission
to terminate its own disposable children. The default 120-second worker deadline
is executed unchanged. Omitting `--default-deadline` leaves G3 partial and exits
nonzero; short injected deadlines test recovery mechanics only.

Individual gates use `--suite http`, `admission`, `recovery`, or `persistence`:

| Gate | Executed boundary |
| --- | --- |
| G1 | Real HTTP framing, routes, strict JSON/Unicode, limits, zero dispatch on rejection, case-sensitive IDs and private files |
| G2 | Simultaneous same-ID admission, 20-client overload, health latency during a blocked child, immutable replay and zero queue |
| G3 | Real worker/frontend SIGKILL, request deadline, initialization/diagnostic/IPC failures, old-epoch completion, unconfirmed death, private temporary directories |
| G4 | SIGKILL at all four rename boundaries, corruption and changed-identity refusal, second writer, unknown IPC ownership, output overflow, publication failures and bounded near-capacity diagnostics |

G4's storage test modifies diagnostic history only while the store is stopped.
It then restarts with a smaller private quota and observes the real append guard;
authoritative terminal bytes must remain unchanged. No production quota changes.

Native gates require an already prepared environment, the declared profile, and
a new evidence directory for each invocation:

```sh
python3 tests/funding-service/accept.py --suite isolation \
  --environment /path/to/environment --profile mac_qwen --work-dir /path/to/g5
python3 tests/funding-service/accept.py --suite native \
  --environment /path/to/environment --profile mac_qwen --work-dir /path/to/g6
python3 tests/funding-service/accept.py --suite stress \
  --environment /path/to/environment --profile mac_qwen --work-dir /path/to/g7
python3 tests/funding-service/accept.py --suite supervisor \
  --environment /path/to/environment --profile mac_qwen \
  --supervisor launchd --work-dir /path/to/g8
```

Profiles are `mac_spark`, `mac_qwen`, and `linux_qwen`; G7 accepts the Qwen
profiles only. Use `systemd-user` on Linux. G5 performs native A/B/A, fresh-worker
comparison, actual context overflow and one explicitly labelled invalid-output
injection **after** real native generation. G6 runs 30 ordinary native requests,
a controlled worker crash and shutdown. Its whole process tree runs inside the
actual loopback-only OS boundary supplied by `offline.py`; direct external
socket denial and successful loopback access are recorded. Missing OS isolation
fails closed. Proxy settings alone are not offline evidence.

G7 runs all 1,000 native requests without recycling the worker and checks the
frozen warmup/tail/slope and RSS limits. `processes.R` samples actual process
creation identities at 100 ms, includes owned descendants, and fails on live
inspection errors. Each request requires a new post-completion sample. A dead
or stalled sampler cannot reuse earlier observations. Fresh-row reads use the
last complete CSV line instead of repeatedly parsing the growing history. Stress
exits before further HTTP requests on a sampling error; per-request CSV rows are
flushed as they complete, preserving partial-run evidence. The 100 ms target and
200 ms missing-period guard are unchanged. These are host RSS
measurements, not Metal device allocation measurements.

G8 creates and later removes a uniquely named disposable definition in the real
user service manager. It executes start, SIGKILL/restart, ordinary stop, occupied
port and changed-config refusal, records repeated failure counts and backoff,
and checks that unrelated live or reused PIDs are never signalled. An unavailable
manager is an unexecuted gate with a nonzero exit. It does not substitute syntax
validation for execution or alter existing user services.

Every run preserves `acceptance.json`, request timings, process RSS samples,
service records and diagnostic logs beneath its evidence directory. Failures
and cleanup errors make the run fail. Reports cover only gates actually invoked;
none establish extraction quality. `--self-test` checks the harness's dead/stalled
sampler guards and explicitly does not execute or pass a service gate.
`Rscript --vanilla tests/funding-service/processes.R /path/to/service-library
self-test` separately proves that a live inspection denial fails, PID reuse is
excluded, and an actual child death becomes a missing sample. An inspection
error allows at most 100 ms to confirm death/reuse; missing samples remain
recorded and cannot certify G7's complete sampling requirement.

`test_environment.py` and `install-pins.R` are separate setup/pinning checks.
The frozen contract remains in `tests/service-contract/contract.json`.

`Rscript --vanilla tests/funding-service/test-ipc-scan.R` runs the focused
model-free IPC scanner regression without installed service packages. It uses
real disposable files and binds `file.info` locally on a copy of the product
function to remove a listed file immediately before stat. Confirmed live IPC
disappearance is allowed; durable disappearance, existing unstatable files,
unverifiable ancestors, and file/directory symlinks remain errors.

`Rscript --vanilla tests/funding-service/test-process-rss.R /path/to/service-library`
runs nine model-free process-lifecycle regressions in every ordinary R CI leg and
the native Linux workflow. It verifies delayed death after RSS/status inspection
errors, persistent live/unknown denial, creation-time identity reuse and actual
child termination. Only confirmed termination can discard a failed read; the
original process handle is retained and retries add at most 100 ms of waiting.
Successful reads and resource thresholds are unchanged.

`python3 tests/funding-service/test_sampler.py` runs six model-free regressions
in every R CI leg and the explicit native workflow: complete/partial quoted CSV
rows, empty/malformed records, bounded history reads, actual fresh append and
failure before another HTTP request. Native receipts fingerprint `accept.py`,
`processes.R` and `offline.py`. The R sampler self-test additionally exercises
live tree-discovery denial, original-parent death/reuse and CSV equivalence.
