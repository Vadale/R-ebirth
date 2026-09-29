# Linux native acceptance at the parent source

Workflow: https://github.com/Vadale/R-ebirth/actions/runs/36506438374
Source commit: `74cc156015ce022e7f6253f47451e062e9ab3ae5`.
Runtime SHA256: `8e458534ccf171e4fa3ed85dab51743a5c821c47526aa634e116ca20ae973ed3`.
Each compact receipt preserves source/harness hashes and the original report digest.

The original priority bootstrap reproduced permission denial with inherited
RLIMIT_NICE `[0, 0]`. The corrected path passed with `[30, 30]`, unchanged
unprivileged UID, observer nice -10 and workload/controller nice 0. This measured
comparison supports the correction; the older failed preflight lacked its own
stderr and cannot retrospectively prove the same cause.

G5, G6, G8 and G7 passed. G7 has 9,015 assertions and 1,000 distinct terminal
requests, one worker PID/creation identity and epoch, 334 validator successes,
666 invalid results and zero infrastructure errors. This is operational evidence,
not a model-quality promotion. Peak process RSS is 1,518,149,632 bytes; last-minus-
first 100 median growth is 28,315,648 bytes; post-100 slope is 39,993.85418355661 bytes
per request. Limits remain 3 GiB peak, 256 MiB growth and 256 KiB/request slope.

`verify-stress.R` independently recomputes request identity/counts and growth,
using base-R `lm()` for slope. `independent-r.json` records its result.
`independent-rss.json` and `provenance.json` retain the raw-sequence audit: 116,194
consecutive samples, maximum exact decimal gap 0.186 seconds, and the same live
worker in every row 32–116191. The focused reviewer separately verified the same
three live PID/birth identities throughout that interval. Full RSS and event
streams are compressed losslessly; raw and compressed digests are recorded.

## Retained teardown marker

`stress-rss.error` is retained unchanged: `process disappeared while sampling`.
It does not certify a failure during the G7 measurement interval. The exact source
checks marker absence after all 1,000 terminal records and fresh post-request
samples, then stops the service before stopping its observer. First-error
preservation prevents an earlier marker being overwritten. Worker removal starts
at row 116192 and the only `alive:false` is the frontend at row 116193; final state
is stopped with 1,000 terminal records and zero restarts. The sampler log is empty.
The marker's timestamp was not recorded: teardown attribution relies on harness
ordering, first-error preservation and terminal samples, not workflow status alone.
Do not describe these artifacts as having no sampler errors anywhere.

## Scope on the later candidate

The later Linux ownership correction changes `svc_alive()` in startup, recovery
and operator controls. Successful steady requests/status writes/RSS do not use
that helper. Focused review supports retaining this G7 evidence for that unchanged
path only together with passing final-source Linux G5/G6/G8 and ordinary controls.
The separate [final-source lifecycle receipts](../owner-lifecycle/) now pass
G5/G6/G8 on `7c9505a`, which also passes all nine ordinary CI checks. G7 was not rerun on the later source. Earlier failed native runs remain
failed and preserved in their own directories.
