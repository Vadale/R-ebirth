# WP11a — Probe evaluation contract

Date: 2026-09-28. Status: **proposal for founder approval (D-033)**.
This freezes the evaluation and reference requirements for WP11b. It does not
implement `llm_probe()`, change an approved signature or certify Demo A's
historical estimates. No new dependency: `glmnet` remains an optional Suggests
dependency under D-020; absent installations get an actionable classed error.

**Acceptance (verbatim, structured production plan):** A split audit detects
leakage; independent statistical reference fixtures and their expected outcomes
are recorded. Any required API/dependency amendment is approved before WP11b.

## 1. Decision and scope

Use caller-declared, group-disjoint evaluation data, with grouped cross-validation
only on the remaining development data. Choose regularization and the default
layer on development data; freeze the fits before scoring evaluation groups.
This gives a tractable first implementation on the 16 GB Mac. Nested CV and
resampling the entire training/selection procedure are deferred.

CV used to select parameters is a selection diagnostic, not an independent
estimate of the selected model's generalization performance. Repeatedly inspecting
the holdout to change layers, labels, preprocessing or the grid consumes it;
later comparisons need untouched groups. The package can enforce partitions in
one call, but cannot enforce the researcher's choices across calls.

The statistical unit is **one captured position per prompt**, initially the
existing `positions = "last"` workflow. Binary ridge logistic probes only;
decodability is association, not evidence that the model causally uses a feature.
No new native engine work or larger-model benchmark belongs to WP11a/b.

## 2. Proposed public amendment

```r
llm_probe(formula, data, method = "glmnet", cv = 10,
          metric = c("auc", "accuracy"), seed = NULL,
          groups = NULL, test_groups = NULL)
```

Existing arguments keep their positions. The formula remains
`label ~ activations(layer = 10:20, component = "residual")`; no extra export.

- `groups`: character group IDs, one per captured prompt in increasing
  `prompt_id` order. A named vector instead matches by the exact character
  representation of each `prompt_id`; names must be unique and exhaustive.
  IDs must be nonmissing and nonempty. `NULL` uses each prompt ID as a group,
  an explicit independence assumption, not inferred independence. Related
  source documents, revisions, paraphrases and matched contrasts must share a
  group supplied by the caller. No hidden trace attribute supplies grouping.
- `test_groups`: a nonempty character vector of unique, known group IDs reserved
  before analysis. Every observation in these groups is excluded from fitting,
  preprocessing and selection. `NULL` returns **exploratory CV only**, with no
  held-out metric or inferential interval; `character(0)` is rejected.
- `cv`: a single integer at least 3; the same group-disjoint development folds
  serve all layers and lambda values. Never silently reduce it when infeasible.
- `metric`: `match.arg()` selects AUC (default) or accuracy for selection and
  reporting. Accuracy uses probability >= 0.5, with no threshold optimization.
- `seed`: `NULL` or a nonnegative integer in R's supported seed range. A supplied
  seed temporarily controls fold assignment and bootstrap draws, restoring the
  caller's RNG state (including its prior absence); `NULL` uses the caller's RNG.

`predict.llm_probe(object, newdata, layer = NULL, ...)` returns probabilities for
the positive class; the default layer is always the development-CV selection.
It uses the saved development-only fit and preprocessing, even after holdout
evaluation. It never silently refits using evaluation labels.

The `llm_probe` class retains per-layer fits and CV metrics, adding separate
held-out metrics, split audit and uncertainty metadata. `plot()` draws held-out
metrics and available pointwise intervals when supplied, marking the layer
selected on development data. Without a holdout it draws an explicitly labelled
exploratory CV curve, **without confidence intervals**. It does not choose the
highest point on the held-out curve. `summary()` exposes the audit below.

This amends the Phase 4 evaluation/CI semantics in API-GRAMMAR §§2/5 as well as
adding two arguments. Approval must cover both, not just their names.

Proposed usage (not runnable until WP11b); prompts, labels, source IDs and the
reserved source IDs are prepared before looking at evaluation results:

```r
tr <- llm_trace(m, prompts, layers = 10:20, positions = "last")
fit <- llm_probe(label ~ activations(layer = 10:20), tr,
                 groups = source_id, test_groups = reserved_ids, seed = 42)
summary(fit)
plot(fit)
```

## 3. Alignment and validation

1. Resolve the requested layers/component and collect prompt/position identities
   before fitting. Require the same prompt IDs and position for each prompt
   across layers (the position may differ between prompts), and complete, unique
   neuron coordinates. Multiple positions, duplicate coordinates,
   missing layers or nonfinite values are errors; never average or drop them.
2. A label column on an in-memory long trace must be constant within each prompt
   and is collapsed to one label per prompt. An external label vector has one
   element per prompt, ordered/named as above. A spilled zero-row proxy uses an
   external vector; do not mistake its `nrow()` for the observation count.
3. Accept logical, numeric 0/1, or a two-level factor (second level positive).
   Record the mapping. Reject missing labels, extra/missing names, ambiguous
   formula shapes, interactions/covariates, and unknown methods. A predictor
   formula contains exactly one `activations()` marker.
4. Audit group separation before fitting. Require both classes in development,
   every CV fitting/validation partition, and the final evaluation partition.
   Require at least two observations per class in every fitting partition for
   the solver. Return counts and a concrete remedy when unsupported; warnings
   about small class counts remain visible.
5. Invalid inputs and solver failures reach R as `relm_error_probe` with `reason`
   and relevant layer/fold/counts. No partial result presented as a complete fit.
   OOM preflight uses `relm_error_oom`, with estimated and allowed bytes.

`newdata` must match the trained component/neuron coordinates and observation
contract; labels and training group IDs are not needed to predict new prompts.
The result is a numeric vector in increasing prompt-ID order, named by those IDs.

## 4. Development-only preprocessing and selection

**Fold allocation v1:** operate only on development groups and their class counts.
Sort groups by decreasing observation count; seeded random ranks break ties.
For each group, assign it to the fold minimizing the sum, over all folds and
both classes, of squared deviations from target class counts (`class_total/cv`),
normalized by squared class totals. A seeded permutation of fold IDs breaks
cost ties. Audit the final partition and fail with counts if either class is
missing; an allocation failure does not prove that every possible partition is
infeasible. Suggest another seed, fewer folds or more independent groups.
Record the realized assignments, not just the seed. Evaluation labels/features
must not affect allocation.

For each layer and each fitting partition:

- Center by its feature means; scale by `sqrt(mean((x - mean(x))^2))` (RMS, not
  sample SD). Drop exactly constant columns using that partition only. Save
  means, scales and retained neuron IDs; apply them unchanged to validation.
- No imputation, PCA, global standardization or feature selection. If no columns
  remain, fail explicitly. If only one remains, the solver may receive a second
  all-zero column to satisfy glmnet's matrix interface; discard that known-zero
  coefficient and preserve the single-feature objective in the returned fit.
- Fit binary logistic ridge with `alpha = 0`, an unpenalized intercept and
  `standardize = FALSE`. The objective is mean binomial negative log likelihood
  plus `lambda / 2 * sum(beta^2)`. Use the fixed descending grid
  `10^seq(4, -4, length.out = 41)`; never derive it using validation data.
- Check convergence and that every requested lambda was fitted. A truncated
  path or solver error fails with layer/fold context; do not select among only
  the successful fits. Do not mutate global glmnet settings without restoring
  them. WP11b pins explicit solver tolerances against the independent oracle.

Selection score is the unweighted mean of per-fold AUC or accuracy. It is not
pooled across predictions from differently fitted models, and has no inferential
standard error. Select each layer's lambda by the highest score, breaking ties
within `1e-12` in favor of the largest lambda. Select the best layer similarly,
breaking ties by the smallest layer index. Record selections at grid boundaries;
do not expand the grid automatically after viewing evaluation results.

Refit each layer with its chosen lambda and fresh preprocessing on **development
data only**. Freeze coefficients, transformations and the selected layer before
computing held-out metrics. A held-out-label or feature mutation may change
evaluation results, but cannot change any fitted quantity or selected parameter.

## 5. Metrics and honest intervals

AUC is the positive-negative pair win fraction with half credit for tied scores.
Accuracy is the fraction of correct labels at threshold 0.5. Evaluation metrics
pool observations: larger groups contribute more prompts. This is not the
equal-weight mean of per-group metrics. Report both prompt and group counts.

Bootstrap **whole evaluation groups**, drawing G group IDs uniformly with
replacement G times per replicate, retaining every row and repeated multiplicity.
Use 2,000 draws and percentile quantiles of type 7 at 0.025/0.975. All layers use
the same draws. Predictions remain frozen; there are no model refits here.

Report intervals as: **Approximate 95% pointwise intervals for held-out sampling
variability, conditional on the fitted models, development data, selection and
split.** This assumes independent, representative groups. It does not include
training/selection variability, guarantee coverage, cover distribution shift,
provide simultaneous coverage across layers, or justify selecting a layer from
the evaluation curve.

Conservative display rules (operational guards, not precision guarantees):

- Withhold intervals below 20 evaluation groups or fewer than 5 groups containing
  either class. Keep the point estimate and show counts/reason.
- Count undefined bootstrap draws (e.g. single-class AUC). If any occur, withhold
  that interval. Do not silently discard/redraw them. Accuracy can remain defined.
- Withhold a zero-width interval and report `degenerate_bootstrap`; observed
  perfect predictions do not establish population certainty.
- CV-only results carry `not_evaluated`, not a bootstrap of selected OOF scores.

The split audit table has one row per prompt: `prompt_id`, `group`, `partition`
(`development` or `test`), `fold` (NA for test) and encoded `label`.
Results also record class/group counts, label mapping, layers/component,
lambda grid, CV scores, chosen lambda per layer, chosen default layer, boundary
flags, seed/RNG kind, preprocessing, solver/version details, held-out predictions,
bootstrap valid/undefined counts, interval bounds/status and protocol version.
Use plain data.frames/matrices and a classed list; no filesystem side effects.

## 6. Controls and the anatomy workflow

The accepted WP11b example runs probes beside a frozen simple-feature baseline
(prompt character count and predefined lexical indicators), with the same split,
fold-local preprocessing, ridge grid and evaluation rules. Indicators must be
fixed on development material before holdout inspection.

A shuffled-label control reruns the **whole development selection procedure**.
For the homogeneous-group fixture, permute complete group labels; for paired
contrasts, use a predeclared within-pair swap. Do not shuffle dependent rows
independently, claim a formal permutation p-value from one shuffle, or require a
small random realization to score exactly 0.5. Keep the true held-out target for
the negative-control evaluation. Record the permutation and its seed.

The controlled null fixture has exactly 0.5 AUC by construction; the lexical
confound has perfect simple-feature separation. These are numerical/behavioral
controls, not accuracy promises for real model activations.

Demo A's existing CV-selected OOF bootstrap and layer search remain historical
exploratory evidence. WP11b adds a correctly labelled short workflow and a
separate evaluated example with a predeclared source-group split. Reusing Demo A
after inspecting it is not a fresh scientific holdout. About five lines measures
API usability, not statistical acceptance.

## 7. References, memory and WP11b acceptance

Independent fixtures and commands live in
[`tests/llm-golden/probe-contract/`](../tests/llm-golden/probe-contract/README.md).
The Python oracle does not import relm or glmnet; the R verifier checks its
results independently. Existing native goldens are unchanged. These references
are prerequisites, **not tests of a product implementation that does not exist**.

WP11b must add these meaningful product gates:

| Gate | Expected outcome |
|---|---|
| Group split | Repeated source groups never straddle partitions/folds; deliberately leaky allocation is rejected |
| Independent numerics | Ridge coefficients/probabilities, tie-aware AUC, accuracy, RMS scaling and fixed cluster resamples agree with committed references |
| Holdout mutation | Changing held-out labels/features changes no development fold, transformation, coefficient, lambda or chosen layer |
| Fold mutation | A validation-only extreme changes no transformation fitted without that fold |
| Selection | Constructed layer/lambda ties follow frozen rules; swapping the winning held-out layer does not change default prediction |
| Controls | Whole-procedure shuffled-label and simple-feature controls run on frozen data; no causal claim from decodability |
| Trace parity | Shuffled long-row order and spilled/in-memory traces yield identical prompt alignment and predictions; duplicate/missing coordinates or a per-prompt position mismatch between layers fail |
| Error/RNG paths | Classed missing dependency, invalid labels, infeasible folds, failed/truncated fit; seeded calls preserve caller RNG |
| Memory | One layer/fold at a time, budget measured in materialized R bytes, over-budget refusal before densification |
| S3 usability | Short formula workflow, useful summary, held-out/exploratory plot labels, probability predictions with training-selected default |

Use lazy per-layer trace reads and release CV fits promptly. Retain final
coefficients and compact metrics/predictions, not all fitted paths. WP11b must
derive and test a conservative peak-byte estimate covering slice conversion,
copies, solver workspace and accumulated output. Reuse the existing trace budget
as a ceiling; a slice that cannot be fitted within it raises a classed error
with narrower-capture guidance. Reading a spilled trace does not make glmnet an
out-of-core solver. No new disk-writing probe or silent memory-limit override.

Checks run without model downloads in the existing Mac/Linux R CI matrix.
The pinned anatomy model is an additional model-gated integration check in
WP11b; no unchanged native rebuild or new model benchmark is needed for WP11a.

## Local verification (2026-09-28)

Python 3.13.5 in the pinned golden environment verified 17 CSV artifacts and
source SHA256 provenance, including 82 independent ridge solutions. R 4.5.1 with
glmnet 5.0 passed the separate metric, bootstrap, scaling, fold, split and
solver comparisons. The valid split passes; both deliberate leakage fixtures
exit nonzero. Requiring numerical verification with glmnet unavailable also
fails, preventing a skipped solver check from passing CI. Tiny synthetic cases
retain the solver's expected small-class warnings.

The fixtures and protocol received one integrated independent review. The
per-prompt token position must match across layers; that ambiguity was clarified.
All 20 source/reference artifact byte counts and SHA256 pins were verified. A
bounded one-ULP perturbation of the oracle math functions left the serialized
CSVs unchanged; actual Mac/Linux CI remains the cross-platform check.
GitHub CI hooks run the Python artifact check and R `--numerical` verifier;
local outcomes above do not claim the new remote run has completed. D-033 remains
proposed and WP11b product behavior remains unimplemented.

## 8. Statistical sources and interpretation

- [Cawley and Talbot (2010)](https://www.jmlr.org/papers/v11/cawley10a.html):
  optimization of a model-selection criterion can bias subsequent evaluation.
  This motivates the separate holdout; it does not prescribe our API.
- [Bengio and Grandvalet (2004)](https://jmlr.csail.mit.edu/papers/v5/grandvalet04a.html):
  overlapping CV fits invalidate treating fold scores as independent replicates.
  We therefore do not attach a naive fold-based CI to selection scores.
- [glmnet reference](https://glmnet.stanford.edu/reference/cv.glmnet.html):
  `foldid` supplies allocations; `grouped = TRUE` summarizes fold statistics,
  not source-document grouping. Our explicit preprocessing/grid protocol uses
  `glmnet()` fits rather than relying on a full-data CV master path.
- [Hewitt and Liang (2019)](https://aclanthology.org/D19-1275/): control tasks
  help distinguish probe behavior from represented information. Our shuffled
  and simple-feature controls are specific checks, not a reproduction of every
  control in that paper and not a causal identification strategy.

The fixed holdout, conditional cluster intervals and display thresholds are the
project's proposed design choices; they are not claimed as universal guarantees.
