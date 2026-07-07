# tests/demos/

The two reference demos, run as scripted acceptance tests
(`SOLO-PHASE-PLAN.md` §8, WP7). These live in the repository, not in the
`rebirth` package tarball.

- **`demo-A-anatomy-lab.R`** — the anatomy lab: a fixed, committed sentiment
  contrast set → `llm_trace()` → `prcomp()` concept direction → per-layer
  cross-validated `glmnet` ridge-logistic probe → decodability (AUC + bootstrap
  CI) by layer → the base-graphics money plot → `llm_steer()` verification on
  held-out prompts.
- **`demo-B-topics.R`** — topics without Python: public abstracts →
  `llm_embed()` → `uwot::umap()` → `dbscan::hdbscan()` → cluster naming via
  `llm_generate()` → one labelled base-graphics cluster map.
- **`demo-utils.R`** — model-free helpers sourced by Demo A: `demo_auc()` (exact
  rank-based Mann–Whitney AUC) and `demo_auc_ci()` (stratified bootstrap CI),
  with an executable self-test that runs on `source()`. No pROC (D-020).
- **`make-abstracts-sample.R`** — regenerates the shipped synthetic sample
  (`rebirth/inst/extdata/abstracts-sample.csv`) deterministically.
- **`fetch-abstracts.R`** — fetches the real ~5,000-abstract arXiv corpus for
  Demo B (base R only; abstracts are pulled locally, not redistributed).

## Running them

The demos need a local GGUF model. Point `REBIRTH_DEMO_MODEL` (or
`REBIRTH_TEST_MODEL_QWEN`) at one; with none set, each script defines its
functions and skips the end-to-end run. From the repository root, with the
package built:

```r
pkgload::load_all("rebirth")
Sys.setenv(REBIRTH_DEMO_MODEL = "/path/to/model.gguf")
source("tests/demos/demo-A-anatomy-lab.R") # auto-runs and draws the money plot
source("tests/demos/demo-B-topics.R")      # auto-runs and draws the cluster map
```

Both are seeded for reproducible outputs. Demo A also runs nightly in CI on the
0.5B model with relaxed thresholds (`.github/workflows/nightly-demo-A.yaml`); it
is non-gating. The `anatomy-lab` and `topics-without-python` package vignettes
narrate the same pipelines and render with or without a model.

Dependencies (per D-020): base R + `rebirth` + `glmnet` (Demo A) + `uwot`,
`dbscan` (Demo B), each guarded by `requireNamespace()`. Money plots are base
graphics only.
