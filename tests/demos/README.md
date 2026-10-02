# tests/demos/

The two reference demos, run as scripted acceptance tests
(`SOLO-PHASE-PLAN.md` §8, WP7). These live in the repository, not in the
`relm` package tarball.

- **`demo-A-anatomy-lab.R`** — the anatomy lab: a fixed, committed sentiment
  contrast set → `llm_trace()` → `prcomp()` concept direction → per-layer
  cross-validated `glmnet` ridge-logistic probe → decodability (AUC + bootstrap
  CI) by layer → the base-graphics money plot → `llm_steer()` verification on
  held-out prompts. `run_demo_A(extended = TRUE)` (or `RELM_DEMO_EXTENDED=1`)
  adds five mechanistic-interpretability figures (D-022): **A1** a multi-concept
  decodability overlay (sentiment vs a second committed concept, formality),
  **A2** a token × layer concept heatmap, **A3** a steering dose–response curve
  (with the full swept range, saturation tail included), **A4** a
  targeted-vs-matched-random ablation effect curve, and **A5** the concept
  direction's layer × layer geometry.
- **`demo-probe-evaluation.R`** — the WP11b grouped evaluation example: 40
  synthetic source pairs, fixed development/test groups, `llm_probe()`, a simple
  lexical baseline and a fixed paired-label control. Run
  `run_probe_evaluation(model_path, output_dir, backend = "cpu")` after sourcing.
  It writes metrics, split/control audits, provenance and a base-graphics PDF.
  The same pinned Qwen0.5 example runs in the Demo A nightly. See
  [implementation evidence](../../docs/probe-implementation.md); its perfect
  lexical baseline prevents interpreting the probe score as a scientific result.
- **`demo-B-topics.R`** — topics without Python: public abstracts →
  `llm_embed()` → `uwot::umap()` → `dbscan::hdbscan()` → cluster naming via
  `llm_generate()` → one labelled base-graphics cluster map.
  `run_demo_B(extended = TRUE)` (or `RELM_DEMO_EXTENDED=1`) adds three
  BERTopic-report analyses (D-022): **B1** topic-quality metrics (simplified
  silhouette + embedding cohesion + the noise fraction), **B2** distinctive
  terms per topic (log-odds z with an informative Dirichlet prior), and **B3**
  inter-topic structure (centroid-cosine heatmap + `hclust` dendrogram); **B4**
  is the polished labelled map. `run_demo_B_reproducible()` asserts fixed seeds
  give byte-identical clustering and statistics.
- **`demo-utils.R`** — model-free helpers sourced by Demo A and Demo B:
  `demo_auc()` (exact rank-based Mann–Whitney AUC) and `demo_auc_ci()`
  (stratified bootstrap CI), plus the WP7.5b shared visual style (`hcl.colors`
  palettes, `pch = 21` points, colour-strip legend, halo text, the
  model | n | seed subtitle) and numeric helpers: for Demo A (bootstrap mean CI,
  cosine matrix, truncated next-token KL, legend breaks) and for Demo B
  (simplified silhouette, embedding-space cohesion, cluster centroids, a
  regex tokenizer + term-count matrix, and Monroe-et-al. log-odds top terms with
  an informative Dirichlet prior). An executable self-test runs on `source()`
  (41 checks, run per-commit in CI). No pROC (D-020).
- **`make-abstracts-sample.R`** — regenerates the shipped synthetic sample
  (`rebirth/inst/extdata/abstracts-sample.csv`) deterministically.
- **`fetch-abstracts.R`** — fetches the real ~5,000-abstract arXiv corpus for
  Demo B (base R only; abstracts are pulled locally, not redistributed).

## Running them

WP10 adds **`demo-streaming.R`**, a separate foreground demonstration. Sourcing
only defines functions: it never starts work or downloads a model. With the
WP10 development package and optional later/promises installed, load a local
model, source the script and call `state <- start_streaming_demo(m)`. RStudio
returns to its console while the chart updates. Inspect `state$status`, then
`state$events`, `state$text` and `state$statistics` after completion. Close the
model when done. The 128-token rolling window is bounded; optional full-event
collection is explicitly caller memory with a 100,000-row demo guard. Counts
use token rows, not text chunks. Throughput includes consumer backpressure;
production and delivery times are separate. This does not repeat Demo A/B or
claim extraction quality.

Demo A's probe AUC and bootstrap intervals are exploratory. Regularization and
layer selection use the same validation results; resampling fixed predictions
does not include that selection uncertainty. Confirmatory use needs nested
cross-validation or an independent test set, plus suitable grouping of related
prompts. Held-out steering checks answer a separate question and do not remove
selection bias from the probe-performance estimate.

The demos need a local GGUF model. Point `RELM_DEMO_MODEL` (or
`RELM_TEST_MODEL_QWEN`) at one; with none set, each script defines its
functions and skips the end-to-end run. From the repository root, with the
package built:

```r
pkgload::load_all("rebirth")
Sys.setenv(RELM_DEMO_MODEL = "/path/to/model.gguf")
source("tests/demos/demo-A-anatomy-lab.R") # auto-runs and draws the money plot
source("tests/demos/demo-B-topics.R")      # auto-runs and draws the cluster map
```

Both are seeded for reproducible outputs (fixed `foldid`, bootstrap seeds, greedy
generation) — two runs give byte-identical numbers. Set `RELM_DEMO_EXTENDED=1`
(auto-run), or call `run_demo_A(extended = TRUE)` for the five Demo A figures
(`demoA-A1..A5-*.png`) and `run_demo_B(extended = TRUE)` for the three Demo B
figures (`demoB-B1..B3-*.png`) plus the polished map; each set adds roughly ten
minutes on the demo model. Both demos also run nightly in CI on the 0.5B model
with relaxed thresholds (`.github/workflows/nightly-demo-A.yaml`,
`nightly-demo-B.yaml`); both are non-gating. The `anatomy-lab` and
`topics-without-python` package vignettes narrate the same pipelines and render
with or without a model.

Dependencies (per D-020): base R + `relm` + `glmnet` (Demo A) + `uwot`,
`dbscan` (Demo B), each guarded by `requireNamespace()`. Money plots are base
graphics only.
