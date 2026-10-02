# Compact, inspectable analysis artifacts

Use the user's language for narrative outputs. Keep stable machine column names
in English. Output size follows the question; do not dump full model objects or
all rows into a chat. Prefer CSV tables and ordinary files over a dependency-heavy
reporting framework. Add JSON when a caller needs it and an authorized serializer
is available; missing numeric values are null, never invented zeros.

## File runner

```text
Rscript --vanilla scripts/run-analysis.R analysis.R new-output-dir input.csv [other-input-file ...]
```

Paths may contain spaces when correctly quoted by the calling shell. Inputs must
be existing files; output must be a new directory. There is no overwrite/resume
mode. Use the host's detached process/job support for lengthy computation.
`status.dcf` contains `running`, `complete` or `failed`; an interrupted process
may leave `running` and must never be interpreted as completion. The runner is
an evidence helper, not a process supervisor or a sandbox.

The trusted analysis script is sourced in a fresh environment with:

- `input_paths`: absolute declared input paths, read only by convention;
- `output_dir`: absolute output directory, for figures and optional artifacts.

Its **last expression** must return a named list:

```r
list(
  summary = c("Plain-language finding with magnitude and uncertainty."),
  estimates = data.frame(
    result_id = "primary", outcome = "measurement", term = "group difference",
    estimate = 1.2, conf_low = 0.1, conf_high = 2.3, conf_level = 0.95,
    scale = "difference", units = "points", n = 80L,
    method = "Welch confidence interval", status = "exploratory"
  ),
  diagnostics = data.frame(
    check = "independence", status = "assumed",
    detail = "One row per participant, according to supplied design."
  ),
  limitations = c("The observational design does not identify a causal effect.")
)
```

These numbers illustrate the schema only; calculate every delivered value from
the actual analysis. Required estimates columns: `result_id`, `term`, `estimate`,
`conf_low`, `conf_high`, `conf_level`, `scale`, `units`, `n`, `method`, `status`.
Additional columns (outcome, group, p_value, adjustment, estimand) are welcome.
Use `NA` for unavailable uncertainty and explain why. Label interval type in
`method`, including bootstrap/credible intervals; `conf_level` is the nominal
coverage/credibility level. `n` means analytic observations; add `n_clusters`,
`n_events` or effective sample size when that changes interpretation. Descriptive
results may have no interval. Result status: `ok`, `exploratory` or `withheld`.
Diagnostics status: `pass`, `warn`, `fail`, `assumed` or `not_assessed`.

The runner writes `summary.md`, `estimates.csv`, `diagnostics.csv`,
`conditions.csv`, `session-info.txt`, `manifest.csv`, `analysis.R` and
`status.dcf`. MD5 fingerprints detect accidental input/code changes; they are
not authentication or a security guarantee. Warnings remain in `conditions.csv`
and a warning count appears in the summary. `complete` means execution and
artifact validation succeeded; it does not certify scientific validity.
On error, preserve status/conditions/session information, report failure and
inspect that failure before retrying. Nonzero exit is failure.

## Interpretation and plots

Lead with the answer, population/comparison, effect size and interval, then the
practical implication and main limitation. Reference rows by `result_id` so an
assistant can trace a claim to a number. Include diagnostic failures as prominently
as the main finding. For ratios, label the reference category and ratio scale;
for probabilities, distinguish absolute percentage points from relative changes.

Select a useful plot rather than adding one mechanically: estimate/interval plot,
observed versus fitted, survival curve or an appropriate residual diagnostic.
Label units, groups, interval meaning and sample size; use accessible colors.
Use base graphics or suitable installed packages and save standard PNG/PDF/SVG.
Keep extra tables in separate files if necessary; do not flatten a complex study
into a single unsupported score. Scripts should write UTF-8 CSVs with explicit
missing values; treat imported text/formula-like cells as data, including when
opening exports in a spreadsheet application.
