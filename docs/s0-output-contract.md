# S0 — Funding extraction and constrained-output contract

Date: 2026-09-27. Base: `5dc15c5` (planning PR #43, all checks passed).
Status: reference artifacts complete; **D-030 approved by the founder on
2026-09-27**. S0 itself changed no generation code or dependencies. S1 implements
this contract; its evidence is recorded in [the implementation report](s1-implementation.md).

## 1. S0 acceptance and deliverables

The ROADMAP acceptance copied at start:

> Commit the corpus manifest, labelled pilot and split assignments;
> audit zero document-group overlap; give the constrained-output, extraction and
> batch-artifact gates a runnable command, fixture, threshold and owner. WP11a and
> WP12a specify their later statistical/service gates. The exact API/dependency
> proposals require their separate approval before S1. This update does not
> claim those artifacts exist.

Delivered artifacts: [pilot and codebook](../tests/structured-output/README.md),
[32 cases](../tests/structured-output/cases.json),
[source manifest](../tests/structured-output/manifest.json),
[output schema](../tests/structured-output/output.schema.json),
[offline checker/scorer](../tests/structured-output/verify.py) and
[simple baselines](../tests/structured-output/baseline.py), plus a
[fixture-only batch example](../tests/structured-output/batch-contract.json) and
[offline identity/state check](../tests/structured-output/check_batch_contract.py).
There are 23 source-derived cases from seven historical documents (five related
source groups), plus nine constructed contract cases. This replaces no larger
evaluation: D1 must report the limitations or freeze an expanded version before
tuning. No trained model or constrained-output runtime has been evaluated.

The selected task is an evidence-linked extraction of USD amount, qualifier,
funding period and any explicit funding-availability condition, for a requested
programme/scope. It tests numbers with multiple possible meanings without first
requiring PDF parsing, retrieval, a service or an additional model.

## 2. Recommended public contract — approved

Append one argument to the approved generation signature:

```r
llm_generate(m, prompt, max_tokens = 256, temperature = 0.8,
             top_p = 0.95, seed = NULL, chat = TRUE, stop = NULL,
             images = NULL, schema = NULL)
```

- `schema = NULL`: retain current behavior, named character-vector return,
  seed attribute and unconstrained numerical goldens.
- Otherwise `schema` is one non-NA UTF-8 character string containing JSON Schema
  text. No path interpretation, R-list coercion, public grammar argument or new
  exported helper. One schema applies to all prompts.
- Return the same named character vector plus the existing seed attribute;
  every successful element is complete, independently validated JSON text.
  Automatic table/list conversion is not part of S1. The application parses its
  fixed record separately; any R parsing dependency gets its own D1 proposal.
- Explicitly describe the task/fields in the prompt. Schema enforcement does not
  silently rewrite prompts or establish factual correctness.
- With a schema, reject nonempty `stop` and image-bearing requests before decode.
  Empty stop/image collections count as absent. A vision-capable handle may still
  perform a text-only request. Default text/vision behavior remains unchanged.
- Validate/compile once per call, then use fresh grammar state per prompt.
  Sequential vectorization preserves names and current scalar-seed reuse. The
  first failed element raises a condition; there is no partly successful vector.
  The batch application calls one document at a time.

## 3. Supported schema profile — approved

Use a small explicit profile of JSON Schema 2020-12, not a claim of full support.
Reject any unsupported keyword before decode, including annotations. Optional
root `$schema` must equal `https://json-schema.org/draft/2020-12/schema`.

| Type | Required semantics |
|---|---|
| Root object | Non-nullable; `properties`, `required`, `additionalProperties: false` explicitly present. |
| Nested object | Same closed/required contract. Every property occurs exactly once in `required`; no defaults or omitted optional fields. |
| String | Either a nonempty, unique string-only `enum` on a nonnullable string, or explicit `maxLength` with optional `minLength` defaulting to zero. Limits count decoded Unicode scalar values, not bytes or grapheme clusters. |
| Integer | Explicit integral `minimum` and `maximum`, ordered within -2147483648..2147483647. Decimal integer lexemes only; fractions/exponents rejected. No floating-point conversion. |
| Boolean / null | Ordinary JSON booleans and null. |
| Nullable value | `type` array of exactly one supported non-null type plus `null`; type-specific constraints apply to the non-null branch. Reject `enum` on nullable types: an enum also constrains null under JSON Schema semantics. |

Reject arrays, `number`, `$ref`, definitions, combinators, patterns, formats,
`const`, dependencies and all unspecified extras. The fixed-record pilot needs
none of these. Preserve schema semantics by requiring explicit closed/required
objects and integer bounds, rather than silently narrowing a general schema.
Generated keys follow UTF-8 lexicographic order, with compact spacing (at most
one ASCII space at each separator). This avoids whitespace-only generation
loops without restricting the JSON values. Validation accepts any key order and
ordinary JSON whitespace.
Reject duplicate object keys, including escaped-equivalent keys, in schemas and
outputs. Decode Unicode strictly without normalization or replacement characters.

## 4. Implementation choice and dependencies — approved

**Recommendation:** keep the current SplitMix64/argmax/top-p sampler and mask its
candidate logits through the existing b9726 grammar sampler before selection.
Add a small compiler for the profile above and an independently structured output
validator. Reuse an established JSON parser; do not write general JSON parsing.

Approved direct Rust dependencies in `rebirth-llm`:

```toml
serde = { version = "=1.0.228", default-features = false, features = ["std"] }
serde_json = { version = "=1.0.145", default-features = false, features = ["std"] }
```

These inspected release manifests declare compatible licenses and compiler
requirements; this is not an executed MSRV or supply-chain check. The expected
transitives include `serde_core`, `itoa`, `memchr` and `ryu`; S1 must resolve, pin
and audit the complete graph under Rust 1.85 before accepting it. Existing CRAN
vendoring remains in its planned phase. No R dependency is added by S1.

Use Serde's visitor interface to reject duplicate keys and enforce limits.
Plain `serde_json::Value` parsing loses duplicate-key evidence. The compiler and
validator share the profile definition but must not validate by reusing generated
grammar; fixture-specific Python assertions provide an additional independent
check. Integer interval grammar construction uses exact integer arithmetic.

Alternative considered: restore the upstream C++ schema converter and its JSON
dependency. That offers broader conversion but restores pruned vendored/build
surface and still needs strict screening and output validation. Choose the narrow
Rust profile for this fixed-record milestone; do not silently broaden it later.

## 5. Completion, errors and bounds — approved

Own/free a native grammar sampler per prompt. Apply its mask before relm selects
a token; preserve token IDs, tie ordering and RNG behavior. Detect an all-masked
distribution before argmax/softmax. Accept only selected admissible tokens into
grammar state. Validate native layouts and ownership; prevent new C++ exceptions
crossing Rust through an exception-catching bridge where required.

When the grammar admits EOG, strictly decode and independently validate the
complete root object and return it immediately; use a neutral EOG score to test
grammar acceptance, not the model's EOG logit. Prove this behavior against b9726
with direct fixtures. Completion on the last allowed token succeeds. Otherwise
token/context/output-budget exhaustion is a failure. No silent retry, repair,
brace insertion, markdown removal or partial-success return.

New approved conditions, inheriting `relm_error`:

- `relm_error_schema`: malformed/unsupported schema or compilation bounds;
  fields `reason` and JSON-pointer `schema_path`.
- `relm_error_structured_output`: incomplete/invalid output, no admissible token
  or output budget; fields `reason`, 1-based `prompt_id`, `seed`,
  `generated_tokens`, and bounded `partial_bytes` as an R raw vector.

Existing argument/model/backend classes remain. Input context overflow retains
`relm_error_context_overflow`; exhaustion while generating constrained output uses
the structured-output condition. Core generation performs no filesystem writes.

| Resource | Approved hard bound |
|---|---|
| Schema UTF-8 text / nesting / nodes | 64 KiB / 8 / 128 |
| Properties per object / total | 16 / 64 |
| Enum members / member length | 32 / 128 decoded scalar values |
| String `maxLength` | 2048 decoded scalar values |
| Compiled grammar | 512 KiB and 65536 grammar elements |
| Prompts per constrained call | 128; 1 MiB each and 16 MiB total UTF-8 input |
| `max_tokens` | At most 8192 in constrained mode |
| Output bytes | 64 KiB per prompt; 8 MiB per call |

Check limits before growing buffers. Shared R/Rust limits get equality tests.
These bound scope; they are not measured throughput/memory results.

## 6. Minimal batch artifact contract — D2, not implemented

S0 includes a hand-assembled manifest/result example and a runnable offline
checker linked above. It establishes the configuration identity and the expected
committed/interrupted/missing decisions without executing a batch runner. The
fixture README defines its canonical encoding; D2 must test the actual R writer
against these bytes. An example copied from a label is not model output.

One writer processes one document at a time. A versioned UTF-8 JSON manifest
identifies relm/native build, R/packages, backend, model/projector SHA256, schema,
prompt-template and source digests, explicit sampling parameters and per-document
seeds. Pure configuration and ordinary data are persisted, never native pointers.

Document results are complete UTF-8 JSON records containing stable input ID,
run-identity digest, status, parsed output or condition information. Commit via a
temporary file in the same directory and atomic rename; the single writer must
refuse to replace a mismatched existing result. An output-directory lock refuses
a second writer; stale locks require explicit recovery, not guesses from age.
A matching committed result is skipped on resume; an interrupted or missing one
is retried with the same seed. An existing mismatched run is refused; a changed
configuration needs a new output directory. No universal exactly-once claim or
cross-filesystem atomicity promise.

The application writes concise events (ID, status, timing, condition class), with
document content confined to explicit result artifacts. Caller-owned directories
survive process restart; managed activation-spill directories are not job stores.
Hash bytes with a tested SHA256 tool; the concrete runtime JSON/hash dependencies
must be selected before D2 implementation. Do not introduce them into core as a
side effect of this contract. Setup and run are separate commands; run is offline
after packages and models have been explicitly prepared.

## 7. Gates and ownership

| Gate | Command / fixture | Threshold and owner | Current status |
|---|---|---|---|
| S0 integrity | `python3 tests/structured-output/verify.py --self-test` | All hashes, spans, records, grouped splits and corruption guards pass; WP owner | Implemented; record run evidence below |
| S0 batch artifacts | `python3 tests/structured-output/check_batch_contract.py`; `batch-contract.json` | Matching committed result skips; interrupted/missing retry; stale model/prompt/schema/source, seed, duplicate ID and corrupt output fail; WP owner | Offline example implemented; no runtime recovery claim |
| Reference comparators | `python3 tests/structured-output/baseline.py` | Report both baselines on all partitions, with failures counted; WP owner | Implemented; not an LLM benchmark |
| S1 parser/compiler/native path | Rust engine tests and `test-structured-output.R`; existing Rust/R PR workflows | Zero invalid successful fixture results, unsupported schemas fail before decode, unchanged unconstrained goldens; owner + integrated reviewer | Implemented; local checks pass; see [S1 evidence](s1-implementation.md) for integration status |
| S1 operational comparison | `python3 tests/structured-output/run-model.py --model MODEL --backend metal --output NEW_DIR` (Linux: `--backend cpu`) | Pinned Qwen2.5-0.5B; median time per native generated token ≤2× unconstrained and additional process peak RSS ≤128 MiB; owner | Mac Metal passes (1.53×, no positive peak-RSS increase); Linux CPU in the model-tolerance workflow |
| D1 extraction | `python3 tests/structured-output/verify.py --predictions RUN.jsonl --split held_out --gate` | README's numeric pilot gate, semantic review and baseline comparison; owner/reviewer | Scorer exists; model outputs and review not run |
| D2 restart | Future `Rscript tests/structured-output/test-batch.R` using pinned tiny-fixture config and a controlled stop after document 2 | Completed results byte-identical after resume, no duplicate IDs, unfinished item retried, changed identities refused, second writer rejected; owner | Runner/test not implemented/run |
| D2 clean operation | Future example `setup.R` then `run.R --config CONFIG` in clean Mac/Linux CPU environments | Run with network disabled after setup, record setup/first-result time and peak memory; owner | Not implemented/run |

S1 adversarial coverage includes integer endpoints, unsupported keywords,
duplicate keys, schema/resource limits, Unicode escape equivalence and surrogate
errors, token boundaries inside UTF-8, premature EOS, all-masked candidates,
completion at exact budgets, image/stop policy and handle reuse after failure.
Default numerical references remain unchanged. Reuse existing decode chunking.
No full native rebuild is needed to validate these S0 documents/data (D-029).

### S0 local evidence

`verify.py --self-test` passed all 32 records, seven snapshot hashes, source spans,
related-document split checks and corruption/metric guards.
`check_batch_contract.py` also passed; it checks only reference artifact
identities and expected states, not the future runner. The fixed baselines
ran once against the frozen artifact version. Held-out results: always-missing
6/10 exact records, 0/4 known amounts; first-amount 6/10 exact records, 2/4 known
amounts and 9/14 unsupported emitted nonmissing fields. Neither meets the gate.
These outcomes illustrate scope/abstention pitfalls and do not evaluate an LLM.
These are S0's offline results. Subsequent native/runtime evidence is recorded
in [S1 implementation](s1-implementation.md); batch operation remains D2.

## 8. Review and next action

One architect reviewed the design and then the integrated S0 package. Two
material findings were corrected: nullable enums are rejected without changing
JSON Schema semantics, and batch artifacts now have an executable offline
reference check. No further broad review or unchanged native rebuild is needed.

The founder approved D-030 as one coherent decision: appended `schema` argument,
restricted profile, return/error behavior, resource limits and the two proposed
Rust dependencies. Implement S1 locally and push at a reviewable milestone.
Routine implementation choices within that approved contract remain the owner's.

Design sources: [JSON Schema objects](https://json-schema.org/understanding-json-schema/reference/object),
[llama.cpp grammars](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md),
[Serde 1.0.228 manifest](https://docs.rs/crate/serde/1.0.228/source/Cargo.toml),
[serde_json 1.0.145 manifest](https://docs.rs/crate/serde_json/1.0.145/source/Cargo.toml).
Local b9726 and relm's custom continuation loop were inspected by the architect;
upstream documentation alone was not treated as an implemented relm capability.
