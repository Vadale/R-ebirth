# tests/demos/

The two reference demos, run as scripted acceptance tests
(`SOLO-PHASE-PLAN.md` §8):

- **Demo A — the anatomy lab**: contrast set → `llm_trace()` → `prcomp` →
  per-layer `glmnet` probes → decodability (AUC + CI) plot → `llm_steer()`
  verification on held-out prompts.
- **Demo B — topics without Python**: public abstracts → `llm_embed()` →
  `uwot::umap` + `dbscan::hdbscan` → cluster naming via `llm_generate()` → one
  labeled map.

Added in **WP7**; Demo A also runs nightly in CI on the CI model with relaxed
thresholds. Empty until then.
