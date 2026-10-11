# relm 0.4.0 release record

Status: **preparation in progress**; no tag, assets or distribution acceptance
is claimed. Authorized on 2026-10-11 under D048 after Phase 7 integration.

The release brings together background/streamed generation, bounded live state,
recorded contrast directions, static component projection, base-R graphics and
the complete research walkthrough. Maintenance addresses shared R validation,
condition construction, trace-coordinate validation, public R state inspection
and isolation of native test hooks. See [NEWS](../rebirth/NEWS.md#relm-040),
[the maintenance plan](maintenance-0.4.0-plan.md),
[the simplifier compendium](simplifier-compendium.md) and
[the support matrix](supported-workflow.md).

## Required completion evidence

- Affected correction checks and one integrated current-source review.
- All nine required final CI outcomes, with actual execution and warnings recorded.
- Source build and built-package check; generated documentation and examples;
  built-package quickstart/demos with explicit model/source provenance.
- Source and Mac binary asset hashes bound to the approved source; GitHub tag and
  release; r-universe source/version observation and fresh-library installation.

The affected local corrections and one integrated review are complete; see
[the source-bound local receipt](../tests/maintenance/0.4.0/local/owner.json).
Final CI, built-package and distribution acceptance
remain pending. Prior 0.3.0 or Phase 6/7 evidence is retained at its original source and cannot substitute
for new release claims. No CRAN submission or Windows/CUDA acceptance is included.

## Interpretation limits retained

The consumed F6e experiment found a modest fixed-corpus projection result, with
truncated outputs and no general efficacy or pure-operator claim. Known pinned
model-tokenizer behavior remains explicit. The Phase 7 long-prefill comparison
now has an explicit oracle precision contract following the retained Mac/Linux
contrast; [default-context accuracy limits remain explicit](maintenance-0.4.0-numerics.md).
Separate earlier cross-schedule outliers are not retrospectively accepted.
Existing model/site and optional-dependency
limits remain in the support matrix. External-user feedback is deferred under D047.

The 0.3.0 D035 exception applied to that release only. Assess any current package
warning against the actual 0.4.0 output; do not transfer the old exception or
suppress diagnostics to manufacture a clean check.
