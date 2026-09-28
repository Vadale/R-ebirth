# D2 — Offline, restartable batch operation

Date: 2026-09-28. Baseline: merged Spark PR #46 (`2c827a7`, llama.cpp b10828).
Status: operational acceptance passed on Mac Metal and Linux CPU; implementation
and independent review complete. [PR #47](https://github.com/Vadale/R-ebirth/pull/47)
is merged at `ddf8467`. All nine final PR checks passed (R run `36415443777`,
Rust run `36415443795`), in addition to the native Linux workflow. No core API, Rust or R package dependency changes.

The [application](../examples/funding-extraction/README.md) provides explicit
setup, offline run/resume, one writer, per-document immutable results and a plain
CSV. D-031's approval addendum limits jsonlite 2.0.0 to this application. Setup
snapshots trusted installed relm/nanoarrow/jsonlite builds and references a
verified local GGUF; the initial R/toolchain/package installation is a prerequisite.
It is not a portable image or a general deployment framework.

## Correctness and independent review

`python3 tests/funding-extraction/test_restart.py --relm-library LIBRARY` passed
**466 assertions in 14.31 seconds** on the founder's Mac. The Python standard
library supplies independent canonical JSON bytes/hashes; actual R processes
exercise the application setup and persistent storage. This is a deterministic
injected-engine test, with no model loading or inference.

Coverage includes real SIGKILL before/after result rename, unchanged committed
bytes, same-seed retry, duplicate-free resume, second-writer rejection, explicit
nonce/host/PID recovery, invalid/error record retention, corrupted/recomputed
digests, changed source/configuration/model/build identity, unknown keys and
malformed JSON. Ownerless locks and partial owner files are constructed states;
the two record-publication boundaries use actual killed processes.

One integrated correctness/security review found three issues, fixed before
native acceptance and covered by regressions:

- jsonlite could replace lone Unicode surrogates or truncate escaped NUL;
  the application now rejects those escape sequences before decoding.
- Decimal/exponent numeric tokens could round or change seed types on resume;
  the integer-only JSON profile now rejects them before conversion.
- Already loaded namespaces could come from outside the pinned snapshot;
  relm/nanoarrow/jsonlite must resolve to the prepared library in a fresh session.

The reviewer rechecked the fixes and reported no remaining material findings.
The process harness is wired into all four Mac/Linux R-release/oldrel PR legs,
reusing the package installed by R CMD check rather than rebuilding native code.

The implementation commit `0c9d627` passed all **nine PR checks**. The
[Mac/Linux package workflow](https://github.com/Vadale/R-ebirth/actions/runs/36412834146)
executed all 466 D2 assertions in each configuration:

| CI environment | D2 process assertions | Time |
|---|---:|---:|
| Linux, R release | 466 passed | 35.96 s |
| Linux, R oldrel-1 / Rust 1.85.0 | 466 passed | 36.45 s |
| Mac, R release | 466 passed | 35.95 s |
| Mac, R oldrel-1 | 466 passed | 37.59 s |

The [five native/repository checks](https://github.com/Vadale/R-ebirth/actions/runs/36412834206)
also passed. No assertions were waived and no native goldens changed.

## Native Mac Metal acceptance

The [retained measurements and outputs](../tests/funding-extraction/measurements/macos-metal-2026-09-28/acceptance.json)
use Spark-X2.5-4B Q8_0, the three checked-in D1 **development** cases, R 4.5.1,
macOS arm64 and the already checked b10828 build. Application SHA256:
`f49c6615f86241145244632950953c8d6bfd5352d5bf6bc5d032ca3bda6e1958`.
The environment receipt pins every installed package and the model bytes.

Every run and recovery process is a fresh R session under `sandbox-exec` with
`deny network*`. Setup uses an existing local model and performs no download.
External `/usr/bin/time` records peak resident memory; first-result timing comes
from the application and includes integrity checks and model loading.

| Operation | Elapsed wall time | Peak RSS | Result |
|---|---:|---:|---|
| Prepare installed-package snapshot and verify 4.38 GB model | 10.28 s | 89.14 MiB | Prepared |
| First complete run | 39.75 s | 4.84 GiB | 3 committed records; first result at 24.30 s |
| Hard-killed second run | 31.94 s until termination | 4.83 GiB | First record committed; second generated but not renamed |
| Explicit abandoned-lock recovery | 0.19 s | 82.26 MiB | Owner verified and lock quarantined |
| Resume in new offline session | 26.47 s | 4.83 GiB | 1 reused, 2 processed; no duplicate commits |
| Repeat completed run | 10.99 s | 88.80 MiB | 3 reused, 0 processed; no model loaded |

All three outputs pass application checks, with no generation errors. The
completed record survives the kill **byte-for-byte**; resumed raw/parsed outputs
match the uninterrupted run when timing and its digest are excluded. The final
reuse preserves every committed byte. The completed-run overhead is mostly
rehashing the model: integrity verification is retained instead of trusting its
filename or modification time. These are observed single-run costs, not an SLA.

## Native Linux CPU acceptance

The [Linux workflow](https://github.com/Vadale/R-ebirth/actions/runs/36412833788)
passed on implementation commit `0c9d627`, including the existing Qwen/S1 checks
and D2's offline run, actual SIGKILL, explicit recovery and resume. The
[retained Linux measurements](../tests/funding-extraction/measurements/linux-cpu-2026-09-28/acceptance.json)
use R 4.6.1, x86_64 Linux, nanoarrow 0.9.0, jsonlite 2.0.0 and the registry-pinned
Qwen2.5-0.5B Q8_0 GGUF (675,710,816 bytes). The application SHA256 is identical
to the Mac candidate. Model size/backend/hardware differ, so the timings below
are operational observations, not a speed comparison between platforms.

The workflow reuses its already downloaded 0.5B model and installed release
build. Run/recovery processes execute inside a separate network namespace and
drop to the caller UID. No 4B download enters ordinary PR CI. GNU `time` reports
peak RSS; setup excludes initial R/package installation and model download.

| Operation | Elapsed wall time | Peak RSS | Result |
|---|---:|---:|---|
| Prepare snapshot and verify model | 3.27 s | 79.50 MiB | Prepared |
| First complete run | 45.22 s | 863.67 MiB | 3 committed records; first result at 24.29 s |
| Hard-killed second run | 35.03 s until termination | 863.62 MiB | First record committed; second not renamed |
| Explicit lock recovery | 0.31 s | 73.62 MiB | Owner verified and lock quarantined |
| Resume in new offline session | 24.46 s | 863.86 MiB | 1 reused, 2 processed; no duplicate commits |
| Repeat completed run | 3.42 s | 75.40 MiB | 3 reused, 0 processed; no model loaded |

The small model produces **one application-valid and two invalid records**, with
zero generation errors. All raw outputs and validation failures remain archived.
The operational harness passes because publication, failure accounting and
resume work correctly; the production CLI would return exit 2 for this completed
batch with invalid records. No quality threshold was lowered or output repaired.
The first committed record remains byte-identical; resumed outputs match the
uninterrupted run apart from per-call timing and its enclosing digest.

## Acceptance scope

This milestone validates operational behavior under process interruption on
tested local filesystems. It does not claim power-loss durability, network
filesystem safety, arbitrary concurrent recovery or cross-hardware bit identity.
The archived receipts contain test-run paths; their temporary prepared libraries
are removed after acceptance and are not a distribution artifact.

`success` validates field types/missingness and exact quote occurrence, not
semantic correctness. D1's negative quality evidence remains unchanged, and the
small-model pilot is not an optimization target. Stronger models, external APIs
and a Luna comparison are deferred at the founder's request. The next planned
work package after D2 acceptance is WP11a's statistical probe contract; the
minimal service contract/implementation follows as WP12a/b.
