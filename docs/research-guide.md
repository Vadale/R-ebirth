# Choosing the right research API

Start with [installation and the first call](getting-started.md). This guide maps
research questions to the existing public API; the
[complete walkthrough](../examples/research-workflow/README.md) supplies a runnable
experiment. You do not need to understand the Rust engine to use these tools.

## Observe the right quantity

| Question | Use | Meaning of the result |
| --- | --- | --- |
| What does the model answer? | `llm_generate()` | Generated text; async mode resolves to the same result shape |
| What numerical representation does each document get? | `llm_embed()` | One pooled, optionally normalized vector per input |
| What happens inside a forward pass over my prompt? | `llm_trace()` | Activation values at selected layers, components and token positions |
| What happens while an answer is generated? | `llm_generate(on_state = ...)` | Bounded observations delivered to an R callback during async generation |
| How do two recorded live states differ? | `llm_compare()` | Matched coordinates, with differences withheld for incompatible histories |
| Which coefficients were applied during generation? | `llm_timeline()` | Recorded additive coefficient history, not a static projection log |

A **token** is a model-specific piece of text. An **activation** is a numerical
value produced while processing it. The **residual stream** passes values between
model blocks; `attn_out` and `mlp_out` identify particular component outputs.
They are different quantities, and not all architectures expose every component.
R-facing layer, token and neuron indices are 1-based.

`as.matrix(trace, layer = ..., component = ...)` selects one activation slice.
Rows represent captured `(prompt_id, token_pos)` pairs; columns represent neurons.
This matrix is ready for ordinary R analysis. It is not a matrix of next-token
probabilities or a measure of causal importance.

## Keep prompts and observations aligned

`llm_trace()` traces the literal supplied prompt. It does not capture a previous
call's generated answer and does not apply a chat template. With generation,
`chat = FALSE` continues literal text; `chat = TRUE` applies the model's template.
Keep formatting consistent when the experimental question requires it.

`llm_compare()` consumes two **live observations**, not arbitrary traces or text
strings. Record the model, generation settings and preceding sampled token IDs.
The first state can have the same prompt history even if the newly sampled tokens
differ. Once prior generated tokens diverge, activation differences are withheld:
the model is then processing different inputs. Do not fill those gaps with zero.

Token events, sampled states and committed text are distinct, especially with
cancellation or stop sequences. Use the meanings in the
[streaming guide](../rebirth/vignettes/token-streaming.qmd), not interchangeable
counts. To distinguish a token cap from a stop, retain the `finish_reason` on
the actual `prompt_end` token event; the first-use recipe shows this alongside
the text. Callbacks execute on R's main thread; keep them short.

## Design an intervention experiment

1. **State the question and observable outcome.** Define prompts, output limits,
   settings and a concrete criterion before observing results. Read the text as
   well as counting characters or tokens.
2. **Separate construction from evaluation.** Capture paired construction inputs
   and reserve different prompts for evaluation. Choose coefficients before the
   final comparison; do not retune on that comparison's outputs.
3. **Keep controls.** Include the original model and a zero-coefficient derived
   handle. Match generation settings and record any failed conditions.
4. **Apply the appropriate operator.** `llm_direction()` builds a model-bound
   artifact from paired captures. `llm_apply_direction()` creates a derived model
   that shares weights while owning a separate context. Residual addition adds a
   vector; component projection removes its scaled contribution at a supported
   site. `llm_ablate()` fixes selected values. These operations are not equivalent.
5. **Observe through generation.** Ordinary tracing and embeddings are refused on
   intervened handles; their separate contexts would not inherit the intervention.
   Use live `on_state` observations when studying the actual intervention.
6. **Export and interpret.** Retain all texts, failures, settings, plots and trusted
   local RDS objects. Close each derived handle and then the original.

The direction is computed from paired target-minus-control values. A name such as
“uncertainty direction” records the construction hypothesis; it does not prove
the vector uniquely represents that concept. A two-prompt illustration cannot
establish generalized efficacy. Keep construction, coefficient selection and
held-out evaluation separate in a larger study.

The current artifact schema requires nonempty construction, selection and
evaluation split manifests even for a fixed coefficient. In the small
[first-use example](../examples/research-first-use/README.md), the selection prompt
is declared and reserved but never executed: there is no selection procedure or
selection evidence. This is a schema requirement, not a reason to pretend that
tuning occurred. The older complete walkthrough uses a practice prompt in that
slot; its coefficient is also fixed in advance.

The portable first-use recipe puts prompt texts and its recorded settings at the
top. For a new question, change the texts before the first run while preserving
their IDs, row order and roles, and use a new output directory. Keep the supplied
CPU/context-512/no-stop configuration: these fields are fixed in the execution
body, not general configuration switches. The example's README lists the limits
of adaptation. The record of the original study remains unchanged.

## Read the graphics correctly

- `plot(model)` describes the model and configured interventions. It is not an
  activation heatmap or evidence that a component causes an outcome.
- A comparison plot depicts the returned `llm_compare()` table. Matching input
  history permits a coordinate difference; causal claims need additional design.
- A timeline depicts additive revisions. A static projection can be active while
  the additive history is empty.

Export at a readable size instead of photographing a narrow RStudio plot pane.
The [graphics vignette](../rebirth/vignettes/model-interventions.qmd) includes
PNG/PDF and CSV/RDS examples. Saved observations can be replotted without running
the model again. CSV does not preserve all R attributes; retain the trusted RDS
alongside it, and never load an untrusted RDS file.

## Bound the work

Start with one small model, one derived handle at a time, one or a few layers,
and `positions = "last"`. Prompt tracing runs a forward pass without sampling.
Async generation uses optional `later` and `promises`; a noninteractive R script
must service the event loop and wait for settlement, as the walkthrough does.
Calling `llm_cancel()` requests cancellation; it does not forcibly terminate an
R process or guarantee a wall-clock/memory ceiling.

Use the [support matrix](supported-workflow.md) before combining model types,
components and operators. For a record of what a less-contextualized agent could
actually accomplish, read the [first-use assessment](research-first-use.md).
