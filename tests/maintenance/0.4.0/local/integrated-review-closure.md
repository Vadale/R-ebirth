# Maintenance 0.4.0 review closure

Date: 2026-10-11. Status: R1 and R2 CLOSED.

- **R1 / P2:** `.github/workflows/nightly-vision-golden.yaml:90` now sets
  `RELM_ENABLE_SELFTESTS: "1"` in the `vision-golden` job environment, covering
  both package installation and the required lifecycle test processes.
- **R2 / P3:** `docs/getting-started.md:10` now links the 0.4.0 introduction to
  `NEWS.md#relm-040`.

Only the affected lines were inspected. No broader review, builds, tests, models
or source edits were performed. The original report and status remain unchanged;
their outstanding CI/release and numerical-debt limitations still apply.
