# Structured output, statistical research and practical deployment

Date: 2026-09-27. Planning baseline: maintenance PR #42, `01c10e9`.
Decision: [D-028](../DECISIONS.md#d-028--structured-research-workflows-and-production-simplicity).
Status: direction authorized; S0 is complete and the founder approved D-030 on
2026-09-27. [S1](s1-implementation.md) is accepted and merged in PR #44, with
macOS/Linux CI and Mac Metal/Linux CPU operational gates passing. The founder
authorized D1 then D2; [their execution plan](d1-d2-execution.md) records the
experiment and batch contract. D1 has a [negative held-out result](d1-extraction-evaluation.md):
0/10 fully grounded structured records despite 10/10 schema validity. D1
usefulness is not accepted. D2 now implements the restartable reference
application under approved application-only D-031; its Mac/Linux operational
acceptance passed; PR #47 is merged at `ddf8467` with all nine final checks green. See its
[acceptance report](d2-batch-operation.md). Later public API changes and new
dependencies retain their separate approval gates. The independent
GPT-6 Astra review, using ultra reasoning, preceded these planning changes.

## 1. Product direction and boundaries

Make relm useful for running local models, producing inspectable research data,
and investigating model behavior with R's statistical tools. Native inference,
activation access, reversible interventions and numerical validation remain the
foundation. Structured output enables practical workflows; it is not sufficient
differentiation by itself and does not establish factual correctness.

| Decision | Scope |
|---|---|
| Keep and develop | Constrained generation, an evaluated document-to-data application, statistical probes, and a short path to reliable batch operation |
| Reuse when needed | Existing MCP, chat, retrieval and evaluation tools; one necessary adapter at a time |
| Test before adoption | Laya or another specialized decision model against simple baselines; an R-specialist model against a frozen task benchmark |
| Exclude from this increment | A new generic MCP/chat framework, vector database, deployment platform, whole-CRAN indexing or foundation-model training |
| Reject as claims | Zero hallucinations, universally calibrated confidence, automatic causal inference, or capabilities being impossible in Python |

The package-suite → distribution → team-supported R-fork ladder is unchanged.
Native async, streaming, types, `reb_compile()`, fine-tuning and later research
phases remain planned. Windows/CUDA and the thesis remain deferred under their
existing decisions. No new model backend is a prerequisite for this increment.

## 2. Sequence and work-package exits

One WP is active at a time. Each implementation WP targets at most two working
weeks; split a larger design before implementation. The following order takes
precedence over historical phase numbering for this increment. **D1 has reached a recorded negative stop** after its bounded evaluation;
D1 usefulness remains unaccepted. D2 implementation/operational acceptance is
complete and merged in PR #47 (`ddf8467`);
S0/S1 and native Spark support are complete. Stronger-model comparisons are
deferred and do not block operational acceptance. Follow the milestone/verification policy
in [development workflow](development-workflow.md) (D-029). WP11a merged in PR #48 at `2a65a3f`, with all nine checks passing. The founder
approved D-033 and its [concrete contract](probe-evaluation-contract.md).
WP11b merged in PR #49 at `ecf3d3f`: all nine PR checks and the Linux CPU
model/control workflow passed. See the [probe report](probe-implementation.md)
and PR #49 for measured evidence. WP12a merged in PR #50 at `95066c7`, with all nine checks passing. The founder
approved the [local service contract](service-contract.md) and exact D-034
dependency closure. WP12b implementation is active; see its
[implementation report](service-implementation.md) for actual acceptance.

| Order | WP | Goal and steps | Acceptance / promotion gate |
|---|---|---|---|
| 1 | **S0 — Extraction and output contract** | Select a narrow public-document task; freeze codebook, grouped partitions, supported schema subset, failure semantics and a minimal artifact convention. Prepare exact API/dependency proposals and the fixture specification. | Commit a versioned corpus manifest, labelled pilot and development/test assignments; audit zero document-group overlap. Specify acceptance commands, thresholds and ownership for constrained output, extraction and batch artifacts (§5.1–4). Probe/service details belong to WP11a/WP12a. API/dependency proposals are reviewed before S1. |
| 2 | **S1 — Native constrained generation** | Integrate token constraints into the existing continuation path; validate the supported schema subset; preserve default generation behavior. Separate conversion and native integration into sequential WPs if necessary. | All successful fixture outputs validate; unsupported constraints fail before decode; incomplete output is explicit. Existing unconstrained goldens stay unchanged. Run model-free adversarial tests and a pinned-model comparison of correctness, latency and memory. |
| 3 | **D1 — Evaluated document-to-data demo** | Extract a few fields from verified text/Markdown into ordinary tables with source evidence; compare simple rules and current unconstrained generation. | Frozen held-out report includes all inputs, failures and abstentions, source verification, field accuracy, unsupported values, coverage and correction time. Numeric product thresholds set in S0 determine promotion; an honest failure report does not establish usefulness. |
| 4 | **D2 — Reproducible batch operation** | Turn the same application into a documented setup command and run command with pinned configuration, persistent results and restart/resume. One process and one writer. | Clean-session run succeeds offline after explicit setup; forced interruption/resume preserves completed results and creates no duplicates. Changed inputs/configuration refuse stale reuse. Record setup time, first-result time and memory on Mac and Linux CPU. This is the first production milestone. |
| 5 | **WP11a — Probe evaluation contract** | Define grouped evaluation, layer/hyperparameter selection, preprocessing, uncertainty and controls; reconcile with the approved formula API. | A split audit detects leakage; independent statistical reference fixtures and their expected outcomes are recorded. Any required API/dependency amendment is approved before WP11b. |
| 6 | **WP11b — Probe implementation** | Implement the accepted contract, S3 summaries/plots/predictions and a short anatomy-lab workflow. | Match the independent reference on controlled data; preprocessing/selection stays inside training partitions; shuffled-label and simple-feature controls run. Demo A in about five lines is an additional usability check. |
| 7 | **WP12a — Minimal service contract** | Choose one existing-tool recipe for the demonstrated application; specify worker ownership, access scope, limits, readiness, deadlines and recovery. | Approve dependencies and freeze numeric load/resource limits plus an executable overload/crash test plan. No dependency on WP14 or native async. |
| 8 | **WP12b — Service template** | Implement that recipe and documented setup/start/stop/recovery commands. A template need not introduce a new relm export. | Normal load, overload, failed requests and forced worker exit meet the WP12a limits. Run the selected path for 1,000 cycles and report memory growth and recovery. Validate Mac and declared Linux CPU deployment. |
| As justified | **I1 — Focused integration** | Add one MCP, ellmer or retrieval adapter needed by a demonstrated caller. Move it before WP12b only when that caller requires it. | Pin supported upstream interfaces; exercise actual calls and fresh-process reopen/reconstruction. A retrieval adapter also needs a pinned encoder and a retrieval-quality comparison. |

S0 is a specification/fixture package, not permission to implement a speculative
public API. Its completion produces a concrete approval request for any changed
signature or dependency. The existing development workflow still applies:
specification, references/tests, small commits, independent review, green checks,
then integration. A failed product gate leads to a bounded correction or a
recorded stop; it must not be hidden by changing the held-out test set.

## 3. The first application

Use a bounded collection of public policy documents, beginning with verified
text or Markdown and approximately 100–200 labelled excerpts if suitable data
are available. Preserve source text, stable document IDs and version digests.
Group excerpts from the same document and related versions before splitting.
This is a feasibility pilot, not a claim of precise subgroup performance.

Candidate fields are programme/intervention type, population, territory,
period and explicitly stated expenditure. S0 narrows and fixes the codebook.
Each populated field carries an exact evidence span and source location; unknown,
conflicting and out-of-scope cases remain visible. Span matching is automatic;
whether the quote actually supports the value needs reference labels/review.
An authentic but irrelevant quote is still an extraction error.

Include negation, multiple amounts, missing information, contradictory passages
and out-of-scope examples. Separate development from final evaluation before
tuning prompts or schemas. Count failed and abstained records in the denominator.
Produce a descriptive report and an inspectable table, without causal claims.
PDF/OCR ingestion, RAG, a dedicated embedding model and Laya are not prerequisites.

## 4. What production simplicity means here

Production includes repeatable scheduled analysis, not only high-throughput web
traffic. The first user experience should be: configure model and inputs, run
one documented command, inspect results, and resume safely after an interruption.

| Layer | relm / R-ebirth responsibility |
|---|---|
| Native relm core | Constrained generation, model lifecycle, tracing/interventions, classed errors and statistical probes; preserve base-R objects and declared side effects |
| Reference application | Ingestion, domain schema, evidence checks, run manifest, document-level results, evaluation and reporting |
| Optional integration | Small adapters to existing MCP/chat/retrieval/HTTP tools; their dependencies stay outside core unless separately approved |
| Deployment recipe | Environment restoration, startup checks and existing supervision; a working application example before any generalized production kit |

For the broader R-ebirth vision, the tested application template can later become
a reusable pattern for deploying R analyses. Generic type contracts and the
compiler spike remain separate Phase-7 work. A fork, new parser or transpiler is
not required to run a research application reliably.

### Batch MVP — D2

- One R process owns one loaded model and processes documents sequentially.
  A startup check validates paths, input/configuration identities, model/backend
  availability and writable output location. Setup downloads/restores explicitly;
  the run has no implicit network dependency.
- Persist configuration, a manifest, per-document results and a concise event
  log. Record relm/native build, R/package versions, model/projector digests when
  applicable, backend, source/prompt/schema digests and per-document seeds.
  Choose and version the concrete format in S0; do not create a storage framework.
- Commit a document result atomically on the target filesystem. Resume verifies
  identities, retains committed results and retries interrupted documents. Stable
  per-document seeds prevent restart order from changing the experiment.
  Persistent artifacts contain ordinary data/configuration, never live handles.
- Keep one writer. No multi-process coordination protocol, scheduler or universal
  exactly-once execution claim. A restart may repeat unfinished computation while
  still publishing at most one committed result for that document/run identity.
- Use caller-owned persistent directories. Managed trace spill is temporary and
  has an age-based sweep; it is not a durable job store. Core generation does not
  start writing manifests or logs as a side effect.
- An application-level `renv` lockfile is a candidate, not a new approved core
  dependency. Pin the R/native environment and model separately. Record the build
  and backend; identical results across different hardware are not promised.

### Local service, then a small-team pilot — WP12

A single-user loopback service may run synchronously if its blocking behavior is
explicit. Keep a fixed model loaded in its owning process and declare limits on
inputs and outputs. The initial endpoint serves the demonstrated task; arbitrary
R execution, user-selected model paths and full activation-trace transfers are
outside its contract.

For a responsive small-team pilot, evaluate an existing HTTP stack with one
persistent inference worker, or an existing outer admission layer supervising
one synchronous worker. Plumber plus an established worker integration is a
candidate in the original plan. WP12a now proposes Plumber + callr + later
in [D-034's concrete contract](service-contract.md), approved on 2026-09-28. Do not build
a queue.

Each worker constructs and closes its own model. Exchange configuration and
ordinary data, not serialized or fork-inherited native pointers. Calls using a
mutable context remain sequential; request-state isolation is tested after both
successful and failed calls. Extra workers require measurements of total model,
context, scratch and backend memory; start with one on the 16 GB target.

A blocking R endpoint cannot also guarantee responsive health checks, admission
control or cancellation during native inference. Put those responsibilities in
the chosen operational layer. If a deadline requires terminating a worker, mark
the active document interrupted and reload the model before accepting work.
Use established supervision such as `launchd` or `systemd`. Persistent outputs
must survive worker and application replacement. Log identifiers, timings,
statuses and condition classes without copying document contents into event logs.

WP12a freezes maximum input size, output tokens, active/pending requests, deadline,
recovery time, peak memory and acceptable memory growth before implementation.
It also defines the binding/network access scope; a network deployment reuses
existing access controls rather than implementing custom authentication.
Every submitted request must end in success, rejection, failure or interruption.
A Linux CPU container is an optional deployment recipe, not evidence for native
macOS Metal behavior. No cloud control plane, multi-tenancy or autoscaling is
promised by this milestone.

## 5. Correctness and evaluation gates

These are **planned acceptance requirements, not executed checks**. Their
eventual commands, fixtures, platform and result belong in the
[validation ledger](validation-status.md).

1. **Constrained output:** document and reject unsupported schema constructs;
   never silently drop constraints. Validate successful outputs independently.
   Test Unicode, malformed/deep schemas, resource bounds, empty admissible-token
   sets, EOS, stop strings and token/context exhaustion. An incomplete result must
   not be reported as success. Keep prompt instructions consistent with schema.
   Review conversion/validation dependencies rather than hand-writing general
   JSON infrastructure merely to avoid a dependency decision.
2. **Compatibility:** preserve approved default signatures and return behavior;
   unconstrained seeded goldens stay unchanged. Numeric changes remain
   golden-first. Measure constraint overhead on a small pinned real model.
3. **Application quality:** report accuracy by field, unsupported-value rate,
   missing-value handling, coverage/abstention, failures and correction time
   against frozen labels and baselines. Structural validity is separate from
   factual support and usefulness. S0 sets task-specific promotion thresholds.
4. **Restart and installation:** run documented commands in clean supported
   environments; force interruption at known document boundaries; verify no
   changed or duplicate committed result. Change model, source, prompt and schema
   identities separately and assert refusal to reuse stale results. Exclude event
   timestamps from repeatability comparisons.
5. **Probes:** keep related observations together, fit preprocessing inside
   training folds, separate layer/hyperparameter selection from final evaluation,
   and specify what confidence intervals cover. Predictive decodability alone
   does not show causal use of a feature. Keep shuffled-label/simple-feature
   controls; do not treat correlated folds as independent observations.
6. **Service:** execute the agreed normal-load, overload, invalid-input,
   repeated-request and worker-exit scenarios. Measure cold/warm latency and
   process-tree/backend memory. The 1,000-cycle stress obligation is open until
   actually run; a short smoke test cannot replace it.
7. **Adapters:** reconstruct process-local handles from verified configuration
   after a fresh R start. Test actual upstream compatibility; documented APIs do
   not constitute a tested integration. Retrieval adds encoder-quality and
   necessary-evidence retention checks.

## 6. Evidence informing the plan

These sources inform design choices; no new service, adapter or comparative
model benchmark was executed for this planning change.

- [llama.cpp grammar documentation](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md): supported-schema limitations, conversion caveats and grammar performance hazards motivate explicit validation and bounds.
- [Plumber execution model](https://www.rplumber.io/articles/execution-model.html): synchronous handlers occupy their R process; operational responsiveness must be designed separately.
- [mirai serialization](https://mirai.r-lib.org/articles/v03-serialization.html) and [Plumber integration](https://mirai.r-lib.org/articles/v02-promises.html#plumber-get-endpoint): existing process tools are candidates, with native-object transfer constraints.
- [renv reproducibility caveats](https://pkgs.rstudio.com/renv/articles/renv.html#caveats): package restoration is only part of a reproducible native-model environment.
- [Plumber hosting](https://www.rplumber.io/articles/hosting.html#systemd) and [Apple launchd guidance](https://support.apple.com/guide/terminal/script-management-with-launchd-apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac): use established process supervision.
- [Ragnar store creation](https://ragnar.tidyverse.org/reference/ragnar_store_create.html): reopening serialized embedding callbacks requires a deliberate model-reconstruction contract.
- [Probe control tasks](https://aclanthology.org/D19-1275/): predictive probe performance requires controls before representational claims.

**Next action:** implement WP12b's approved application-only ticket service and execute its
frozen Mac/Linux acceptance gates. The contract checker verifies only planning
consistency; no service/load/stress result is claimed. D2 and WP11b are integrated;
D1's negative quality result and deferred stronger-model comparison are unchanged.
