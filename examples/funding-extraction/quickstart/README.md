# Six notices to a reviewable CSV

Extract the **total programme budget** and a supporting quotation from six short
notices using a local model and R. Keep absent amounts missing, compare every
answer with an explicit expectation, and save a CSV for review.

This is a small starting point for document analysis, not an automated funding
decision system. The notices are **synthetic**: invented programmes and amounts,
no real organisations, personal records or clinical data. The data, labels and
script are original example material under the repository's
[MIT OR Apache-2.0 licence](../../../LICENSE.md); you may redistribute and adapt
them under those terms. The model has its own Apache-2.0 licence.

## Inspect before downloading anything

- [Inputs](notices.csv): six notices, including missing totals and distracting numbers.
- [Expected values](expected.csv): labels written before generation, with the exact
  evidence clause required for each stated amount.
- [Recorded run](recorded/README.md): raw answers, per-case review, measured time,
  memory and limitations. No model is needed to read these files.
- [R script](run.R), [prompt](prompt.txt), [schema](schema.json) and
  [settings](settings.json): the complete procedure. No hidden notebook state.

| Notice | Expected total (EUR) | What can go wrong |
| --- | ---: | --- |
| Cedar 2026 | 250000 | Direct total |
| Harbour 2026 | missing | A 40000 per-project cap is not the programme budget |
| Meadow 2026 | 120000 | Do not use the previous year's 90000 |
| Riverside 2026 | 300000 | Do not take a neighbouring programme's 700000 |
| Orchard 2026 | missing | Participant counts are not money |
| Willow 2026 | 600000 | Do not substitute the first year's 200000 |

## Prepare

Use a local checkout of this repository, **R >= 4.5**, installed **relm >= 0.6.1**,
and **jsonlite 2.0.0**. jsonlite is the existing application-only dependency of
[the funding example](../README.md); it is not a relm package dependency. No Python
is needed. Follow [relm installation](../../../docs/getting-started.md) first.

If jsonlite is absent, install 2.0.0 in your R library. A matching binary from your
configured repository avoids compilation; verify its version. The exact source
was available at this URL when the recipe was recorded:

```r
install.packages(
  "https://cran.r-project.org/src/contrib/jsonlite_2.0.0.tar.gz",
  repos = NULL, type = "source"
)
stopifnot(as.character(packageVersion("jsonlite")) == "2.0.0")
```

Installing from source needs a C compiler. When CRAN moves this version, use its
[jsonlite archive](https://cran.r-project.org/src/contrib/Archive/jsonlite/).
The script refuses another version instead of silently changing the reference
environment.

Run these commands from the repository root. Choose writable model, result and R
temporary directories on a disk with enough space. Keep at least 1.12 GB for the
model plus working memory; file size is not a RAM estimate.

```sh
# Offline checks: no model loading or download.
Rscript --vanilla examples/funding-extraction/quickstart/run.R check

# Explicit online preparation: about 1.12 GB, verified by SHA256.
Rscript --vanilla examples/funding-extraction/quickstart/run.R download .recipe-models

# Inference: uses only the verified local file; no download in this step.
Rscript --vanilla examples/funding-extraction/quickstart/run.R run .recipe-run .recipe-models
```

The `.recipe-run` directory must not exist. A repeat uses a new directory so the
first run and its mistakes survive. Set `TMPDIR` before launching R if its normal
temporary location has a small quota. Do not commit model files or local reruns.

The fixed model is Qwen2.5-1.5B-Instruct Q4_K_M, with four CPU threads, a 2048-token
context, temperature zero, seed 231023 and at most 192 generated tokens per
notice. Model identity and all settings are in [settings.json](settings.json).
The script verifies its bytes, loads one handle, processes the notices in order
and closes the handle. It does not tune prompts, retry, repair output or invoke
tools suggested by the text. Seeds do not promise byte-identical results across
machines or package builds.

## Read the result

```r
review <- read.csv(".recipe-run/review.csv")
review[c("id", "amount_eur", "expected_eur", "passed")]
# Inspect evidence and the source notice before using any extracted amount.
```

`results.csv` preserves the complete JSON for each attempt, or the error class,
message and available partial output. A successful call has `status = "ok"`;
that says nothing about the facts. `review.csv` separately scores the amount and
quotation. Missing totals require **both fields to be null**. For a stated amount,
the quotation must be a contiguous substring of the notice containing the
predeclared evidence clause. This simple rule is specific to these toy cases;
it is not a general entailment test.

`metrics.json` reports model verification, model load and total generation time,
plus the R process's peak resident memory on Linux (`VmHWM`). RSS is unavailable
on other platforms. Download/install time is excluded. `provenance.json` records
R, relm source/build identity and settings; `inputs.csv` hashes the copied inputs
and executed script. The output directory keeps those copies alongside the
answers. Expected labels are used only by the evaluator, never in model prompts.

Recalculate the review without loading a model:

```sh
Rscript --vanilla examples/funding-extraction/quickstart/run.R score .recipe-run
```

Use the copied `run.R` inside an older output directory when its input files
have changed; the root script evaluates against the current adjacent dataset.
An interrupted run can contain partial rows and has no final metrics; scoring
refuses missing or reordered cases. For resumable work use the
[batch application](../README.md).

## Errors, costs and limits

- **Missing/corrupt model:** the run stops before loading; prepare the pinned file.
- **Context/output budget or invalid structured output:** the failed attempt is
  retained and scored as failed. No automatic repair or retry masks the error.
- **Valid JSON with a wrong value or quotation:** keep it, flag it, review the source.
  Do not use `status = "ok"` as an accuracy label.
- **Cost:** local inference makes no paid API calls, but download, compute,
  electricity and review have costs. Only the recorded timing, file size and
  memory are measured here; monetary cost, energy and review time are unmeasured.

The labels were authored and reviewed by the same assistant as the recipe, not
by independent domain experts. Six deliberately simple cases and one CPU pass
are a demonstration, not a holdout, population accuracy estimate, throughput
benchmark or evidence that an LLM beats a regular expression. Existing
[negative extraction findings](../../../docs/d1-extraction-evaluation.md) still
apply to their original task. Real PDFs, OCR, tables, currencies and ambiguous
budgets need additional data and human evaluation.

The offline `check` command belongs to the Linux-release R-CMD-check job. Actual
model generation is a separate, explicit **[MODEL]** recipe run; ordinary PR
checks never download the model. This recipe does not establish Windows ARM64,
WebAssembly, GPU or clinical-use support.
