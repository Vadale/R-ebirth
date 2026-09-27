# S1 — Bounded native structured generation

Date: 2026-09-27. Decision: approved [D-030](../DECISIONS.md#d-030--bounded-structured-generation-for-the-funding-pilot).
Status: implemented and locally validated; cross-platform CI and the Linux CPU
measurement remain integration gates. No release has been tagged.

## Delivered behavior

`llm_generate(..., schema = NULL)` preserves default generation. Supplying a
scalar UTF-8 JSON schema enables the [approved subset](s0-output-contract.md):
closed required objects, bounded strings/integers, string enums, booleans and
the specified nullable forms. Unsupported constraints fail before decoding.
The return remains a character vector with its names and seed attribute.

```r
schema <- '{"type":"object","properties":{"label":{"type":"string","enum":["yes","no"]}},"required":["label"],"additionalProperties":false}'
answer <- llm_generate(m, "Classify: is water a liquid?", schema = schema,
                       temperature = 0, seed = 1, max_tokens = 64)
```

The schema is compiled once per vector call. Every prompt gets an independent
native grammar state. The existing prompt chunking and continuation path are
reused. `schema = NULL` follows the original sampler; constrained sampling masks
the vocabulary before the same sampler. Successful output is checked again
against the supported schema. Token, context, output, grammar and input budgets
are bounded; exhaustion returns `relm_error_structured_output` with the prompt
index, seed, generated-token count and bounded partial bytes. Schema failures
use `relm_error_schema`. There is no implicit retry, repair or partial-vector
success. Nonempty image/stop inputs are rejected in this mode.

`schema.rs` owns the compiler and independent value validator; `structured.rs`
owns state lifetimes; the relm-owned `native/grammar.cpp` catches C++ exceptions.
No vendored engine source or existing golden changed. Native grammar masking
uses bounded batches to limit temporary memory. Greedy mode visits candidates
in exact argmax order and stops at the first admissible token; sampled mode
masks the complete distribution. Equivalence, including tied positive/negative
zero logits, is checked against full masking on the pinned vocabulary.

The generated form uses sorted keys and at most one ASCII space at each grammar
spacing position, preventing whitespace-only continuations. The validator
accepts every legal JSON whitespace character and arbitrary object-key order.
Neither formatting nor the schema establishes factual or cross-field validity.

## Checks and execution homes

| Check | Evidence / execution home |
|---|---|
| Parser, schema compiler, bounded grammar, Unicode/number edge cases | Rust engine tests in `rust.yaml`; upstream code-point grammar oracle is independent of relm's validator |
| Existing numerical behavior | Unchanged synthetic logits, trace and intervention goldens; default and no-spill Cargo tests |
| Public arguments and conditions | `test-structured-output.R` in R-CMD-check; model-free invalid schemas use the tiny committed fixture |
| Names/seeds, chunked prompts, exhaustion and handle reuse | Same R file with `RELM_TEST_MODEL_QWEN`; local and model-tolerance nightly |
| Exact final context position, all-masked candidates, greedy-mask equivalence | `structured_context_boundary_and_masked_sampling_model` with Qwen; explicitly invoked by model-tolerance nightly |
| Timing/memory/schema validity | `run-model.py`; local Mac Metal, Linux CPU in model-tolerance nightly; driver self-tests in `rust.yaml` |
| Dependencies and native linking | Locked approved Serde versions, archive twin pin, cargo-deny; Linux oldrel CI builds Rust 1.85.0, Intel macOS cross-link job checks the new archive |

The full installed-package R suite passed **1,068 expectations, zero failures,
seven skips** on macOS arm64 with R 4.5.1, cached Qwen and vision assets,
`NOT_CRAN=true`. Skips are the opt-in download and six unprovided modern-model
checks. The new R file contributes 100 passing expectations. This is actual
R 4.5.1 evidence, not a claim to have tested local R 4.6.1. Final Rust default/
no-spill tests, FFI tests, formatting, Clippy and vendor-integrity checks passed. Supply-chain checks
passed with the pre-existing duplicate/unmaintained-package warnings; the final local
advisory check refreshed the RustSec database. The source build and `R CMD check --no-manual` passed with zero errors,
warnings and notes, including rendered vignettes. Remote execution results
belong to the PR/workflow records described below.

One integrated implementation review and one focused review of the masking
optimization were completed. Findings corrected before acceptance include
checking context capacity before accepting a token and treating equal signed
zero logits in the same order as the existing argmax. No repeated broad review
or golden regeneration was used.

## Operational measurement

The [recorded Mac Metal report](../tests/structured-output/measurements/macos-metal-2026-09-27/report.json)
retains timings, output bytes/digests, model/schema/input hashes, native-library
hash and runtime metadata. It uses the pinned Qwen2.5-0.5B-Instruct Q8_0 on an M4,
one fixed **development** excerpt, one warmup and three measured greedy runs per
mode, separate processes and no concurrent build. Native token counts are
observed from an internal diagnostic payload while timing the public R call;
the public return shape is unchanged.

| Quantity | Unconstrained | Structured |
|---|---:|---:|
| Generated tokens per measured run | 80 | 64 |
| Median seconds per generated token | 0.0112875 | 0.01728125 |
| Process peak RSS (bytes) | 909,508,608 | 903,020,544 |
| Successful schema-valid runs including warmup | 4/4 | 4/4 |

Time ratio **1.531× ≤2×**; additional peak RSS **0 MiB ≤128 MiB** (the signed
difference is negative, reflecting whole-process variation; this is not a
zero-allocation claim). RSS includes model loading/warmup and does not isolate
all GPU allocations. One short case, three repeats and fixed mode order are
engineering evidence for this gate, not a general throughput guarantee.

Failed development measurements are not discarded: unrestricted whitespace
initially exhausted 512 tokens; compact formatting fixed that. Applying grammar
to the whole vocabulary at once then measured **2.231×** and **295.5 MiB** extra
RSS, failing both thresholds. Bounded batches and exact greedy early selection
fixed the memory cost. An intermediate run overlapped a Cargo compilation and
measured **2.062×**, **11.1 MiB**, failing latency; the uncontended run above
followed without a threshold change. Original logs remain in the owner's local
task evidence; the final portable report is committed.

Both modes still fail the report-only task consistency checks on this example.
Schema validity does not ensure correct evidence or missingness semantics. D1
must select its prompt/model on development data, freeze the candidate, then
run the held-out application gate and report correction effort. D2 owns offline
setup, result persistence and interruption/resume. No batch/service capability,
Windows/CUDA acceptance or broad extraction-quality claim is delivered by S1.

## Integration acceptance

The source package build includes rendered Quarto vignettes. The first local
build could not find Quarto; selecting the already-installed Quarto 1.10.18
resolved that environment error without changing vignette code. `R CMD check --no-manual` then completed with **Status: OK**, zero errors,
warnings and notes.

The PR check summary and model-tolerance workflow artifact are the execution
record for macOS/Linux, Rust 1.85.0 and the Linux CPU operational comparison.
The PR description records their final results and run links. S1 is accepted
only when those gates pass; D1 is the next work package. This document records
the local pre-push measurements and does not predict remote outcomes.
