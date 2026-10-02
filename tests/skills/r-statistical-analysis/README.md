# Statistical skill: bounded validation

Date: 2026-10-01. Companion skill v0.1.0; no relm native code changed.

## Executed checks

- The skill-creator frontmatter/resource validator passes with the repository's
  existing Python test environment (PyYAML available there). A legacy validator
  does not support the optional standard `compatibility` field, so runtime
  requirements are in the skill body instead. No new dependency was installed.
- Base-R artifact-runner checks pass: a known mean/Student interval fixture,
  spaced paths, warning retention, existing-output rejection, failed fits,
  malformed intervals and detection of modified input. These model-free checks
  are wired into all four existing R PR matrix legs, before package compilation.
  Local verification: macOS arm64 / R 4.5.1; remote results are separate.
- Independent guided forward test: 60 synthetic persons, two groups, five visits,
  300 rows. R 4.5.1 / nlme 3.1-168 fitted a repeated-measures model and person-level
  change sensitivity, produced estimates/intervals and a visually inspected plot.
  Final execution completed without warnings. The first analyst attempt failed
  on `update()`/unqualified `lme.formula`; its code/error remain in `evidence/`.
- Fourteen requests received a metadata-only model assessment. This assessment
  was not blinded and is not a native-client activation experiment. It supports
  no automatic selection percentage or universal R preference claim. Two cases
  require workflow context/body instructions rather than metadata alone.

The skill's statistical-check guidance was clarified after review: a
non-significant lack-of-fit test does not validate a model assumption. Raw forward
outputs are retained unchanged, including that diagnostic's overly positive
`pass` label, with a separate interpretation note in the review. No repeat fit
was needed for this instruction-only clarification.

## Reproduce the short checks

From the repository root:

```sh
Rscript --vanilla tests/skills/r-statistical-analysis/test-runner.R .
Rscript --vanilla integrations/skills/r-statistical-analysis/scripts/inspect-environment.R stats nlme
```

With nlme already available, repeat the independent example into a **new** output:

```sh
Rscript --vanilla integrations/skills/r-statistical-analysis/scripts/run-analysis.R \
  tests/skills/r-statistical-analysis/evidence/analysis.R \
  /tmp/r-statistical-example-new \
  tests/skills/r-statistical-analysis/evidence/observations.csv
```

The data are synthetic, never a treatment-effect demonstration. The example is
not part of a continuous statistical benchmark; no unrelated package build or
model download is needed. The first fixture in `test-runner.R` has an independent
closed-form numerical check. The complex example is a workflow check with a
sensitivity analysis, not independent validation of nlme's implementation.

## Evidence and remaining work

`evidence/` contains exact analysis/input snapshots, numerical results, the main
plot, retained first failure and the review. `provenance.json` binds these files
and the runner by SHA256. Source provenance is separate from the post-review
instruction clarification. `requests.json` contains mixed routing/behavior
expectations; future I1 evaluation must test the latter by execution.

Not executed: native automatic selection in Codex/Claude, marketplace discovery,
other advanced statistical domains (Bayesian, survival, surveys, omics, etc.),
Windows or all R packages. I1 after WP9/WP10 owns actual external-client transport
and selection checks. No hosted model API, package installation, relm inference,
release rerun or WP12b stress test was used for this skill.
