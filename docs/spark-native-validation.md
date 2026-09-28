# Native Spark integration — D-032

This work updates the embedded engine from llama.cpp b9726 to **b10828**
(`3ad1ba7336986d98592d3e28cafd1a406715351f`). It runs the model directly in
relm, with no Ollama process or server. The target is the minimum release named
by the [official model card](https://huggingface.co/XHToken/Spark-X2.5-4B).

**Integration update (2026-09-28):** [PR #46](https://github.com/Vadale/R-ebirth/pull/46)
merged at `2c827a7` after all nine PR checks and every dispatched validation
workflow passed: Spark Linux CPU (25 expectations), Qwen/S1, Linux/Mac vision,
both demos and Valgrind. The local milestone below retains its original scope;
remote run links are preserved in the merged PR. D2 is tracked separately in
[its batch-operation report](d2-batch-operation.md).

## Scope and reproducibility

The optional registry alias is `spark-x2.5-4b-q8_0`, from
`XHToken/Spark-X2.5-4B-GGUF`, revision
`9826e0be84e6e6e8b9668abc91421109a1df1e2d`, file
`Spark-X2.5-4B-Q8_0.gguf`. Its 4,375,021,152 bytes were downloaded directly and
verified against SHA256
`5c2c3c190e4337e1016b8593ca8e26e8b18c972200b107385d4ec61a25d9dea2`.
Weights are local data and are not committed. Existing small CI pins remain.

The two official chat-template spellings are pinned at model revision
`0bcb35678590218655dff3765b9e61c83b35e9c4`. Independent Jinja2 rendering produced
ten byte fixtures, checked by ordinary Rust tests without a model download.
The actual GGUF embeds the standalone template exactly. Native BOS/EOS IDs are
0/1; the R API exposes 1/2. Each official turn carries its own start marker;
the tokenizer must not add an extra one.

Ordinary chat retains the author's `<think>` opener. Schema-constrained chat
uses the author's `</think>` opener, so the JSON constraint begins at the first
generated token. No reasoning is silently stripped and no output is repaired.
An unrecognized Spark template is refused. The existing single-user-turn API
is unchanged; this does not introduce generic conversation/tool support.

Spark activation tracing remains explicitly unsupported, including residual
capture, pending an independent activation reference. Its upstream `attn_out`
has different semantics from D-014. Existing intervention capability probes
remain active; the optional acceptance checks a zero-final-residual invariant,
steering effect and source-handle reversibility. The 4B spill gate remains open.

## Engine and package gates

The sole local vendor patch remains the `build_cvec` intervention hook, with
unchanged added/deleted payload. Patch 0002 is retired because its library-only
build support is upstream. New native `vendor-hash` sources and licenses are
retained; no R/Rust dependency or public function is added. The compiled-header
ABI oracle checks every mirrored struct field, alignment and relevant enum.

Local acceptance on the Mac mini M4, R 4.5.1:

| Gate | Result |
|---|---|
| Tarball, pre-/post-patch digests and reverse-patch coherence | Passed |
| Engine default tests and unchanged synthetic numerical assertions | Passed; model-gated cases not counted as model evidence |
| No-spill engine / FFI tests | 102 / 7 reported passes, zero failures; one ignored no-spill calibration case |
| Independent numpy oracle and committed golden bytes | Passed, no regeneration |
| Loaded Spark template/token/flag unit test | Passed on CPU; loading/tokenization only |
| Package build with rendered Quarto vignettes | Passed |
| R CMD check, rendered vignettes | Passed: zero errors, warnings or notes |
| Complete R suite with Qwen 0.5B and the vision pair | 1,068 passed, zero failures/errors, eight declared skips; Spark run separately |
| Spark Metal R acceptance, context 4096 | 25 expectations passed in 15.77 seconds; generation, schema, tokenization, context overflow, explicit trace refusal and interventions |
| Spark acceptance process maximum RSS | 5,777,031,168 bytes (5.38 GiB); not a whole-device or large-trace bound |
| Same-machine pristine b10828 vision encoder | Passed: maximum absolute difference 0 across 98,304 values; original five-token T1 pin also passed |
| Rust Qwen intervention KL and vision embedding probes | Passed |
| Demo A / Demo B on Qwen 0.5B, including extended analyses | Passed: AUC 1.000, steer shifts +0.119 / -0.868, A4 impact/random 456×; 12 topics, silhouette 0.846 |
| Workspace Clippy | Passed with warnings denied |
| Tap-off generation overhead | 0.00%; baseline and trace-active medians both 0.269 seconds, 11 repetitions each; gate below 2% |
| S1 Qwen structured-output operational regression | Passed: 1.898× seconds per generated token (limit 2.0×), additional peak RSS 7,061,504 bytes (limit 128 MiB), schema-valid outputs |
| Formatting, offline evaluation artifacts and workflow YAML | Passed |

The [S1 operational report](../tests/structured-output/measurements/d032-qwen-macos-metal-2026-09-28/report.json)
preserves the measurements, including the narrow latency margin. Remote Linux
CPU and GitHub package/model checks remain pending at this local milestone.

An integrated correctness/security review found one CI coverage omission: the
optional job did not invoke the real-model Rust tokenizer test. The job now
invokes it and requires its successful test marker. No P1 issue was reported.

The optional `manual-spark.yaml` job runs on Linux CPU and can also be requested
through `nightly-model-tolerance.yaml` with its `spark` dispatch input. Ordinary
PR checks and scheduled runs never acquire the 4.38 GB model. The R model gate is
`rebirth/tests/testthat/test-llm-spark.R`; set `RELM_TEST_MODEL_SPARK` to a verified
GGUF and `RELM_TEST_SPARK_BACKEND` to the desired backend. A workflow definition
is not an executed acceptance result.

## Extraction experiment

The consumed D1 held-out pilot is **regression/exploratory evidence only**.
Its labels, source snapshots and frozen selected prompt remain unchanged.
The evaluator's `--split regression --mode structured` path preserves raw
outputs and failed cases, but produces no held-out promotion gate. Spark cannot
freeze or claim a new held-out evaluation on this consumed pilot.

The comparison holds the original settings at context 4096, maximum
768 output tokens, greedy sampling and the original case seeds. Both model and
engine change relative to D1, so any difference cannot be attributed solely to
model size. Author benchmarks using thinking mode are not comparable to this
non-thinking structured run. Human correction time remains unmeasured. D2 and
the proposed D-031 dependency remain outside this work package.

The [raw regression report](../tests/structured-output/measurements/d032-spark-macos-metal-2026-09-28/regression/report.json)
records all ten completed outputs without retries or repair. The installed
native library SHA256 is
`17ef12b92215a1bcaa211068ab10c62882b8e4be2bc8829f11909c23b95e1019`.

| Frozen checker metric | Archived D1 Qwen 1.5B Q4 | Spark 4B Q8 regression |
|---|---:|---:|
| Schema-valid records | 10/10 | 10/10 |
| Task-valid records, including evidence checks | 2/10 | 10/10 |
| Exact value/evidence record matches | 0/10 | 8/10 |
| Correct known amounts | 1/4 | 4/4 |
| Unsupported nonmissing fields within task-valid records | 6/8 | 2/11 |

The last denominator excludes invalid records, so it must be read together with
task validity, not as a standalone reliability estimate. The two residual errors
are `nlm-total` (`nearly` classified as `approximate` instead of the codebook's
`less_than`) and `brain-total` (a budget year treated as one year of project
duration despite no stated duration). The constrained run takes a median
**7.597 seconds per document** (range 7.261–14.227; 93.98 seconds across the ten
generation calls). That is observed call latency, not a service throughput SLA.

This result supports continuing development with Spark. It does not pass the
original unsupported-field criterion, and the reused pilot cannot establish
generalization even if every numerical criterion were met. Select changes using
development cases; acquire a new independently held-out corpus before a new
quality acceptance. The model-free artifact check rescores all 160 archived
D1/Spark predictions and verifies preserved output bytes.
