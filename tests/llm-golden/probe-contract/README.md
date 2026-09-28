# WP11a statistical reference contract

These new-feature fixtures freeze reference semantics **before `llm_probe`
implementation**. They neither implement that API nor accept product behavior.
No existing native golden is regenerated. They run without a model or native
build: CI should invoke the Python checker and `verify.R --numerical` after
installing the already approved `glmnet` Suggests dependency.

From the repository root, using the existing pinned Python 3.13 environment:

```sh
.golden-venv/bin/python tests/llm-golden/probe-contract/reference.py --check
Rscript tests/llm-golden/probe-contract/verify.R --numerical
.golden-venv/bin/python tests/llm-golden/probe-contract/reference.py --audit tests/llm-golden/probe-contract/split-valid.csv
```

`--audit split-holdout-leak.csv` and `--audit split-cv-leak.csv` must exit nonzero.
Both checkers execute these negative cases themselves. R uses only base R for
metrics, preprocessing and audit; `glmnet` is only the comparison solver. Without
`--numerical`, R compares the solver if installed and explicitly skips it otherwise.
With `--numerical`, a missing solver is an error. There are no new dependencies.

`reference.py --write` is the generator, under the project's `golden-update`
procedure. Reason: **WP11a freezes independent statistical oracles before
llm_probe implementation**. `provenance.json` records byte counts and SHA256 for
every CSV plus the generator, independent R verifier and this README. `--check`
verifies those bytes and recomputes every generated CSV. These are portable
12-significant-digit statistical references, not machine-specific native float
goldens; there is no native `.machine` comparison or tolerance regeneration.

The ridge objective is mean binomial negative log likelihood plus
`lambda / 2 * sum(beta^2)`, with an unpenalized intercept. The 41 lambdas are
`10^seq(4, -4, length.out = 41)`. Standardization uses training means and RMS
scales `sqrt(mean((x - mean(x))^2))`, dropping constant columns. The separable
four-corner case has intercept and nuisance coefficient zero; at lambda 1,
`beta1 = 0.4010581375...`. The nonseparable case has unequal prevalence and a
nonzero intercept. Both have balanced nuisance coordinates within each `(x1,y)`
combination; convexity gives `beta2 = 0`. Python profiles the intercept by scalar
bisection and then bisects the remaining slope gradient, without glmnet or a
general optimizer. R checks coefficients (relative/absolute tolerance `2e-5`),
probabilities (`2e-6`), objective (`2e-9`) and KKT residuals (`2e-7`). Both input
columns vary; the future one-surviving-column path may internally add a zero
padding column for glmnet, excluding it from reported coefficients.

Tie-aware AUC uses explicit positive/negative pair counts in Python and average
ranks in R. The original `[0,1,0,1]` / `[.1,.2,.2,.1]` case has **AUC .5**
(1 win, 2 ties, 1 loss); changing the final score to zero yields **.375**
(1 win, 1 tie, 2 losses). Classification uses `score >= .5`, including equality.
A constant-score control has AUC .5; a perfect lexical confound has AUC 1 and
does not establish representation-specific utility. A fixed permuted-label
control gives AUC .5. Fold diagnostics take the arithmetic mean across folds;
unequal fold sizes expose accidental row-weighted averaging.

Bootstrap draws expand whole groups with replacement, preserving repetitions
and unequal cluster sizes. The eight explicit mixed draws are a compact oracle,
**not a 2,000-draw product run**. Production calls for 2,000 draws and type-7
95% quantiles. Extra fixture cases with single-class draws or a degenerate
interval require withholding the interval, reporting the reason and number of
undefined draws, without silently redrawing. The validation extreme in the
scaling fixture must not affect training center, scale or dropped columns.
The compact bootstrap fixtures verify raw percentile arithmetic. Their three
groups cannot support a displayed product interval: separate display-policy
fixtures require at least 20 groups and 5 groups containing each class, and
pin undefined, degenerate and no-evaluation statuses. Split CSVs use `train`
as the reference name for the product's development partition; audits require
at least three folds. They test group identity isolation, not label feasibility.

WP11b still needs executable product mutation guards: holdout changes cannot
alter fitted parameters, preprocessing or model/layer/lambda selection; group
identities cannot cross train/test or CV boundaries; CV preprocessing is fitted
inside each training fold; selection and controls use only training data;
sampled/group bootstrap and all uncertainty policies use the frozen semantics;
memory budgets include materialized R objects. The split audit here is executable
reference validation, not evidence that an unimplemented product prevents leakage.
