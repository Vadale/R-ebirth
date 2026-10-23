# Documentation

Start with one supported path, then use the specialist guides when needed.

[Watch relm in motion](animated-research.md): two short, code-generated animations
of actual activation comparisons and token events, with static figures and data.

[Six notices to a reviewable CSV](../examples/funding-extraction/quickstart/README.md):
a small public recipe with synthetic inputs, expected values, raw outputs and
measured errors, time and memory. Read the saved run without a model download.

## Start and complete an experiment

1. [Install and check capabilities](getting-started.md).
   [Choose or change a model](models.md): pinned downloads, your own GGUF and
   model-specific observation limits.
2. [Choose the right research API](research-guide.md): prompt traces, live states,
   directions, controls and how to interpret the plots.
3. [Run the research walkthrough](../examples/research-workflow/README.md):
   load → observe → compare → intervene → evaluate → export.
4. [Check support and interpretation limits](supported-workflow.md).
5. [Use the agent guide and standalone API examples](agents.md).
6. [Read the independent agent's first-use assessment](research-first-use.md):
   actual outputs, documentation difficulties and remaining gaps.

[API/version policy](api-policy.md) defines the compatibility baseline;
[WP16 validation](wp16-implementation.md) records actual example execution and
the separate publication and 1.0 release gates.

Version [0.6.1 is published](https://github.com/Vadale/R-ebirth/releases/tag/v0.6.1)
on r-universe, including desktop build corrections and maintainer-tooling
security updates. For historical numerical and runtime evidence, use the
[validation ledger](validation-status.md); plans and old receipts are not current
results. The submitted **0.5.0 CRAN candidate** remains frozen awaiting acceptance;
see [submission status](cran-submission.md). The [model guide](models.md) records
optional CPU threads, chat support and the bounded dense/MoE comparison.

## Extend the same workflow

- [Linux CUDA installation and measured scope](linux-cuda.md), with the
  [implementation/performance report](wp13-linux-cuda-implementation.md).
- [Streaming](../rebirth/vignettes/token-streaming.qmd) and
  [live intervention graphics](../rebirth/vignettes/model-interventions.qmd).
- [Recorded contrast directions](../rebirth/vignettes/contrast-directions.qmd).
- [Probes and activation research](../rebirth/vignettes/anatomy-lab.qmd).
- [Topic modelling](../rebirth/vignettes/topics-without-python.qmd) and
  [vision](../rebirth/vignettes/vision.qmd), with their optional dependencies.
- [Structured output, batch and service](structured-production-plan.md).
  [S1](s1-implementation.md) and [D1 evaluation](d1-extraction-evaluation.md)
  separate format acceptance from extraction quality.
- [External statistical assistants](external-assistants-plan.md), an optional
  companion workflow; relm does not require an assistant.

## Maintain and assess

- [Phase 7 plan](phase7-consolidation-plan.md),
  [maintenance and CI inventory](phase7-maintenance.md), and
  [maintainer execution report](phase7-implementation.md).
- [Optional post-publication user feedback](phase7-user-feedback.md): independent
  usability remains deferred, not claimed by the maintainer's functional run.
- [API and version policy](api-policy.md), including compatibility and the
  thirty-day green-CI gate before 1.0.
- [Current PR-check audit and deferred platforms](ci-efficiency-implementation.md#pr-check-audit-and-platform-deferral-2026-10-23): retained coverage, removed repetition and timing limits.
- [Development workflow](development-workflow.md): coherent milestones, scoped
  verification and batched pushes (D-029).
- Binding specifications: [product plan](../SOLO-PHASE-PLAN.md),
  [API grammar](../API-GRAMMAR.md), [architecture](../ARCHITECTURE.md) and
  [decisions](../DECISIONS.md). Historical reports retain their original scope.
