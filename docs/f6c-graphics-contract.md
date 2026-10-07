# Reusable model and intervention graphics

Date: 2026-10-07. **D-044 APPROVED.** After receiving the concrete contract and
its API approval question, the founder merged PR60 and instructed "ho fatto il
merge, puoi passare al prossimo step". That instruction authorizes F6c
implementation. The preceding roadmap-only approval did not approve unseen
exports; the signatures below were presented before this implementation decision.

F6c makes three existing capabilities usable together: locating interventions
in a model, comparing observed states, and following applied coefficients during
generation. Figures use base graphics; their underlying tables remain available
for ordinary R analysis and caller-managed export. No new R/Rust dependency,
native operation, vendor patch or inference wrapper is proposed.

## 1 Public surface

Add two constructors and three S3 plot methods. These signatures are approved
in API-GRAMMAR section 12; implementation and acceptance remain separate.

```r
plot.llm(x, layers = NULL, ...)

llm_compare(reference, intervention, context, layer,
            component = "residual", neurons = NULL,
            max_bytes = 64 * 1024^2)
plot.relm_comparison(x, ...)

llm_timeline(state, history = NULL, max_states = 256L,
             max_bytes = 8 * 1024^2)
plot.relm_timeline(x, ...)
```

`reference` and `intervention` are single, already delivered F6a/F6b callback
states, with exactly `step`, `logits`, `trace` and the worker steering attribute.
They are observations, not model handles or instructions to run generation.
Use actual generation states from intervened handles: ordinary `llm_trace()`
still rejects such handles and must not be substituted for these observations.

Both constructors return a plain classed data frame. Plot methods draw on the
current graphics device and invisibly return the plotted table. They do not
choose file paths, create a device or accumulate state. Caller-owned `pdf()`,
`png()`, `saveRDS()` and `write.csv()` remain the export mechanisms. A plain
`as.data.frame()` view exposes columns; RDS retains attributes and provenance.
No HTML, Shiny, browser server or graphics package becomes a dependency.

All three plots accept only documented base-graphics options through `...`
(`main`, `cex`, `col`); invalid names fail rather than being silently ignored.
Default legends and provenance/alignment notices cannot be removed by a title.
Restore changed graphical parameters on success and failure. These methods
complement the existing probe plot and demo analyses, without changing them.

## 2 Model block map

`plot(m)` presents the selected transformer blocks and marks configured
residual steering and ablation. `layers = NULL` selects all blocks up to a
32-block display bound; larger models require an explicit selection of at most
32 distinct valid layers. Omitted blocks appear as labelled gaps. No automatic
inference or allocation proportional to hidden width is allowed.
Require an open `llm` handle; a closed handle retains the existing classed error.
Only immutable R metadata is inspected, including while a native job is active.

For source-verified sequential `llama` and `qwen2` layouts, the schematic shows
attention, MLP and residual paths, with the existing `attn_out`, `mlp_out` and
post-intervention residual observation sites. The residual intervention marker
states steer-then-ablate semantics; layer 1's steering restriction is visible.
Other architectures receive a generic ordered block view labelled as such;
never invent a validated internal topology from a name or layer count. A vision
projector is an external input annotation, not an interpreted encoder graph.

The diagram describes model metadata and the immutable handle's configured
interventions. It does not claim those sites were captured in an experiment or
display live coefficients from a running job. Use the timeline for worker-applied
coefficients. Edge position/width is not an activation measurement, attention
weight or estimated causal relationship. A caption makes that distinction.

The returned table has one row per displayed site and exact columns
`layer` (integer), `site` (character), `detail` (character),
`configured_steers` and `configured_ablations` (integers counting entries).
Site identifiers are `block`, `attn_out`, `mlp_out`, `residual`; generic views
use only `block`. Attributes retain architecture and layout-detail status.
Do not copy steering vectors or the native handle into the returned table.

## 3 Paired observed states

`llm_compare()` selects one layer/component and explicit neurons, or every
captured neuron when `neurons = NULL`. Indices are 1-based, unique and valid.
The two selected coordinate sets must match exactly; duplicates, partial
coverage and non-finite values fail. No recycling, zero filling or implicit
aggregation is allowed. Neither input is modified or retained by reference in
the result. Already delivered states remain usable after their model closes.

### Experimental context and alignment

`context` is a base list with exactly `reference` and `intervention`. Each entry
has exactly these fields:

| Field | Contract |
|---|---|
| `model_sha256` | A 64-digit hexadecimal content digest from the experiment's verified model record. A path is not model identity. |
| `settings` | Named list of `seed`, `chat`, `temperature`, `top_p`, `max_tokens`, `stop`, `context_length`, `backend`, `relm_version`, `engine_revision`; values describe the actual run. |
| `generated_tokens` | Full 1-based integer sampled IDs through the supplied state, in order, recorded from `step$token_id`. |

The two model digests and settings must be identical. Validate settings using
the existing generation value rules, bounded text fields and exact field names.
Require byte-identical recorded prompt text in trace metadata and equal
`prompt_token_count`. Check generated length against `state_id`, its final ID
against `step$token_id`, and all source/context-position identities. Context is
caller-recorded provenance, not cryptographic authentication of a callback;
format validation must never be described as independently hashing a loaded
model or proving the run settings. The runnable collection recipe uses one
verified cached model and an intervened handle derived from it, identical prompt
and generation arguments, and records every sampled token ID separately for each
run. It binds the model digest to the cached model registry record. No hidden
native tokenization call or new export is needed. `llm_tokens()` is not a source
of templated generation-prefix IDs: its special-token flags differ from both
raw and chat generation.

For state k the causal input prefix is the consumed prompt followed by generated
IDs 1 through k-1, **excluding the token just sampled at k**. Identical recorded
model, prompt, chat setting and implementation establish the same deterministic
prompt tokenization within this experiment contract; the collector verifies its
length as well. Compare the complete generated-ID prefixes exactly, including
their lengths, before computing an activation difference. The alignment status
explicitly states that it relies on this recorded context, not a separately
observed full prompt-ID sequence. A different sampled token at k does not invalidate that state's
input alignment; it can invalidate the next state's alignment. Equal token
pieces, matching positions or matching only the last source token do not prove
equal histories. The intervention's prior effects in its KV cache remain part
of the experiment, even when its current coefficient is zero.

When prefixes match, compute `difference = intervention - reference` in R
double precision at identical coordinates. When they differ, retain both
observed values but set all differences to `NA_real_`. The result and plot must
say **different input histories; descriptive comparison only**, and record the
first divergent context position. Never silently align only their common suffix.
Matched input histories permit a controlled observation, not a general causal,
quality or statistical-significance claim from one experiment.

### Returned values and figure

Class: `c("relm_comparison", "data.frame")`. Exact columns:
`layer`, `component`, `neuron`, `reference`, `intervention`, `difference`;
indices are integers, labels character, measurements double, ordered by neuron.
Attributes contain schema version 1, selected state/source coordinates,
alignment status and divergence, the bounded context and both applied steering
tables. Do not embed either input trace, file lease, model pointer or full state.

An `outputs` attribute records the two sampled token IDs and a plain table
joining the supplied top-logit summaries by token ID: reference/intervention
logit and probability, and their differences only for aligned prefixes where
both values are present. Missing top-k entries are `NA`, not probability zero.
The table is a truncated distribution view, never a full KL or output-quality
estimate. Display pieces, if present, remain labels rather than identity keys.
The current state's sampled token is not guaranteed committed output: cancellation
or a stop suffix can prevent it appearing in final text.

The default figure has reference, intervention and difference panels sharing
the same neuron coordinates; the first two share a value range and the signed
difference range is symmetric around zero. A compact output annotation shows
sampled IDs and the bounded top-logit comparison. For divergent histories the
third panel explains why differences are withheld. Titles include selected layer,
component and source positions; the underlying table is the numerical authority.

## 4 Bounded steering timeline

`llm_timeline(state)` starts a history from state 1. Within a callback, assign
`history <- llm_timeline(state, history)` and explicitly return the intended
F6b reply or `NULL`; the history itself is not a valid steering reply.

The history is a plain data frame with class
`c("relm_timeline", "data.frame")`. It contains the eleven existing step
columns, in their existing order, followed by `intervention`, `layer`, `coef`.
Repeat the step once per worker steering row. With no steering entries, retain
one row with those three fields `NA`, so token/state timing is still visible.
Do not retain activation vectors, logits, traces, spill leases or model pointers.
Use only the worker's applied steering attribute, never callback reply intent.

Append only the next consecutive state with unchanged prompt identity, prompt
length and intervention IDs/layers; retain the existing revision/position rules.
Reject duplicate/reversed/skipped state IDs and inconsistent audit rows. A new
generation starts a new history; there is no global collector or invented native
run identifier. As with ordinary editable R tables, the caller must not splice
observations from different runs. The helper validates consistency, not origin.

`max_states` is 1 through 1024 and counts whole states, not expanded rows.
Retain the newest states fitting both bounds, removing oldest complete states
as needed. Attributes record schema version 1, original and retained state
ranges, dropped-state count, bounds and compact validation metadata. Truncation
is explicit in every plot. If one state's audit cannot fit, fail before extending
history. Old caller-held histories remain caller-owned and are not a hidden leak
claim or part of a process-wide memory guarantee.

The figure shows sampled token IDs/state positions and piecewise-constant
applied coefficients by intervention, marking `applied_after_state` and
`effective_source_pos`. A callback reply at state k first affects a later decode;
never draw it as causing state k. Label these as sampled states, not committed
output text. A zero coefficient does not reset historical KV. Large intervention
sets require an explicit table subset for rendering rather than hidden omission;
the default renderer admits at most 16 distinct interventions.

## 5 Resource and failure contract

`max_bytes` is a finite whole number of bytes: compare allows 64 KiB through
256 MiB; timeline allows 64 KiB through 64 MiB. These bound package-owned R
working materialization and result construction, including both slices, joins,
copies, context and attributes. Existing caller-owned inputs, graphics-device
buffers, native model memory and total process RSS are separate. Include any
Arrow batch retained during conversion in the working ledger.

Preflight shapes, widths, string bytes and row counts before dense allocation;
check actual materialized object sizes against the frozen conservative ledger.
Define that ledger with exact R allocation prototypes before implementing the
constructors. A result-only `object.size()` assertion is insufficient. Reject
before a conversion that cannot be bounded. Byte/capacity checks and refusal
are required even when only a small neuron subset is requested.

For spilled live captures, reuse the existing integrity, schema, nonce and
source-position checks. Add a scoped internal streaming selector as necessary:
one admitted Arrow batch plus selected rows, without collecting an entire trace
or calling an unbounded `as.matrix()` first. No spill-format/native-writer change
or new persistent artifact is approved. Missing/corrupt/mismatched files retain
classed failures; returning fabricated empty data is prohibited.

Reuse `relm_error_argument` for invalid arguments/context/coordinates,
`relm_error_trace` for malformed observation or spill data, and `relm_error_oom`
for budget refusal, with argument/reason/count/estimate fields as appropriate.
An allocation invariant violation is `relm_error_internal`, not a warning or a
silent truncation. No new public condition class is proposed.

## 6 Implementation and acceptance order

1. After D-044 approval, freeze its signatures in API-GRAMMAR and define the
   concrete memory ledger. Write small independent R fixtures first for block
   markers, signed differences, prefix divergence, top-k absence and timeline
   revisions. No modification of accepted native numerical goldens is needed.
2. Implement the two constructors, three renderers and scoped spill selection.
   Keep shared validation/rendering helpers only where the three views use them.
   No generic plotting framework or new inference/decode path.
3. Run model-free boundary tests on ordinary R CI: exact data values/ordering;
   1-based coordinates; malformed context/duplicate/missing coordinates; first
   state versus next-state divergence; zero/negative/static/live coefficients;
   bounded history and atomic append refusal; file-integrity and batch-size
   refusals; materialized peak-ledger controls; graphics parameter restoration.
4. Use one small paired cached-Qwen experiment via the already accepted live
   interface, with fixed settings and a verified prompt prefix. Include observed
   output divergence, ordinary and spilled selected data equality, and a coefficient
   timeline. Record settings, actual applied audit and figure data. This validates
   the new composition; it does not repeat F6a/b acceptance or claim task quality.
5. Render and inspect all three figures at normal and compact sizes, including
   monochrome/color-accessible distinction and caller-owned PDF/PNG export.
   Verify legible labels, no clipping, visible dropped-state/provenance notices
   and exact correspondence between plotted values and returned tables. Include
   an ordinary RStudio usage check without repeating generation responsiveness.
6. Finish one integrated review for the substantial implementation, relevant
   package checks, runnable documentation/NEWS and one coherent feature PR.
   Preserve source scopes and warnings, use background jobs and sparse monitoring.
   No unchanged native, sanitizer, vision or earlier live acceptance reruns.

## 7 Approved scope

The approval covers the two new constructors, three S3 plotting methods and bounded,
read-only comparison/timeline semantics above, with base graphics and existing
dependencies. This approves F6c implementation only. F6d direction artifacts and
F6e native projection retain their separate future concrete contracts.

The alternative of automatic experiment execution and a browser dashboard is
deferred: it adds orchestration, lifecycle and deployment obligations before the
existing observations have a reusable visual interface. Handwritten demo plots
remain useful, but do not replace the supported package methods proposed here.
