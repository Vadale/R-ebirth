# WP9 foreground RStudio acceptance — 2026-10-02

Actual foreground RStudio console, R 4.5.1 / RStudio 2025.9.1.401, on the founder's
Mac mini M4. The previously verified installed WP9 library was reused. Candidate
8053bf8 changes only test setup and documentation relative to that runtime.
All recorded runtime input hashes still match the prior accepted manifest.

The cached Qwen 0.5B CPU job ran for **17.78796 seconds** with seed 17, four
prompts and 512 maximum tokens per prompt. Submission took **0.105 seconds**.
An independently submitted `source(".../probe.R")` returned `[1] 2` in the live
console while the job was running (probe timestamp lies strictly between start
and finish). The measured R expression time was **0 seconds at clock resolution**,
below the 500 ms gate, with **322 independent event-loop heartbeats**. This
measurement does not include UI automation transport latency. The actual UI
subsequently displayed `WP9_RSTUDIO_COMPLETE: passed`.

RStudio had just opened a fresh R process. Its sole hidden global was
`.Random.seed`; the preflight first rejected that and was corrected to preserve
it explicitly. No model generation had started in that rejected preflight.
The separately launched temporary project could not be selected by the UI
controller, so the existing fresh, empty foreground console was used. This was
not a background RStudio job. The founder's editor documents were untouched.
After completion the original globals, seed, library paths and search path were
restored exactly; the UI displayed `WP9_RSTUDIO_WORKSPACE_RESTORED`. The namespace
and DLL remain loaded for safe finalization; no forced unloading was attempted.

`status.json`, `result-summary.json`, `result.rds` and `restoration.json` are
machine-written receipts. Scripts and post-run source/installed/model hashes
are included. `ci-8053bf8-final-pr.json` records all nine green checks before this
evidence-only milestone; later head checks must be verified separately. Prior
compiler, sandbox and CI failures remain in their original directories.

This passes the missing foreground responsiveness gate. It adds no claim about
extraction accuracy, arbitrary models, CRAN readiness or a new public release.
