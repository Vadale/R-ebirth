# Supported research workflow

Updated 2026-10-19. Start with the [installation guide](getting-started.md), then
the [complete walkthrough](../examples/research-workflow/README.md). It uses
existing public APIs and exports ordinary R objects, CSV and base-R graphics.
The integrated research APIs are included in 0.4.0. Check installed functions,
not only the version string. This matrix describes recorded support, not every
combination accepted by the underlying engine.

| Task | Supported route | Boundary |
| --- | --- | --- |
| Load and generate | Local GGUF, `llm()`, `llm_generate()`; macOS arm64/Metal, Linux CPU and optional development Linux CUDA acceptance | Windows CPU production source-package checks passed at PR71; full research/GPU parity is unverified. [CUDA scope](linux-cuda.md) is a locally verified source build, not the published 0.4.0 binary. Model loading is synchronous. |
| Observe | `llm_trace()` with layer/position/component filters; `on_state` during async generation | Spark tracing is unsupported. Filter captures; managed Arrow spill limits capture storage, not total process RSS. |
| Compare and export | `llm_compare()`, `llm_timeline()`, `plot()`; table/CSV and trusted RDS | Matching recorded input histories are required for differences. Caller provenance is validated, not authenticated. A configured model map is not measured activity. |
| Construct directions | `llm_direction()` from paired actual captures and explicit model/split provenance | Schema 1 residual directions support addition. Schema 2 records supported attention/MLP sites; artifact/model identity must match. |
| Project | `llm_apply_direction(operator = "project")`, a fixed derived handle | Dense Llama `attn_out`/`mlp_out`; dense Qwen2 `mlp_out`; recorded CPU/Metal and single-device Linux CUDA scope. No sparse/MoE, GPU-general or arbitrary-architecture promise. |
| Update during generation | Bounded `on_state` replies update additive coefficients | Projection is static. Additive revisions in a timeline do not represent static projections. Callbacks run on R's thread and must remain short. |
| Evaluate | Fixed prompts, controls, held-out data and explicit metrics using ordinary R | Shorter text, decodable labels and changed activations do not prove correctness, causal use, general efficacy or safety. |
| Close/cancel | `close()` and cooperative `llm_cancel()`; GC as a fallback | Close derived handles explicitly. A watchdog requests cancellation; it is not an operating-system memory/time guarantee. |

For choosing among these functions, see the [research API guide](research-guide.md).
Ordinary prompt tracing and embeddings are refused on intervened handles;
observe their generation with `on_state`. This includes projected handles, which
also refuse images. `llm_compare()` takes live observations, not arbitrary traces.

The projection operator is `x - coef * u * dot(u, x)` for the stored unit
direction, at the recorded site. Residual addition uses a different site and
direction; comparing the two is not an isolated comparison of operators.

Live spill cleanup has a platform boundary: Unix removes an unpublished file
only while its recorded device/inode still matches. Non-Unix systems retain
caller-managed files for explicit cleanup; managed native spill leases are
unavailable there. A passed Windows CPU package check does not certify Windows
live-spill cleanup parity. The 0.5.0 warning correction preserves this behavior.

## Existing complementary uses

These remain supported examples, not prerequisites for the primary walkthrough:

- [Topics](../rebirth/vignettes/topics-without-python.qmd): embeddings and optional
  ecosystem tools `uwot`/`dbscan`; no new topic framework.
- [Probes](../rebirth/vignettes/anatomy-lab.qmd): optional `glmnet`, grouped splits
  and held-out evaluation; predictive decodability is not causal use.
- [Structured output and batch/service](structured-production-plan.md): bounded
  supported JSON schemas and separate application dependency environments.
- [Vision](../rebirth/vignettes/vision.qmd): the pinned model/projector pair and
  its recorded acceptance, not generic multimodal tracing support.
- [Assistant companion](external-assistants-plan.md): optional external R
  workflow tooling; no assistant service is required by relm.

Core R imports are `methods` (part of R) and `nanoarrow`. Async/live generation
uses optional `later >= 1.4.8` and `promises >= 1.5.0`. Documentation rendering
uses optional Quarto tooling. Install only the optional tools for the selected
route; no new dependency is introduced by the walkthrough.

## Evidence and remaining limits

The [validation ledger](validation-status.md) and [F6e report](f6e-implementation.md)
retain source-specific evidence and failures. Phase 6's consumed eight-task
evaluation showed a modest projection result: the descriptive interval for
character-count change versus original includes zero, and seven of eight
projection outputs hit the token cap. Do not rerun or tune those held-out prompts.
Two separate grouped cross-schedule numerical outliers exceeded the recorded
whole-forward tolerance; they are not accepted as batching invariance. The
pinned Qwen tokenizer warning about the end token and its possible stopping
effect remain recorded.

The [maintenance inventory](phase7-maintenance.md) identifies retained gates and
remaining work. Phase 7's current acceptance is a maintainer functional run
(D-047). [Independent usability feedback](phase7-user-feedback.md) is deferred
until after publication; neither acceptance nor adoption by external users is
claimed. A separate [agent first-use assessment](research-first-use.md) now
records a fresh question using the released package, with practical difficulties
and model failures retained. It does not replace external-human feedback or test
all capabilities in this matrix.
