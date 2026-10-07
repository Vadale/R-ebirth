# F6d frozen evaluation protocol

Protocol F6d-v1, frozen on 2026-10-07 **before any F6d model run**. D045 is
approved; this is a bounded operational evaluation, not evidence of useful
behavior before execution. Input text and hashes are in
[`prompts.csv`](../tests/directions/evaluation/prompts.csv), with the fixed
settings in [`manifest.json`](../tests/directions/evaluation/manifest.json).
No model download is required or authorized.

## Experimental unit and capture

Use the existing cached Qwen2.5-0.5B-Instruct Q8_0 file with SHA256
`ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e`.
Verify its bytes before load and keep it unchanged throughout the experiment.
Use one original CPU handle with context length 512, pinned current patched
engine, and text input only. Recorded provenance is not authentication of
loaded weights. Never substitute another same-width model.

The construction set contains 12 factual questions, each with target concise
and control elaborate instructions. Selection and final evaluation contain
6 and 8 different questions. All 38 prompt byte strings and hashes are
distinct; their facts/items are allocated before fitting. These small,
hand-written tasks are not a representative population sample. A phrase/hash
audit cannot rule out semantic similarity or the model's pretraining exposure.

Capture residual layer **12**, position `last`, with existing `llm_trace()` on
the original unintervened handle. These trace tokenization flags are
`add_special=TRUE`, `parse_special=FALSE`; the supplied strings are raw text with
no external template. Capture one pair at a time, preflight space for two
12-by-hidden-width matrices, verify complete neuron coordinates/actual source
positions, and release each trace before the next pair. Use pair IDs as row
names and full ordered neuron IDs as column names. Save captured inputs and
their hashes with the result so independently checked provenance is possible.

Construct exactly one direction with `normalize_pairs=FALSE` and
`orthogonalize=FALSE`. Layer, methods and corpus do not depend on observed
selection/final results. Save/reload the artifact and validate it. The numerical
tests independently cover other algorithm combinations; this experiment does
not search over methods or layers.

## Generation and controls

Generation settings: raw `chat=FALSE`, `temperature=0`, `top_p=0.95`,
`max_tokens=64`, `seed=101`, no stop/schema/images. Record actual sampled token
IDs/counts through the existing stream callback; do not infer them by
retokenizing final text with `llm_tokens()`, whose flags differ. Record final
text, finish reason, elapsed time and any error. No output-quality retry.

Selection settings, in this fixed order for each of the six tasks:
original handle, zero coefficient, learned direction at `-2,-1,1,2`, and a
norm-matched random direction at coefficient `1`. Generate that random vector
once using `set.seed(1045)` in the isolated evaluation process, independent
normal coordinates and unit normalization; retain its exact values/hash.
It is a negative control, not an artifact imported under fabricated construction
provenance. Apply it through existing raw-vector `llm_steer()`. Close each
derived handle before the next run; keep only one original and one derived
handle alive. No large handle grid or unbounded live-state history.

For each output record:

- Required-answer inclusion: case-insensitive match of any prewritten
  alternative in `required_pattern`, bounded by non-alphanumeric characters
  or the string ends. This literal check can miss valid paraphrases and does
  not assess reasoning, grounding or all factual content.
- Unicode character count (`nchar(type="chars")`) and actual sampled-token
  count. Shorter output alone is not a quality improvement.
- Empty output after whitespace trimming; native length finish reason;
  repeated-output count defined as consecutive identical lowercase whitespace
  tokens after trimming. Preserve the raw text and this exact limited detector.

A learned nonzero coefficient is eligible only if every selection task retains
baseline required-answer inclusion, with no extra empty/truncated output or
increase in repetition count, and mean character count is strictly lower than
baseline. Rank eligible settings by mean character count, then absolute
coefficient, then signed coefficient. If none qualifies, select zero. Any
failed selection run disqualifies that setting; baseline failure invalidates
selection and the final run does not begin until a diagnosed infrastructure
issue is resolved under an explicitly recorded amendment. Do not repair a
poor task outcome or change a metric to obtain a nonzero selection.

## Final holdout and reporting

Persist the selection table and chosen coefficient **before** the first final
task. On each of the eight final tasks run baseline, zero, selected learned
coefficient, random coefficient `1`, in that order with frozen settings. If the
selected value is zero, still retain a separately labelled selected-setting
run rather than relabelling an earlier output as new evidence. Final prompts
are then consumed; no tuning or fresh-generalization claim from reuse.

Save per-task tables, outputs and errors. Report paired differences in answer
inclusion, characters/tokens, emptiness, truncation and repetition. For paired
mean differences use 2000 task-level paired bootstrap resamples, seed 2045,
percentile 95% intervals. State that eight deliberately selected tasks provide
limited conditional uncertainty, not validated population coverage. Keep the
resampling indices/results. Report negative effects and zero selection honestly;
a favorable effect is not an engineering acceptance requirement.

Use base graphics for the selection dose-response and held-out paired summaries.
Export their underlying ordinary tables and readable PDF/PNG. One separate
bounded observation example reuses F6c `llm_compare()` / `llm_timeline()` with
the frozen selected setting, retaining at most two states and eight history
rows. It is a visualization check, not an additional final-holdout outcome.
Use a construction prompt; record actual input-prefix alignment and withhold
deltas after divergent token histories. No old RStudio acceptance is repeated.

All experiment outputs go to a fresh run directory. Freeze source/package/model
hashes, preserve failed receipts, and independently verify arithmetic, manifest
disjointness, selection rule, CSV/plot data and actual counts. This protocol
does not change the separate D045 arithmetic/resource acceptance or existing
native tolerances. The execution status remains **NOT RUN** until actual
receipts exist.

## Recorded harness amendment before any generated evaluation text

On 2026-10-07 the initial execution completed the 24 construction captures,
independent direction arithmetic and exact checked-versus-raw native application
comparison. Its overall run FAILED: the evaluation script supplied capture-only
`top=0` / `spill=FALSE` with `on_state=NULL`. Existing argument validation rejected
all 42 selection calls before generation. No token event, selection decision or
held-out output existed. Raw calls, sources and diagnosis are retained in
`tests/directions/measurements/model-evaluation-20261007-175741`.

The correction uses the existing capture defaults (`top=20`, `spill=TRUE`) when
no observation callback is present; these settings perform no capture in that
mode. The separate two-state visualization keeps its explicit capture settings.
Prompt text, tokenization, sampling, coefficient grid, quality guards and every
evaluation metric are unchanged. Resume reuses the exact captured matrices,
fitted artifact and random vector with explicit parent-source provenance; it
does not repeat accepted capture/numerical/application work. The first actual
selection and held-out text generation remains pending at this amendment.
