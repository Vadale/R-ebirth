# relm

<!-- badges: start -->
[![R-CMD-check](https://github.com/Vadale/R-ebirth/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/Vadale/R-ebirth/actions/workflows/R-CMD-check.yaml)
[![r-universe](https://vadale.r-universe.dev/badges/relm)](https://vadale.r-universe.dev/relm)
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](https://github.com/Vadale/R-ebirth/blob/main/LICENSE.md)
<!-- badges: end -->

**Local language models as base-R objects.**

relm runs open-weight models on your machine with no Python, model server or
API key. Generate text and constrained JSON, embed documents, and inspect a
model's internal values using ordinary R vectors, data frames and matrices.
Its Rust core embeds a pinned, patched llama.cpp; R remains your working
environment for statistics, visualization and reproducible research.

**Version 0.3.0** adds structured generation, native Spark support, statistical
probes, and separate batch/service examples. See the
[release notes](https://github.com/Vadale/R-ebirth/blob/main/rebirth/NEWS.md#relm-030).
Binary availability follows r-universe builds; check `packageVersion("relm")`
after installation.

## Installation

Use [r-universe](https://vadale.r-universe.dev/relm) for macOS and Linux builds:

```r
install.packages(
  "relm",
  repos = c("https://vadale.r-universe.dev", getOption("repos"))
)
packageVersion("relm")
```

r-universe tracks `main`; check the version before using the 0.3.0 features.
Prebuilt binaries need no native toolchain. Source installation needs R >= 4.5,
Rust >= 1.85.0, CMake >= 3.28 and a C/C++ compiler. See the
[installation guide](https://github.com/Vadale/R-ebirth/blob/main/docs/getting-started.md)
for source builds and troubleshooting. Windows/CUDA acceptance is still pending.

The only required R dependency is `nanoarrow`, which reads spilled traces.
`glmnet` is optional for probes; `uwot` and `dbscan` are optional demo packages.
Optional `later` and `promises` enable development async/streaming generation.
Application examples prepare their own separate dependency environments.

## Development: asynchronous token data

After the 0.3.0 tag, `llm_generate(async = TRUE)` keeps generation on a native
worker. The WP10 development interface adds `on_token`: short callbacks receive
bounded plain-data-frame batches of token IDs, committed text and prompt-end
events. The promise still resolves to the ordinary named text vector and seed.
A caller-owned binary file connection can receive UTF-8 CSV instead.
Check `"on_token" %in% names(formals(llm_generate))` for installed support.

```r
pending <- llm_generate(m, "Explain a confidence interval.", seed = 17,
  async = TRUE, on_token = function(batch) {
    cat(paste0(batch$text[batch$event == "text"], collapse = ""))
  })
observed <- promises::then(pending, function(value) print(value),
  onRejected = function(error) message(conditionMessage(error)))
```

Load `m` as in the quickstart below and install optional `later`/`promises` first.
Callbacks run on R's main thread; slow callbacks or storage can block R and
backpressure the worker. `llm_cancel(m)` is cooperative. See the
[token-streaming guide](https://github.com/Vadale/R-ebirth/blob/main/rebirth/vignettes/token-streaming.qmd)
for the event schema, CSV and rolling statistics. Live activations and changing
interventions during generation are separate future work.

## Quickstart

The small Qwen model below is approximately 675 MB. `llm_download()` verifies
the pinned Apache-2.0 model by SHA256 and reuses a matching cached copy.

```r
library(relm)

path <- llm_download("qwen2.5-0.5b-instruct-q8_0")
m <- llm(path)

llm_generate(m, "The capital of France is", chat = FALSE,
             max_tokens = 8, temperature = 0)

# Embeddings are numerical representations of text: one matrix row per input.
emb <- llm_embed(m, c("cats", "kittens", "quarterly revenue"))
tcrossprod(emb)  # cosine similarities between normalized rows

# Activations are the numerical values inside the model at a selected layer.
tr <- llm_trace(m, "The movie was wonderful.",
                layers = 12, positions = "last", components = "residual")
as.matrix(tr, layer = 12, component = "residual")
```

`llm_tokens()` also converts text to token IDs, and `llm_logits()` returns the
next-token distribution as a data frame. Capture filters keep traces small;
traces over the configured budget spill to disk and are read a slice at a time.
The full 4B-model spill acceptance on a 16 GB Mac remains an open hardware check.

## Structured output in 0.3.0

Pass JSON Schema text to the existing generation function. This example reuses
the model loaded above and returns a JSON string:

```r
schema <- '{
  "type": "object",
  "properties": {
    "sentiment": {"type": "string", "enum": ["positive", "negative"]}
  },
  "required": ["sentiment"],
  "additionalProperties": false
}'
llm_generate(m, 'Classify the sentiment of "I loved this film." Return JSON.',
             schema = schema, max_tokens = 64, temperature = 0)
close(m)
```

Successful calls return complete, validated JSON. Unsupported schemas fail
before generation; incomplete output raises a classed R condition. The supported
profile includes closed objects, bounded strings and integers, string enums,
booleans and null. Arrays, general JSON Schema, image inputs and nonempty stop
sequences are outside this mode. Schema validation establishes format, not
factual correctness. Ordinary text and image generation retain `schema = NULL`.

Spark-X2.5-4B is also supported natively through llama.cpp b10828. Its optional
`spark-x2.5-4b-q8_0` alias downloads the official 4.38 GB GGUF. Constrained chat
uses Spark's official non-thinking opener. **Spark activation tracing is
unsupported** until an independent numerical reference exists.

## Investigate model behavior

`llm_probe()` fits binary ridge models to activation traces using a formula with
`activations()`. A probe asks how readily a label can be predicted from internal
model values. Explicit source groups keep related prompts together during
cross-validation; preprocessing and layer/regularization selection use development
data only. Reserve `test_groups` before analysis for held-out evaluation and
conditional group-bootstrap intervals. Without a holdout, results are labelled
exploratory and carry no inferential interval.

Use `summary()`, `plot()` and `predict()` on the fitted probe. The
[anatomy-lab vignette](https://github.com/Vadale/R-ebirth/blob/main/rebirth/vignettes/anatomy-lab.qmd)
explains grouped evaluation and saved-fit prediction. The complete
[probe evaluation script](https://github.com/Vadale/R-ebirth/blob/main/tests/demos/demo-probe-evaluation.R)
runs a paired-source example with paired-label and simple-feature controls.
Predictive decodability does not establish causal use.

For interventions, `llm_steer()` adds a chosen direction to the residual stream,
the values passed between model layers. `llm_ablate()` fixes selected units to a
value to investigate their effect. Both return a fresh model context over shared
weights; the original handle remains available for an exact reversal. A runtime
check refuses an intervention it cannot verify rather than silently doing nothing.
These are instruments to audit and investigate behavior, not guarantees of safety
or bias removal.

## Images and worked demos

Since 0.2.0, vision-language models accept JPEG, PNG and BMP inputs through
`llm_generate(images = ...)` and `llm_embed(images = ...)`. Load the model with
its companion `llm(projector = ...)`: the projector translates images into
values the language model can read. Interpretability of the vision encoder itself
is outside the current release.

Three vignettes provide complete workflows with pinned Apache-2.0 models:

- **The anatomy lab:** activation traces, statistical probes and interventions.
  Open `vignette("anatomy-lab", package = "relm")`.
- **Topic modelling without Python:** embeddings, UMAP, HDBSCAN and model-generated
  cluster names. Open `vignette("topics-without-python", package = "relm")`.
- **Seeing machines:** generate test images, ask about them and compare image/text
  embeddings. Open `vignette("vision", package = "relm")`.

![A topic map with eight automatically named clusters](man/figures/topic-map.png)

*Recorded Demo B output on 500 abstracts. The figure illustrates this corpus and
model run; it is not a general clustering-quality benchmark.*

## From an R session to a repeatable application

The repository includes two application templates, separate from the core API:

- [Restartable funding extraction](https://github.com/Vadale/R-ebirth/blob/main/examples/funding-extraction/README.md):
  explicit setup, offline execution, immutable results and verified resume.
- [Local funding service](https://github.com/Vadale/R-ebirth/blob/main/examples/funding-service/README.md):
  one loopback HTTP frontend, one persistent model worker, one active request,
  no job queue, durable tickets and recovery commands.

Their Mac/Linux operational acceptance includes interruption recovery and
1,000 same-worker service requests. Exact source provenance, limits and prior
failures remain in the
[service report](https://github.com/Vadale/R-ebirth/blob/main/docs/service-implementation.md).
Operational reliability does not establish extraction accuracy: the frozen D1
pilot had 10/10 schema-valid, 2/10 task-valid and 0/10 fully grounded records,
failing all four promotion gates. See the
[quality evaluation](https://github.com/Vadale/R-ebirth/blob/main/docs/d1-extraction-evaluation.md).

## Validation and license

The [validation ledger](https://github.com/Vadale/R-ebirth/blob/main/docs/validation-status.md)
distinguishes independent numerical references, regression checks and open
hardware/research gates. The
[architecture](https://github.com/Vadale/R-ebirth/blob/main/ARCHITECTURE.md) and
[decisions](https://github.com/Vadale/R-ebirth/blob/main/DECISIONS.md) explain the
native engine and its boundaries.

Original code is **MIT OR Apache-2.0**. Vendored llama.cpp is MIT. Modified
redistributions must rename under the
[trademark policy](https://github.com/Vadale/R-ebirth/blob/main/TRADEMARK.md).
