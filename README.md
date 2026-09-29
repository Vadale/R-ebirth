# R-ebirth · relm

**Local language models and model research in ordinary R.**

R-ebirth is delivered as **relm**, an R package that runs open-weight models on
your machine. Generate text, produce constrained JSON, embed documents and
inspect a model's internal activity. Results are ordinary character vectors,
`data.frame`s and matrices, ready for R's statistical and plotting tools.

The native engine is a pinned, patched llama.cpp embedded through Rust. No
Python, model server or API key is required. relm runs on stock R >= 4.5.

![A topic map of scientific abstracts, with clusters named by a local model](rebirth/man/figures/topic-map.png)

*The [topic-modelling demo](rebirth/vignettes/topics-without-python.qmd) combines
relm embeddings with optional UMAP and HDBSCAN packages, then asks the model to
name each cluster.*

## relm 0.3.0

**Version 0.3.0** adds structured output, statistical probes and operational
application examples. See the [release notes](rebirth/NEWS.md#relm-030).
Binary availability follows r-universe builds; check the installed version
before using the new features.

The new release brings together:

- **Structured output:** `llm_generate(schema = ...)` returns complete JSON
  matching a supported bounded schema, or a classed R error.
- **Native Spark support:** Spark-X2.5-4B generation through llama.cpp b10828,
  including its official non-thinking opener for constrained chat. Spark
  activation tracing remains unsupported.
- **Statistical probes:** `llm_probe()` fits binary ridge models to activations
  with grouped cross-validation, development-only selection and optional held-out
  evaluation. A probe measures how readily a label can be predicted from a model's
  internal values; predictive success alone does not establish causal use.
- **Operational examples:** an [offline, resumable batch application](examples/funding-extraction/README.md)
  and a [loopback service template](examples/funding-service/README.md) with a
  persistent model worker, durable tickets and bounded resources. Their optional
  application dependencies stay outside the relm core.

Generation, tokenization, embeddings, text-and-image input, activation tracing,
steering and ablation remain available. Activations are the numerical values
inside a model; steering adds a chosen direction to those values, while ablation
sets selected units to a fixed value to investigate their effect.

## Install and start

[r-universe](https://vadale.r-universe.dev/relm) distributes macOS and Linux builds
and tracks the repository's `main` branch. Check the installed version before
using the 0.3.0 additions:

```r
install.packages(
  "relm",
  repos = c("https://vadale.r-universe.dev", getOption("repos"))
)
packageVersion("relm")
```

Start with the [package quickstart](rebirth/README.md#quickstart) or the
[installation guide](docs/getting-started.md). The package README includes
generation, structured output and a small activation trace. The guide covers
source builds, image input and troubleshooting.

## What has been validated

Numerical paths are checked against independent references, with the scope of
each comparison recorded in the [validation ledger](docs/validation-status.md).
The batch and service examples passed their declared Mac/Linux operational
acceptance; service stress includes 1,000 requests on one persistent worker.
The [0.3.0 release report](docs/release-0.3.0.md) records packaging, installed-package
checks and the remaining CRAN-readiness findings.
The [service report](docs/service-implementation.md) preserves exact source
provenance and separates the stress measurements from later lifecycle checks.

These results do not establish extraction accuracy. The frozen D1 pilot produced
10/10 schema-valid outputs, but only 2/10 task-valid and 0/10 fully grounded
records; all four quality promotion gates failed. See the
[evaluation report](docs/d1-extraction-evaluation.md). Likewise, steering and
ablation are research instruments for auditing model behavior, not guarantees
of safety or bias removal.

Windows/CUDA, tracing inside the vision encoder, and several larger-model
hardware checks remain open. The [public execution plan](docs/structured-production-plan.md)
records the completed increment and later work; no
new work package is started by this release.

## Repository and development

| Path | Contents |
|---|---|
| `rebirth/` | R package, installed as `relm` |
| `rebirth/src/rust/` | Native Cargo workspace: `rebirth-llm` and `rebirth-ffi` |
| `rebirth/src/llama.cpp/` | Pinned engine, patches and vendoring provenance |
| `tests/llm-golden/` | Independent numerical references |
| `tests/demos/` | Runnable research demos |
| `examples/` | Funding batch and service applications |
| `docs/` | Design, acceptance evidence and installation guide |

For builds and contributions, read the [architecture](ARCHITECTURE.md) and
[development workflow](docs/development-workflow.md). The public specifications
are [SOLO-PHASE-PLAN.md](SOLO-PHASE-PLAN.md), the
[execution plan](docs/structured-production-plan.md), [API-GRAMMAR.md](API-GRAMMAR.md)
and [DECISIONS.md](DECISIONS.md).

## License

Original code is dual-licensed **MIT OR Apache-2.0**; see [LICENSE.md](LICENSE.md).
Vendored llama.cpp is MIT; see [NOTICE](NOTICE). Modified redistributions must
rename under the [trademark policy](TRADEMARK.md).
