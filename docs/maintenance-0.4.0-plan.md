# Maintenance and release 0.4.0

Date: 2026-10-11. Status: implementation authorized by the founder.
Baseline: merged Phase 7, `cca4dcf18e4b3772778168f59f50a9f559e4eaef`.

The founder requested correction of existing technical debt, meaningful code
simplification, clearer simplifier instructions and documentation, an updated
GitHub README and a new release before Windows/CUDA. This is one maintenance
deliverable on `codex/maintenance-release-0.4.0`; Phase 8 remains unstarted.

## Debt ledger and ownership

| Item | Action | Acceptance |
| --- | --- | --- |
| Unexplained long-prefill activation mismatch and retained cross-schedule discrepancies | Native owner diagnoses current source and retained observations before proposing a bounded discriminating experiment. | Explain and correct the cause with independent frozen-reference checks; do not relabel a later pass as a fix or regenerate consumed references. |
| R 4.5 non-API state lookup | Replace the non-API accessor with the public frame lookup after the existing active-binding/provenance checks. | Forged, lazy, invalid and GC controls pass; promises remain unforced; R 4.6 branch and resource charge unchanged; compiled-symbol inspection and final package checks. |
| Repeated R handle validation and condition construction | Simplifier consolidates genuine duplicate invariants in existing internal helpers. | Public arguments, validation order, condition fields/classes/calls and native-close synchronization preserved; focused regressions. |
| Incomplete trace-coordinate validation | Refuse a duplicate cell replacing a missing cell even when the row count is unchanged. | Duplicate-plus-missing regression; valid matrices and frozen numerical data unchanged. |
| Test-only native entry points shipped by default | Isolate owner/test hooks behind an explicit non-default build feature, with one authoritative registration list. | Production build contains no test entry points; test build executes existing boundary/resource/async regressions; no public API or runtime-layout change. |
| Stale simplifier instructions and historical punchlist | Publish a current compendium with concrete readability rules, current dispositions and D029 verification policy. | Every actionable historical item traced to current source, a completed change or an explicit evidence-based disposition. |
| Release/documentation drift | Update root/package README, current guides, NEWS and versioned distribution metadata. | Built-package examples/docs, source/binary identity, nine final CI checks and installable published release verified. |

The R simplifier owns the selected R functions and focused tests. The native
owner initially performs source-only diagnosis. The parent is the sole build,
model, integration and publication executor. No parallel native builds or
duplicate test runners. One integrated review is complete; its two findings
(vision fixture-build routing and a release-note link) are corrected and closed.

Local correction acceptance is recorded in
[`tests/maintenance/0.4.0/local/owner.json`](../tests/maintenance/0.4.0/local/owner.json):
24 C controls, 9 FFI unit cases, production registration checks, matching compiled
profiles and 443 installed R cases with 6,704 passing expectations and 67 scoped
skips. The original sandbox-access failure remains failed; only its 61 affected
cases were resumed with actual Metal/sysctl access against the same installed DLL.
The installed libraries still carry pre-version-bump metadata. Final release
package acceptance and the numerical-debt disposition remain outstanding.

## Work and verification order

1. Preserve the accepted baseline and open failures. Reconcile the historical
   July simplifier punchlist with current source; do not repeat already completed
   work or delete evidence to make the repository appear simpler.
2. Implement the concrete C/R and test-surface corrections in separable changes.
   Use focused tests for changed behavior; numerical investigation precedes any
   refactor of the affected native path.
3. Inspect public signatures, generated wrappers, resource accounting and
   documentation together. Record readability gains and changed responsibilities,
   without claiming a performance improvement unless it is measured.
4. Run the final relevant integration checks once on the assembled candidate,
   including the numerical/resource boundaries actually changed. Preserve raw
   failures and diagnose before an affected correction. No blind retries.
5. Complete one review, update the GitHub documentation, publish a release
   candidate and required CI, then build/tag/publish the accepted version and
   verify distribution. No receipt-only commits that restart CI.

## Limits that must stay explicit

- No new public API, dependency, vendor pin, copied R layout or numerical
  tolerance is authorized by a cleanup. Existing D046 comparison criteria remain.
- Recorded model quality, model/site support and consumed holdouts are evidence
  limits, not defects that may be erased or retuned for a release.
- External-user feedback remains deferred under D047. Windows/CUDA and CRAN
  submission remain the subsequent roadmap scopes; this release does not claim
  those acceptances.
- The previous release's documented CRAN-specific findings must be reassessed
  against the actual built candidate. Do not call a warning-bearing check clean.
- Long operations run in the background. Reuse the existing sparse monitor,
  report meaningful changes only, and stop waiting turns rather than polling.
