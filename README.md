# relm · Local language models in R

**Turn text into data, inspect a model's internal activity, and compare interventions
from an ordinary R session.** relm returns text, data frames and matrices you can
use with your existing statistical and plotting tools.

Inference runs on your computer after you download a model. No Python runtime,
model server or API key is required. **relm** is the R package; R-ebirth is this
repository.

[Install](#install) · [First example](#first-example) ·
[Complete extraction recipe](examples/funding-extraction/quickstart/README.md) ·
[Guides and reference](https://vadale.github.io/R-ebirth/) ·
[0.6.1 release](https://github.com/Vadale/R-ebirth/releases/tag/v0.6.1)

![R plots compare recorded model activations, an unchanged zero control, and a residual intervention alongside next-token probabilities.](docs/media/research/activation-intervention.gif)

*An actual saved relm experiment: inspect internal values, check a zero control,
and compare an intervention. The animation reveals recorded values; it does not
simulate measurements or demonstrate improved accuracy.*
[Static figure, data and explanation](docs/animated-research.md).

## Install

Use **R >= 4.5**. Install from [r-universe](https://vadale.r-universe.dev/relm):

```r
install.packages(
  "relm",
  repos = c("https://vadale.r-universe.dev", getOption("repos"))
)
```

The published release is **0.6.1**. Prebuilt binaries avoid a Rust/C++ build;
check availability for your R version and platform. The supported desktop scope
is Linux, macOS and Windows x86_64; Windows ARM64 and WebAssembly are deferred.
See [installation and troubleshooting](docs/getting-started.md) for source builds
and platform details. CRAN acceptance of the separately submitted candidate is
still pending; see [submission status](docs/cran-submission.md).

## First example

The first download is about **1.12 GB**. Later calls reuse the verified model.
This example uses CPU explicitly; memory use and speed depend on your machine.

```r
library(relm)

path <- llm_download("qwen2.5-1.5b-instruct-q4_k_m")
m <- llm(path, backend = "cpu", context_length = 2048L, threads = 4L)
answer <- llm_generate(m, "Explain a research budget in one sentence.",
                      chat = TRUE, max_tokens = 64L,
                      temperature = 0, seed = 231023L)
cat(answer, "\n")
close(m)
```

Example output from this model in a CPU run (wording may vary):

> A research budget is the financial allocation made by an organization to fund research activities.

A fluent answer can still be wrong. To work with documents, keep the source text
and check the extracted facts. [Choosing another model](docs/models.md) explains
pinned downloads, local GGUF files, chat templates and supported operations.

## A complete recipe: six notices to a reviewable CSV

[Run the funding extraction quickstart](examples/funding-extraction/quickstart/README.md).
It includes six short **synthetic** notices, expected values, an R script, every
recorded response, and measured time and memory. It extracts a programme's total
budget with a supporting quotation and checks cases where the total is absent.

The recorded CPU run matched **5 of 6 amount/evidence pairs** in about **116
seconds** of generation, with the failed response preserved. You can inspect the
saved results without downloading a model. Six designed examples are not a
real-world accuracy benchmark. Valid JSON alone does not establish a correct amount.

## Explore further

| Your next question | Guide |
| --- | --- |
| How do I capture activations and compare an intervention? | [Research walkthrough](examples/research-workflow/README.md) and [API guide](docs/research-guide.md) |
| How do I turn documents into embeddings or topic maps? | [Topics without Python](rebirth/vignettes/topics-without-python.qmd) |
| How do I watch generation? | [Token streaming](rebirth/vignettes/token-streaming.qmd) and [recorded demonstrations](docs/animated-research.md) |
| How do I process larger batches or resume a stopped run? | [Batch application](examples/funding-extraction/README.md) and [local service](examples/funding-service/README.md) |
| Which model, backend and research operations are supported? | [Support matrix](docs/supported-workflow.md), [model guide](docs/models.md) and [validation limits](docs/validation-status.md) |
| How can an assistant use the API correctly? | [Agent guide](docs/agents.md), [llms.txt](llms.txt) and [API/version policy](docs/api-policy.md) |

Select layers and positions when capturing activations; spill does not bound all
process memory. Close model handles when finished. Interventions provide no
safety or debiasing guarantee. The [negative extraction evaluation](docs/d1-extraction-evaluation.md)
and [first-use study](docs/research-first-use.md) remain available with their
original findings. CUDA work is deferred; an ordinary binary does not imply GPU
support.

## Contribute

Start with the [documentation index](docs/README.md) and
[development workflow](docs/development-workflow.md). The package is in `rebirth/`;
runnable examples are in `examples/`. Architecture and implementation details
are linked from those guides.

Original code is **MIT OR Apache-2.0** ([license](LICENSE.md)); vendored llama.cpp
is MIT ([notice](NOTICE)). Modified redistributions must follow the
[trademark policy](TRADEMARK.md).
