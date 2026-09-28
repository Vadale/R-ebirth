# D2 — Offline, restartable batch operation

Date: 2026-09-28. Baseline: merged Spark PR #46 (`2c827a7`, llama.cpp b10828).
Status: implemented and independently reviewed; local process and Mac Metal
acceptance pass. Linux CPU native acceptance and PR checks are pending at this
local milestone. No core API, Rust or R package dependency changes.

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

## Linux CPU gate and scope

The existing Qwen tolerance workflow now runs the same native harness using the
already downloaded registry-pinned 0.5B Q8_0 model and installed release build.
Run/recovery processes execute inside a separate network namespace with the
caller UID. No 4B download enters ordinary PR CI. The workflow preserves logs,
environment receipts, resource measurements and committed records as
`funding-extraction-cpu`. A workflow definition alone is not a passing result;
record the actual execution before closing D2.

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
