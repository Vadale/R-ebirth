# A small, inspectable model experiment

This is the supported relm 0.4.0 research walkthrough. It joins the public APIs
without a new framework: **load → observe → compare → intervene → evaluate → export**.
It is a usability exercise, not a benchmark or evidence that steering improves answers.

## Before starting

1. Install relm **0.4.0 or later**, with R >= 4.5, following the
   [installation guide](../../docs/getting-started.md). Restart R after upgrading.
   Clone or download this repository as well: `examples/research-workflow/run.R`
   is a repository example, not a file installed by `install.packages("relm")`.
   The script checks actual functions/arguments before loading the model.
2. Install the existing optional `later` (>= 1.4.8) and `promises` (>= 1.5.0)
   packages in the same R session's library search path. Restart R after an upgrade.
3. Have the cached `qwen2.5-0.5b-instruct-q8_0` model, approximately 675 MB.
   This walkthrough verifies its pinned SHA256 and does not download anything.
   Set `model_path` to your existing file, for example
   `model_path <- path.expand("~/models/qwen2.5-0.5b-instruct-q8_0.gguf")`.
   If you need the file, choose explicitly to run
   `model_path <- relm::llm_download("qwen2.5-0.5b-instruct-q8_0")` instead.
   Keep that returned path: the downloader's cache is not necessarily `~/models`.
4. Record the engine revision of your installed build. The released 0.4.0 engine
   uses the research label `b10828-patched-D039-D040`; the maintenance diagnostic-
   directive patch does not change its numerical implementation. Use that label
   only for the corresponding engine. Record
   `packageDescription("relm")$RemoteSha` separately for the package source
   revision (it may be absent in a local source installation). The script records
   the installed DLL path/checksum, but does not save `RemoteSha` automatically.
   Caller-supplied provenance is not authentication of the installed binary.

Run from the repository root in a fresh R session:

```r
source("examples/research-workflow/run.R")
run_research_workflow(
  model_path = model_path, # existing path or the path returned by llm_download()
  output_dir = "research-output", # must not already exist
  engine_revision = "b10828-patched-D039-D040"
)
```

The repository root is the directory containing `README.md`, `rebirth/` and
`examples/`; set R's working directory there before `source()`. Use a new output
directory for a new experiment. If you only want to inspect existing results,
read the saved files instead of rerunning the model.

For the meaning of a trace, direction, live state and comparison, see
[Choosing the right research API](../../docs/research-guide.md). The
[independent agent first-use report](../../docs/research-first-use.md) records a
separate real attempt and its remaining friction; it is not human user research.

The script loads one CPU model, captures four construction prompts at layer 12
and generates eight short outputs (four conditions on two separate prompts,
32 tokens each). It holds at most one derived handle at a time and closes it.
The original and zero-projection outputs must match. A 120-second generation
watchdog requests cancellation and waits up to 30 seconds for settlement.
This is not a bound on model loading or total process memory. Run a long
session in a background R process if you need the foreground console free.

## Read the results

- `prompts.csv`, `conditions.csv`, `settings.rds`: inputs and fixed conditions,
  written before generation. The coefficient is fixed at 1, never tuned on the
  two observed responses. The practice prompt occupies the schema's selection
  split; no coefficient-selection procedure is performed.
- `construction.rds`, `directions.rds`: actual paired residual/MLP captures and
  checked model-bound artifacts. The direction is target minus control.
- `outputs.csv`: all eight texts, character counts, observed sampled-state counts
  and token-cap indicators. Read the text: a shorter wrong or unfinished answer
  is not an improvement. Counts are not silently called committed output tokens.
- `*-comparison.png` and matching CSV/RDS: original versus projection at the first
  live state, with a common prompt history. These activation differences do not
  establish improved answer quality. Addition and projection also differ in
  intervention site and direction, so this is not a pure-operator comparison.
- `configured-model.png`: the configured static projection at MLP layer 12.
  It is not a live-activity or causal-importance map.
- `practice-*.rds`, `evaluation-*.rds`: actual first observations, sampled IDs,
  results and bounded coefficient timelines. Static projection has no additive
  live revisions; an empty coefficient history does not mean no projection.
- `provenance.rds`, `installed-dll.csv`, `session-info.txt`, `files.csv`: model,
  installed runtime, session and output identities. CSV omits R attributes;
  retain the trusted local RDS files too. Never read an untrusted RDS.
- `STATUS.txt`: becomes COMPLETE only after all steps and exports succeed.
  Partial directories are retained on failure; use a new name only after
  diagnosing the cause, rather than overwriting evidence or retrying blindly.

Use `read.csv("research-output/outputs.csv")` to inspect all rows, and
`readRDS("research-output/evaluation-comparison.rds")` to recover the plotted
values and provenance without loading a model or generating text again.

## Stop and interpret

Write down one observation, one alternative explanation and one limitation.
The small fixed corpus and token cap do not support a generalized efficacy claim.
The pinned model's recorded tokenizer warning can affect stopping semantics;
retain actual warnings from your run. There is no detector/safety guarantee.
The [capability matrix](../../docs/supported-workflow.md) states the supported
sites, backends, resource boundaries and optional tools.

For later independent usability feedback use the
[post-publication feedback procedure](../../docs/phase7-user-feedback.md).
A maintainer or automated run of this script is not external-user acceptance.
