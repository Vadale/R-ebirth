# Maintenance 0.4.0 integrated review

Date: 2026-10-11. Branch: `codex/maintenance-release-0.4.0`.
Base: `cca4dcf18e4b3772778168f59f50a9f559e4eaef`.
Status: two actionable findings; no other findings in the bounded review.

## Findings

1. **[P2] Enable the selftest build for the vision nightly.**
   `/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/tests/testthat/test-llm-async-lifecycle.R:8`
   now requires the native fixture registrations. However,
   `.github/workflows/nightly-vision-golden.yaml:165` installs the default profile
   without `RELM_ENABLE_SELFTESTS=1`, then line 190 invokes the installed lifecycle
   preflight. All three required lifecycle cases use this gated helper, so they
   skip; `tests/ci/run-vision.R:25` rejects required skips and the nightly fails
   before its model stage. Set the explicit flag consistently for this workflow's
   install and test processes. Preserve the required no-skip checks. Parent has
   acknowledged the correction; it was not yet applied in the reviewed snapshot.

2. **[P3] Link the 0.4.0 introduction to its release notes.**
   `/Users/alessandrovadala/DOCUDESK/R-ebirth/docs/getting-started.md:10`
   still targets `NEWS.md#relm-030` immediately after describing the 0.4.0 research
   interfaces. It sends users to the older release and omits the stated features.
   Change the fragment to `#relm-040`.

## Scope and evidence

Reviewed the changed R guards/conditions/trace conversion and focused tests;
public old-R frame lookup and existing provenance/unforced-value controls;
feature/configuration/registration/wrapper wiring; extracted native fixture
modules; the ignored prefix diagnostic; current workflow consumers; and release,
README and simplifier documentation. The module moves preserve existing assertions
(formatting only). No additional current fixture-dependent workflow omission was
found: the tolerance test step already enables selftest; demos, service/S1/D2 and
manual Spark use public paths.

Read-only receipts support 24 C controls, both compiled/installed profiles,
production registration checks (6 cases, 19 expectations), and 9 FFI unit tests.
The original selftest CSV has 443 cases, 6,385 passing expectations, 67 optional
skips and 61 failed cases with zero passing expectations; the retained exact-case
resumption records 319 passing expectations for those 61 cases. The combined
6,704 expectations are therefore not double-counted. This is a corrected evidence
aggregate, not a claim that the original run passed. External testthat/header
warnings and original failures remain retained.

No builds, tests, models, formatting or source edits were performed by this
reviewer. Final CI, source-build/package checks and publication/distribution
acceptance remain pending. The unresolved Phase7 long-prefill failure remains
scientific debt: the new diagnostic does not fix it or establish acceptance, and
the temporary branch-scoped CI execution must be removed after its retained run.
No public API/dependency/vendor/golden or numerical-tolerance change was found.

Reviewed source identities and status are recorded in `integrated-review.json`.
