# WP11b — Statistical probes

Date: 2026-09-28. Implements the founder-approved D-033
[evaluation contract](probe-evaluation-contract.md). Development version
0.2.0.9000; not a new release of the public v0.2.0 binary.

## Delivered behavior

`llm_probe(labels ~ activations(layer = layers), trace, groups = source_ids,
test_groups = reserved_ids, seed = 42)` fits binary ridge probes with explicit
group-disjoint evaluation. It returns ordinary tables plus S3 print, summary,
plot and probability-prediction methods. Without evaluation groups, output is
explicitly exploratory CV, with no inferential interval.

Scaling, constant-column removal, lambda selection and default-layer selection
use development observations only. Grouped CV shares folds across layers.
Final coefficients are frozen before held-out scoring; prediction reuses their
saved transformations. Held-out intervals resample whole groups, conditional on
the fitted models and development/selection procedure. Small, undefined or
degenerate intervals are withheld with recorded reasons and counts.

In-memory and Arrow-spilled traces must have one position per prompt, identical
prompt/position/neuron coordinates across layers, and finite complete values.
Reads process one layer at a time. The materialized-workspace estimate includes
input, dense working copies, solver paths and retained output. It is checked
before R densification; reading an Arrow batch itself can allocate buffers first.
Spilling does not turn glmnet into an out-of-core solver.

No native code or dependency changes. `glmnet` remains optional Suggests under
D-020, with a classed installation remedy when unavailable. Other invalid inputs
and solver failures use `relm_error_probe`; budget refusal uses `relm_error_oom`.

## Numerical implementation and convergence regression

The solver uses the approved 41-point descending lambda grid, RMS scaling,
`alpha = 0`, no automatic standardization, `thresh = 1e-14`, `maxit = 1000000`,
`fdev = 0` and `devmax = 1`. Caller glmnet controls and seeded RNG state are
restored, including failure paths. Incomplete or nonconverged paths fail loudly.

The real-model paired-label control exposed a cold-start failure in the final
development refit: layer 6, 40 observations by 896 neurons, selected lambda
0.00158489319246111 (grid index 35), solver code -1 after the iteration limit.
The same fit converged along the fixed grid prefix through index 35. Final
refits therefore follow that prefix and retain only its selected endpoint.
No tolerance or acceptance threshold was weakened, and no held-out data enters
this correction. A regression distinguishes the prefix from a singleton/full
path and verifies endpoint extraction through public prediction.

The frozen independent fixtures remain unchanged. Both the ordinary full path
and all 82 separately fitted prefix endpoints pass coefficient, probability,
objective and KKT acceptance. For the endpoint comparison, maximum absolute
errors were respectively 2.04e-8, 4.37e-9, 4.91e-13 and 4.38e-9.

## Acceptance evidence

- Focused product and export tests: 29 blocks, 330 passing expectations, zero
  failures, warnings or skips. Covers holdout mutation, grouped split guards,
  ties, controls, solver errors, RNG restoration, trace/spill parity, memory
  preflight and saved-fit S3 behavior.
- `Rscript tests/probe-product/run.R --relm-library PATH`: installed-product
  agreement with all 82 frozen ridge roots, metric ties, RMS scaling and fixed
  cluster resamples. This mandatory gate fails if glmnet or fixtures are missing;
  it runs after R CMD check in every macOS/Linux release/oldrel CI leg.
- One independent integrated review approved the implementation; a narrow
  followup approved the warm-start correction and its regression.
- Source build with all three Quarto vignettes: passed. `R CMD check --no-install
  --no-manual` against the installed library: zero errors, warnings or notes;
  examples and documentation checks passed. Tests run separately because this
  check mode skips them.
- Complete installed-package suite: 1,177 passing expectations, zero failures
  or test warnings, 48 declared skips for opt-in model/network coverage. Native
  synthetic checks ran with Metal access; the dedicated Qwen workflow below
  supplies the real-model probe acceptance. The installed testthat package emits
  its R 4.5.2 build-version notice under local R 4.5.1.
- Installed-package Qwen Metal workflow: passed in 112.046 seconds, including
  both controls, saved-fit prediction and PDF rendering. The local R installation
  reused the unchanged native library below; CI builds the native source afresh.

PR #49 merged at `ecf3d3f` after all nine checks passed on candidate `67ad682`:
[R package matrix](https://github.com/Vadale/R-ebirth/actions/runs/36434776460),
[Rust/repository checks](https://github.com/Vadale/R-ebirth/actions/runs/36434776322)
and the additional [Linux CPU Demo A/probe workflow](https://github.com/Vadale/R-ebirth/actions/runs/36434815787).
The Linux run used R 4.6.1/glmnet 5.1. Its paired-label AUCs were 0.58, 0.4525
and 0.54 at layers 6/12/18; true labels and the lexical baseline scored 1, with
degenerate intervals withheld. The workflow retains full metrics/audit artifacts.
These remote outcomes supplement the local measurements below.

Local numerical environment: macOS arm64, R 4.5.1, glmnet 5.0. The final model
acceptance uses the existing validated native library, SHA256
`17ef12b92215a1bcaa211068ab10c62882b8e4be2bc8829f11909c23b95e1019`.

## Pinned model example and interpretation

`tests/demos/demo-probe-evaluation.R` uses the existing Qwen2.5-0.5B-Instruct
Q8_0 pin: revision `9217f5db79a29953eb74d5343926648285ec7e67`, model SHA256
`ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e`.
It captures the last position at layers 6, 12 and 18 of 80 synthetic prompts:
40 matched source pairs, 20 development groups, 20 untouched evaluation groups,
four development folds, seed 321.

The demonstration includes a simple feature baseline (text length plus the
explicit adjective) and a predeclared paired-label swap in half the development
groups, keeping true evaluation labels. These controls share folds. It saves
the corpus, split audit, metrics, swapped labels, base-graphics plot and solver/
session provenance. The existing Demo A nightly runs the same example on Linux
CPU and uploads those artifacts.

The [committed Mac measurements](evidence/probe-mac/metrics.csv) are:

| Analysis | Layer | Selected lambda | CV AUC | Held-out AUC | Conditional 95% interval |
|---|---:|---:|---:|---:|---|
| Activations | 6 | 10000 | 1.00 | 1.0000 | Withheld: degenerate |
| Activations | 12 | 10000 | 1.00 | 1.0000 | Withheld: degenerate |
| Activations | 18 | 10000 | 1.00 | 1.0000 | Withheld: degenerate |
| Simple features | — | 10000 | 1.00 | 1.0000 | Withheld: degenerate |
| Paired-label control | 6 | 0.001584893 | 0.42 | 0.5525 | 0.4025–0.6925625 |
| Paired-label control | 12 | 0.025118864 | 0.46 | 0.4925 | 0.3300–0.6600 |
| Paired-label control | 18 | 0.039810717 | 0.32 | 0.5800 | 0.4400–0.7225 |

All analyses had 2,000 defined resamples. The true-label probes selected the
largest grid penalty; ties select default layer 6. No grid tuning followed these
scores. Corpus, partition audit, fixed swap and session provenance accompany
the measurements in `docs/evidence/probe-mac/`.

This intentionally confounded example tests the workflow: a lexical baseline
already solves its labels. Perfect probe AUC would therefore establish neither
a unique representational discovery nor causal use. The fixed label swap is
one negative control, not a permutation p-value. Historical Demo A's selected
OOF bootstrap remains exploratory; the new API does not validate it retroactively.

## Remaining scope

Multiclass outcomes, multiple token positions per prompt, nested CV and
training/selection uncertainty are not implemented. Large-model spill acceptance,
Windows/CUDA and stronger-model comparisons remain separate work. The next
planned package is WP12a: a bounded service contract for the existing application,
with concrete limits and dependency approval before a service implementation.
