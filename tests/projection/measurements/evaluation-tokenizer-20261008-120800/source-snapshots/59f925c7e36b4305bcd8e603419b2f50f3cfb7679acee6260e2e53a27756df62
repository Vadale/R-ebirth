# F6e frozen evaluation protocol

F6e-v1, frozen on 2026-10-07 before any F6e inference. D046 is approved.
This is an operational comparison of complete intervention settings, not an
assumption that projection improves behavior. Inputs and settings are fixed in
[prompts.csv](../tests/projection/evaluation/prompts.csv) and
[manifest.json](../tests/projection/evaluation/manifest.json). No model download.

## Source, split and capture

Use only the cached Qwen2.5-0.5B-Instruct Q8_0 bytes with SHA256
`ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e`, one original
CPU handle/context512 and one derived handle at a time. Record exact package,
engine, source and model identity. File checks and caller records are not
loaded-weight authentication. Actual CPU placement is required for this
experiment; Metal causal/performance acceptance is a separate native gate.

Twelve construction pairs, six selection questions and eight final questions
are allocated before fitting. All38 prompt byte strings are distinct and have
no exact question or prompt-hash overlap with the consumed F6d corpus. These
are hand-written convenience tasks, not a random population sample. Exact-text
separation does not establish semantic independence or pretraining absence.

Capture both full-width residual and raw MLP output at fixed layer12, last
position, on the original handle. One trace per prompt may capture both
components, giving24 traces and48 component vectors. Use trace's actual raw-text
profile (add_special=TRUE, parse_special=FALSE), actual source positions and
ordered neuron coordinates. Do not infer those positions from generation's
separate tokenization or a retokenization of output. Preflight four12-by-H
matrices and one live trace before allocating; release each trace promptly.

Construct exactly two learned unit directions using the same paired prompt
set: residual schema1 for addition, MLP schema2 for projection. Use
normalize_pairs=FALSE and orthogonalize=FALSE. Layer, capture, corpus and
construction options are not selected from results. Save/reload each trusted
artifact, recorded context and captured matrices, retain their bytes/digests,
and independently compare arithmetic and canonical encoding. No old captures,
directions or F6d held-out results are reused as F6e evidence.

## Random control with truthful provenance

In the isolated R process, set.seed(1046) and shuffle exactly six plus-one and
six minus-one pair signs once. For the MLP matrices, a minus sign swaps that
pair's actual target/control rows and their prompt digests/source positions in
the context. Build the control through the same public constructor. This is a
unit-norm balanced pair-sign randomization of real contrast data, not uniform
spherical noise or proof that all concept signal was removed. Keep signs,
matrices, metadata and resulting values. Do not invent capture provenance for
a raw random vector, redraw on an unfavorable result, or tune this control.
An invalid/degenerate construction is a retained experiment failure.

## Generation, selection and quality limits

Use raw chat=FALSE, temperature0, top_p0.95, seed1046, max_tokens256, no stop,
images or output schema. The cap is larger than F6d's64 but still bounded and
chosen before outputs; reaching it is not proof of complete-response brevity.
Observe actual token/finish events with the existing stream callback and save
original seeded returned text. Compare text bytes as character values and check
seed separately. Do not repeat the prior collector error of treating unname()
as removal of every attribute. Do not supply capture-only options when no
on_state callback is present. The generation watchdog remains120 seconds;
retain cancellation/error events and never retry an unfavorable output.

For each selection task run all12 settings in the manifest order: original,
zero addition, zero projection, learned addition at[-2,-1,1,2], learned projection
at[-1,0.5,1,2], and random-control projection at1. This gives72 actual runs.
Zero cases must reproduce original seeded text/token events exactly; failure is
an engineering issue rather than something the selection score may hide.

Record case-insensitive literal required-answer inclusion with non-alphanumeric
boundaries, Unicode character count, actual sampled tokens, whitespace-empty
output, length finish/truncation, adjacent repeated lowercase whitespace tokens,
elapsed time and errors. Literal inclusion is a deliberately limited quality
measure, not reasoning/factuality/safety validation. Preserve all raw text.

Select one coefficient separately for each learned operator. A candidate is
eligible only if all six runs succeed, every task preserves baseline literal
answer inclusion, has no extra empty/truncated output or repeated-token count,
and mean character count is strictly lower. Rank eligible candidates by mean
characters, then absolute coefficient, then signed coefficient; otherwise select
zero. Failed candidate runs disqualify that setting. A failed baseline invalidates
selection; only a diagnosed infrastructure amendment can resume it. Never alter
a prompt, metric, coefficient grid, layer, cap or quality guard based on outcomes.

## Held-out evaluation and reporting

Persist all selection rows and both chosen coefficients before first final
inference. Run six settings per final task in fixed manifest order: original,
zero addition, zero projection, selected addition, selected projection, random
projection at1. Execute48 runs even when a chosen setting is zero; keep their
labels and actual source distinct. The eight final prompts are now consumed;
no retuning and no fresh-generalization claim from later reuse.

For all six metrics report paired task-level differences of each nonbaseline
setting versus baseline, and selected projection versus selected addition.
Use one saved set of2000 task-index bootstrap resamples with seed2046, percentile
95% intervals, no multiplicity-adjusted or population-coverage claim. Report
truncated and untruncated counts separately; do not drop truncations from the
primary fixed sample. Export all original rows, errors, chosen coefficients,
resampling indices, interval data and readable base-R PDF/PNG plots. Negative
effects and a zero selection are valid outcomes, not reasons to rerun inference.

Residual addition and MLP projection differ in both site and learned vector.
Their comparison describes these complete interventions; it does not isolate
a pure causal effect of the operator formula. The random-pair-sign control
also does not establish that any favorable change is uniquely concept-specific.

Two separate two-state observations on the first construction prompt may check
F6c rendering/aligned deltas: original and the selected projection. Freeze
other generation settings; retain at most two states per call and no unlimited
history. Only compare matching source prefixes and never label this as extra
held-out efficacy. Model-map output must label the configured projection; a
static projection is not an additive F6b coefficient revision. These two calls
are separate from the120 selection/final runs.

Execution remains NOT RUN until actual receipts exist. Persist per-stage
source manifests and partial results before testing success. On a collector
failure diagnose and reuse intact completed model outputs with explicit parent
scope; do not silently rerun accepted inference. The behavioral score is not an
engineering acceptance gate. Native causality/numerics, resource admission,
installed R boundaries, scoped visual checks and final CI remain required.
