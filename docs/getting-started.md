# Getting started with relm

relm is an ordinary R package with a native Rust/C++ engine. Use a prebuilt
binary when one is available for your platform, or install from source with the
toolchain below. The package name in R is **relm**; `rebirth/` is its directory
inside the R-ebirth repository.

Version **0.3.0** adds structured output and statistical probes; see the
[release notes](../rebirth/NEWS.md#relm-030). Binary availability follows
r-universe builds, so check the installed version before using the new features.

## Install from r-universe

The [relm r-universe page](https://vadale.r-universe.dev/relm) is live and
distributes macOS and Linux builds. Prebuilt binaries need no Rust or C++
toolchain:

```r
install.packages(
  "relm",
  repos = c("https://vadale.r-universe.dev", getOption("repos"))
)
packageVersion("relm")
```

r-universe builds from `main`, so its version can differ from the latest tagged
release. Check the installed version before using structured output or probes.
Windows and CUDA remain deferred pending their own hardware acceptance.

## Install from source

You need R >= 4.5, Rust >= 1.85.0 (via [rustup](https://rustup.rs)),
CMake >= 3.28, a C/C++ compiler and `xz`. On macOS, install Xcode command-line
tools and CMake; on Linux, use the corresponding development packages.

With the optional `remotes` package installed, run:

```r
remotes::install_github("Vadale/R-ebirth", subdir = "rebirth")
```

This installs the current `main` checkout. The first native build can take
several minutes. To install a local clone, run `devtools::install("rebirth")`
from the repository root. The Cargo workspace is `rebirth/src/rust/`.

## First run

This example downloads approximately 675 MB on its first run. The pinned
Apache-2.0 model is verified by SHA256; later runs reuse a matching cached file.

```r
library(relm)

path <- llm_download("qwen2.5-0.5b-instruct-q8_0")
m <- llm(path)
llm_generate(m, "The capital of France is", chat = FALSE,
             max_tokens = 8, temperature = 0)
close(m)
```

`chat = FALSE` continues the supplied text; only the continuation is returned.
The default `chat = TRUE` applies the model's chat template. `temperature = 0`
uses greedy generation.

The [package quickstart](../rebirth/README.md#quickstart) continues with embeddings,
a small activation trace and constrained JSON. Activations are numerical values
inside the model; capture filters select the layers and token positions to inspect.
Statistical probes in 0.3.0 use these values to measure predictive decodability
with explicit source groups and optional held-out evaluation.

## Images and research demos

For image input, load a vision-language model together with its companion
projector, which translates images into values the language model can read.
The pinned pair is `qwen2-vl-2b-instruct-q4_k_m` and
`qwen2-vl-2b-instruct-mmproj-f16`. Each is downloaded separately with
`llm_download()`; pass the projector path to `llm(projector = ...)` and a JPEG,
PNG or BMP path to `llm_generate(images = ...)` or `llm_embed(images = ...)`.

The installed vignettes provide complete examples:

- `vignette("vision", package = "relm")` draws its own test images.
- `vignette("anatomy-lab", package = "relm")` explores traces, probes and interventions.
- `vignette("topics-without-python", package = "relm")` builds a topic map.

The topic demo optionally uses `uwot` and `dbscan`; probes use `glmnet`.
Runnable scripts also live in [`tests/demos/`](../tests/demos/). Larger models
are optional and are not needed for the first run.

## Offline batch and local service

The 0.3.0 repository includes a
[restartable batch application](../examples/funding-extraction/README.md) and a
[loopback service template](../examples/funding-service/README.md). Follow each
recipe's explicit setup step to prepare its isolated application dependencies
and verify an existing model. Run and resume operations then work offline.
These examples are repository applications, not new relm exports.

The service keeps one model worker alive, admits one request at a time and
persists request tickets. Mac/Linux acceptance covers its declared resource
limits, recovery and 1,000 same-worker requests; see the
[acceptance report](service-implementation.md) for provenance and scope.

Treat extraction results as data requiring review. Schema validity and reliable
execution do not establish factual correctness. The
[frozen D1 evaluation](d1-extraction-evaluation.md) failed all four quality
promotion gates; operational acceptance did not change that result.

## Troubleshooting

- **Installation asks for cargo or CMake:** R is building from source. Install the
  source toolchain, or select an available binary for your platform and R version.
- **A function or argument is missing:** check `packageVersion("relm")` and restart
  R after upgrading. Version 0.2.0 predates structured output and `llm_probe()`.
- **Memory on a 16 GB Mac:** begin with the 0.5B model and narrow trace filters.
  Traces above their configured budget spill to disk; model/context memory is
  separate, and the full 4B-spill hardware acceptance remains open.
- **Ollama is already running:** its server may keep another model in memory.
  Stop it before memory-intensive relm sessions. relm does not depend on Ollama.
- **Spark tracing fails:** generation is supported, but its activation trace
  intentionally raises a classed unsupported error pending a numerical reference.

## Maintainer release checks

The r-universe registry already points at this repository's `rebirth/`
subdirectory and follows `main`. Account setup and repository visibility are
complete. The maintainer's local release checklist covers versioning, package
checks, tagging and publication; the public
[development workflow](development-workflow.md) defines review and CI requirements.

For 0.3.0, verify the distribution build after integration, then install in a
clean library, check `packageVersion("relm")`, load the package and run the
first-run example. A green GitHub matrix does not by itself verify that a new
r-universe binary is available. Record the actual published version and platform
results; do not substitute an older binary or source build for this check.

CRAN preparation remains a later [package-plan](../SOLO-PHASE-PLAN.md) milestone alongside
documentation and API stability work. The current package remains experimental.
