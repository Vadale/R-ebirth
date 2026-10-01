# Independent forward test of r-statistical-analysis

This was an actual, bounded execution of an observational longitudinal analysis,
not a native assistant-routing test. No repository files were changed, no native
build ran, and no package or data was downloaded or installed.

## Execution and artifacts

- R 4.5.1, aarch64-apple-darwin20; nlme 3.1-168 available; lme4 unavailable.
- Input: /private/tmp/relm-stat-skill-eval/observations.csv. Input MD5 remained
  24cd8f8850186f9e4390d66bc829ec1a before and after the successful execution.
- Complete run: /private/tmp/relm-stat-skill-eval/forward-test/results-v2.
- Reproducible code: results-v2/analysis.R. The root analysis.R matches its
  recorded MD5 0e08c71bad7a1c2d67d0fe40a1014d2b at completion.
- Main estimates: results-v2/estimates.csv; report: results-v2/summary.md.
- Main figure: results-v2/trajectories.png; diagnostic figure:
  results-v2/diagnostic-plots.png. Both were opened and visually inspected.
- Diagnostics, conditions, session, manifest, variance components, residual ACF,
  observed means, fitted trajectories and individual changes were retained.
- Successful runner exit 0, State complete, zero captured warnings or errors.
- First attempt: results/ (State failed, exit 1). It is intentionally preserved.

To reproduce, use a fresh output directory:

```sh
Rscript --vanilla \
  /Users/alessandrovadala/DOCUDESK/R-ebirth/integrations/skills/r-statistical-analysis/scripts/run-analysis.R \
  /private/tmp/relm-stat-skill-eval/forward-test/results-v2/analysis.R \
  /private/tmp/relm-stat-skill-eval/forward-test/reproduction-new \
  /private/tmp/relm-stat-skill-eval/observations.csv
```

## Numerical result and limits

There are 60 persons (30 per group), five monthly visits numbered 0 through 4,
300 observations, no missing data, no duplicated person/visit combinations and
no within-person changes of group. A REML linear mixed model with correlated
person-specific random intercepts and slopes estimates the primary association:

| Estimand | Estimate | 95% confidence interval |
|---|---:|---:|
| Programme minus comparison monthly change | 1.361073 | 1.107790 to 1.614356 |
| Programme minus comparison change over 4 months | 5.444292 | 4.431161 to 6.457423 |
| Comparison monthly change | 0.439345 | 0.260247 to 0.618443 |
| Programme monthly change | 1.800418 | 1.621320 to 1.979516 |
| Observed 4-month change difference, Welch sensitivity | 5.347423 | 4.209440 to 6.485406 |

Primary intervals use nlme's Wald t degrees of freedom (238 for slope terms).
The sensitivity treats each person's first-to-last change as one independent
observation, using Welch df 56.39; it reaches the same substantive conclusion.
The exploratory ML comparison with categorical group-by-visit means gives
p=0.288848; this does not establish that the mean trajectories are linear.

The group allocation is observational. These estimates describe different
trajectories and do not identify an intervention effect. There are no supplied
adjustment variables, pretreatment trends, population sampling frame, score
meaning or minimally important difference. Higher scores cannot automatically
be called improvement. Five visits span four monthly intervals.

## Visual and diagnostic review

The main plot is legible, with group labels, score units, month scale, group sizes
and pointwise 95% mean confidence bands. The bands represent uncertainty in each
group mean, not the interval for the group difference or prediction intervals.
The observed means are broadly consistent with linear trajectories.

The residual plot shows no striking funnel or curve. The residual Q-Q plot is
approximately linear with some upper-tail deviations. Lag-1 normalized residual
ACF is -0.295; such conditional residual correlations are affected by fitting
person-specific effects and should not alone be interpreted as proof of an AR
process. Five observations per person limit covariance diagnosis. The script
retained the residual-correlation and distribution checks as not_assessed;
this later visual review is recorded separately rather than changing a completed
runner artifact. No exhaustive influence or covariance-structure analysis was
performed in this bounded test. Random-slope SD was 0.2431 and random-intercept
SD 6.2697; there was no captured convergence failure.

## What worked

- The skill led to inspecting repeated IDs, time coding, missingness, group
  references and package availability before fitting.
- nlme was a suitable already-installed package; lme4 absence did not block the
  method or cause installation. No relm/model/network path was used.
- The actual repeated-measures model, estimand, endpoint sensitivity and causal
  caveats aligned with the skill. Computation completed in well under a second,
  so a background monitor would have been unnecessary.
- Runner output was compact, easy to inspect and reproducible. It retained
  failure evidence, source code, fingerprints, conditions and session metadata.

## Actionable observations

1. No blocking skill or runner defect was found in this forward test. This is
   one successful scenario, not comprehensive method or runner validation.
2. Useful documentation improvement: include one longitudinal example using
   namespace-qualified nlme refits. On this installed nlme version,
   update(nlme::lme(...), method='ML') replays an unqualified lme.formula call
   and fails when nlme is not attached. That is an analyst/API compatibility
   issue, not a runner defect. Explicit nlme::lme(...) refits resolved it; the
   failed run's conditions.csv correctly records the error.
3. The routing fixture contains two context-dependent requests:
   package_missing lacks an explicit analysis objective when shown alone;
   harmful_selection is statistical but its rejection behavior cannot be
   inferred or tested from metadata alone. Keep routing and safe-execution
   expectations separate in any reported evaluation.
4. The metadata review below is not native automatic activation, and it is not
   blinded: the fixture contains expected annotations. Do not convert its
   judgments into an activation percentage or a universal reliability claim.

## Owner interpretation note

These are synthetic evaluation data, not an empirical programme result. The
script labelled the lack-of-linearity diagnostic `pass` while correctly stating
that non-significance does not establish linearity. Read that as successful
execution of a diagnostic, not validation of the assumption. The skill now
explicitly requires `assumed`/`not_assessed` for unverified assumptions. The raw
completed output is preserved rather than retroactively relabelled. This was a
documentation clarification; no claim of a new forward run is made. Native-host
automatic selection remains untested.

Portable copies of the code, input, main result and failed-attempt code/condition
are in this directory. The absolute scratch paths above retain execution
provenance; reproduce from these portable files with the runner and a new output
directory. Supplementary diagnostic artifacts remain in the original scratch
directory and are described above; they are not all bundled here.
