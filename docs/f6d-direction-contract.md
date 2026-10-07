# Contrast directions and held-out evaluation

Date: 2026-10-07. **D-045 / API-GRAMMAR section 13: APPROVED.** The founder
replied "Vai" after this concrete proposal and the explicit API, temporary-file
and recorded-provenance question. Proposal history remains in commit c4befed.
No approval is pending for this scope; implementation/acceptance are separate.
D-042/D-043 continue to bind the product objective and sequence.

## 1 Small public surface

```r
llm_direction(target, control, context, layer,
              normalize_pairs = FALSE, orthogonalize = FALSE,
              max_bytes = 64 * 1024^2)

llm_apply_direction(m, direction, context, coef = 1,
                    max_bytes = 64 * 1024^2)

print.relm_direction(x, ...)
```

The constructor consumes already collected, paired activation matrices. It
performs no inference. One artifact describes one full-width residual direction
at one layer. The application function validates it and delegates to existing
`llm_steer()`, returning its fresh model handle. Existing numeric-vector steering,
generation, live coefficients, comparisons and plotting remain unchanged.

The artifact is a plain data frame with class
`c("relm_direction", "data.frame")`, exactly `neuron` (integer) and `value`
(double) columns, and validated metadata attributes. This preserves the base-R
return grammar and prevents accidental passage of the whole artifact to the
numeric-only `llm_steer(direction=)`. Deliberately extracting `$value` still gives
a raw vector; applying that through `llm_steer()` bypasses artifact checks.
`print()` gives a one-screen summary and returns `x` invisibly; nonempty `...`
is rejected. There is no new plot method, experiment runner or storage format.

Use caller-owned `saveRDS()` / `readRDS()` for trusted artifacts. Read-back
validation is mandatory in `llm_apply_direction()` and `print()`; no native
operation occurs before compatibility/integrity checks pass. A loaded artifact
holds no pointer, environment, trace, lease, training matrix or model path.

## 2 Inputs and recorded context

`target` and `control` are plain double matrices with identical dimensions
`N x H`, at least two pairs, and finite values. Their identical row names are
explicit, nonempty, unique pair IDs; identical column names are exactly
`as.character(seq_len(H))`, in order. No reordering, recycling, implicit
coercion, missing-neuron filling or dropping of observations is allowed.
Custom classes/attributes beyond ordinary matrix dimensions/names are rejected.
Layer is a whole scalar in `2:context$model$layers`; layer 1 is excluded because
the existing additive mechanism cannot steer it. Both logical options are
nonmissing scalar logicals.

`context` is an ordinary list with exactly these entries:

| Entry | Exact contents |
|---|---|
| `model` | List: `sha256`, `architecture`, `quantization`, `hidden_size`, `layers`, `engine_revision`. The checksum identifies the declared GGUF bytes, including embedded tokenizer data; geometry is positive integer and must match `H`. Engine revision identifies the capture build, including its patch revision, rather than only an upstream tag. |
| `capture` | List: `component = "residual"`, `positions = "last"`, `input_format = "raw_text"`, `tokenizer = "gguf_embedded"`, `add_special = TRUE`, `parse_special = FALSE`, `template_sha256 = NULL`, `context_length`, `backend`, `relm_version`. Context length is positive integer, backend is an explicit resolved backend, and package version is nonempty. No external/chat template is claimed in this first profile. |
| `pairs` | Data frame: `pair_id`, `target_sha256`, `control_sha256`, `target_pos`, `control_pos`. Row order exactly matches both matrices; source positions are positive integers within the recorded context length. Digests identify the exact UTF-8 prompt bytes, without newline or Unicode normalization. |
| `splits` | Data frame: `prompt_sha256`, `split`, with one unique digest per row. Split is `construction`, `selection` or `evaluation`; each is nonempty. The construction digest set is exactly the set used in `pairs`. No prompt digest occurs in multiple splits. Preserve this declared split before fitting. |
| `seed` | `NULL` or one nonnegative integer through `.Machine$integer.max`, recording construction-corpus randomization. Trace itself performs no sampling and this function neither draws nor changes the R RNG. Evaluation seeds are separate records. |

Checksums are 64 lowercase hexadecimal characters. Character scalars are valid
UTF-8; pair IDs are at most 128 bytes and other free text at most 256 bytes.
Unknown fields, missing values and arbitrary nested objects are rejected.
Bounds are `N <= 4096`, `H <= 65536`, at most 16384 split rows and at most
8 MiB of materialized context. These are admission limits, not recommended
experiment sizes. Validate the bounded schema before allocating validation
vectors or canonical copies. Matrix data are checked row by row.

The constructor can detect exact-prompt overlap in the declared manifest, not
semantic paraphrases, undisclosed data or incorrect capture labels. It does not
prove that supplied matrix rows were generated from the supplied text hashes.
The reproducible collection script must supply and verify that evidence.

## 3 Direction arithmetic

For each construction pair, let `t_i` and `c_i` be its full residual vectors.
The positive direction is always **target minus control**:

1. Compute `d_i = t_i - c_i` in double precision.
2. With `normalize_pairs = TRUE`, replace each `d_i` by its unit vector;
   otherwise retain its magnitude.
3. Average the resulting pair differences in the recorded row order to get `d`.
4. With `orthogonalize = TRUE`, form the mean of the **original** control rows,
   `c_bar`, normalize it to `u`, and replace `d` by `d - u * sum(u * d)`.
5. Normalize the final result to unit Euclidean length.

Pair normalization changes weighting. Orthogonalization removes the component
parallel to the construction control mean. They are independent, opt-in choices;
neither is described as universally better. F6d does not implement the runtime
projection edit `h - alpha * v * dot(v, h)`; that remains F6e.

Use a scaled norm to avoid squaring overflow; reject nonfinite differences or
intermediate results. A pair is degenerate when its difference norm is zero or
at most `64 * .Machine$double.eps` times the larger input-row norm. Reject it,
with the pair ID, under either option; never silently discard it. Reject a
zero/unstably cancelled mean at the same relative threshold against the mean
pair norm. Orthogonalization additionally rejects a zero/unstably cancelled
control mean against the mean original control-row norm, and a
remaining norm at most that threshold times the pre-projection norm. These
new algorithmic guards are frozen before goldens; no existing tolerance changes.
Record the operation order, input/difference norms, pre/post projection norms
and final norm. No centering, PCA, automatic sign flip, layer search or fitting
on selection/evaluation activations is hidden inside construction.

The persisted values are doubles. Existing native steering converts them to
its existing float representation; coefficient units refer to this unit
direction, not to pair count or an unstated activation standard deviation.

## 4 Artifact integrity and persistence

Metadata is in a single `direction` attribute with a versioned, fixed schema:
`schema = "relm_direction/1"`, `layer`, `component`, `context`, `method`,
`diagnostics`, `producer`, `digests`. Method holds the two logical options and
the exact algorithm identifier. Diagnostics contain only the bounded scalar
and per-pair norm records above. Producer records relm/R versions; it does not
replace the separately recorded capture build. Digests cover target/control
matrix coordinates and values, corpus pair order, split manifest, output vector
and the complete artifact payload excluding its own payload-digest field.

Freeze a language-independent canonical encoding alongside the reference:
domain/schema prefix, fixed field order, explicit type tags and dimensions,
little-endian integer/double values and length-prefixed UTF-8 strings. Matrix
values are encoded in row-major coordinate order. Finite IEEE-754 doubles,
including signed zero, retain their bits; reject NaN/Inf. Encode NULL explicitly;
never hash R printer output, locale-dependent decimal text, a model filename or
an arbitrary compressed RDS serialization. Fixed field order is canonicalized
only after exact-name validation. Coordinate/pair order is never canonicalized
by sorting away a mismatch.

`tools::sha256sum()` is already used by the package and needs no dependency.
It hashes files, so this approved contract explicitly permits **temporary canonical
checksum files** for these two functions and the validator used by printing.
Write in bounded chunks to unique files in the session temporary directory,
close descriptors and unlink on success/error/interrupt. Keep at most one file
alive at once; cap its bytes using the admitted canonical-size estimate. No
model file, user artifact or caller-selected path is written or overwritten.
Disk-full/hash failures are classed errors, not a fallback to unchecked vectors.
This is a narrow approved amendment to API-GRAMMAR rule 9, not an implicit write.

RDS round-trips must preserve exact values, schema and metadata. Validation
checks the payload digest, coordinates, finite unit norm and all semantic
invariants, not only class names. A wrong schema, altered coefficient, layer,
model digest or split record fails before native derivation. Checksums detect
accidental changes; a party can edit both the data and its checksums. This is
not a signature, authentication protocol or safe untrusted-RDS importer.
Caller `readRDS()` allocation happens before validation and is outside F6d's
working-memory bound. Do not load untrusted serialized R objects.

## 5 Checked application and identity limits

For `llm_apply_direction()`, `context` is exactly a destination **model record**
with the six fields of construction `context$model`, recorded independently
for the actual loaded model. Require exact equality with the artifact's model
record. Also compare declared architecture, quantization and geometry with the
handle's metadata, verify residual coordinates/layer, and run all artifact
checks before delegating to:

```r
llm_steer(m, layer = recorded_layer, direction = checked_values,
          coef = coef, positions = "all")
```

Reuse current coefficient checks, runtime intervention sentinel, native geometry
checks, busy/closed conditions and immutable-handle ownership. Existing
interventions compose by the existing sum/steer-before-ablate rules. No sampled
text or native operation is needed for artifact validation; the delegated
steering call retains its existing capability probe and fresh-context cost.
Zero/negative coefficients are valid with existing semantics. F6b can change
the new entry's coefficient using its existing applied audit.

**The model binding is recorded provenance plus compatibility checks, not
authentication of loaded weights.** Current handles/native metadata carry no
durable checkpoint hash. R metadata is editable. Hashing `m$path` after loading
does not prove the bytes used by that handle if the file was replaced; even
before/after path hashes do not create an atomic loader binding. This proposal
does not claim to solve that problem or quietly hash every model load.

The supported recipe verifies the pinned cached file, keeps it unchanged during
load/capture/evaluation, records its checksum and derives experimental handles
from that same original handle. File immutability and truthful records are
explicit experiment assumptions. Across sessions, verify the pinned file and
recreate the handle; copying the artifact's record into an unrelated handle is
not validation. Same width, same architecture or same path is insufficient.
Automatic loaded-weight attestation would require a separate loader contract;
the founder approved this narrower, honest F6d boundary.

## 6 Memory and side effects

`max_bytes` is a finite whole number from 1 MiB through 512 MiB, default 64 MiB.
It admits the constructor's materialized inputs, bounded working arrays,
validation/canonicalization workspace and returned object. It is not total R
heap/RSS, model/KV memory, device memory or memory retained by the caller.

Let `I` be the sum of materialized input-matrix sizes and context size, `M` the
context size, `N` pairs and `H` width. A conservative initial ledger is
`I + 4*M + 2^20 + 8*(40*H + 16*N) + 4*(N + H)`. Charge labels, metadata copies,
diagnostics, output frame and hashing buffers, not just the vector's `8*H`.
Implementation must freeze a measured full ledger before acceptance and stay
within this admitted envelope; if it cannot, report the mismatch before
expanding the contract. Scalar/row validation and incremental accumulation
must not allocate an `N x H` difference matrix. There are no input copies for
sorting or concatenating all pairs. Constructor output `object.size` and actual
working-array/canonical buffer maxima must be checked independently.

Application/printing validate within the same bounded metadata/width profile;
application's caller-selected budget covers its resident artifact/context and
validation copies before allocating any fresh native context. Printing uses the
64 MiB default and never derives a handle. Capture and slice materialization
remain governed by their own existing contracts; an ordinary spilled
`as.matrix(trace)` still materializes its selected slice. This constructor is
not an out-of-core matrix engine. The recipe collects one bounded prompt pair
at a time, preflights the final matrix pair, and releases each trace before the
next capture; larger work must use smaller, explicitly designed experiments.

No global RNG/options/working-directory/search-path change, model download,
model loading or automatic output file is introduced. Use existing
`relm_error_argument` for malformed input, `relm_error_intervention` with
specific reasons for degenerate directions, incompatible/corrupt artifacts and
checksum I/O, and `relm_error_oom` for admission. Propagate existing native
busy/closed/intervention conditions. Preserve original parent I/O conditions.

## 7 Acceptance and proportional execution plan

The approved roadmap acceptance is retained verbatim:

> an independent small reference verifies direction arithmetic and
> normalization; save/reload preserves exact values and provenance and rejects
> incompatible artifacts. A bounded cached-model example evaluates held-out
> prompts without leaking them into direction or coefficient selection. Base-R
> tables expose numerical results underlying each plot. Approve concrete artifact,
> side-effect and public API contracts before implementation; no new dependency
> or model download follows from this roadmap decision.

Execute in this order:

1. Add an independent small Python reference under
   `tests/llm-golden/directions/`, using the pinned reference environment. Freeze
   all four normalization/projection combinations, direction sign, unequal pair
   magnitudes, nonorthogonal control mean and degenerate cases before product
   code. Independently encode canonical bytes/digests too. New goldens get their
   own commit; existing model/golden inputs remain unchanged. Compare double
   arithmetic with absolute-plus-relative tolerance `1e-12`, fixed before code.
2. Model-free installed R tests cover shape/order/schema/1-based boundaries,
   overlap/duplicate manifests, finite/degenerate arithmetic, unchanged inputs
   and RNG, exact RDS round-trip, corruption/incompatibility refusals, I/O
   cleanup, memory admission and measured object/working-buffer bounds. They
   run on all four ordinary R CI legs. Add both new exports to the exact public
   export guard in the implementation milestone.
3. A new bounded `[MODEL]` case uses the already cached pinned Qwen. Verify
   artifact application equals raw-vector application and zero equals baseline
   for fixed-seed/parameter runs, then original-handle reset. Use the existing
   accepted native library if native sources/dependencies are unchanged;
   do not infer new native acceptance or rebuild unchanged vendor code.
4. Freeze the evaluation protocol/data hashes before its first model run:
   12 construction pairs, 6 selection tasks and 8 final tasks on disjoint
   content; one predeclared residual layer. Use a concise-versus-elaborated
   answer contrast on simple synthetic factual tasks with prewritten required
   answer strings. Record literal-answer inclusion, character/token counts,
   truncation and repeated-output counts; these are limited operational
   measures, not a general quality judge. Use raw text consistently with the
   capture profile; retain exact prompts, settings and outputs.
5. On selection tasks compare the original handle, zero, learned direction
   coefficients `-2, -1, 1, 2` and a separately seeded norm-matched random
   direction. Choose at most one learned coefficient by a predeclared rule
   using selection data only; ties/failed quality safeguards select zero.
   A nonzero coefficient is eligible only if each selection task retains the
   baseline's required-answer inclusion, with no additional empty, truncated
   or repeated output and lower mean character count. Among eligible settings
   choose the lowest mean character count, then smallest absolute coefficient,
   then smaller signed coefficient. Otherwise choose zero. Fix the random
   control coefficient at `1`. Use at most 64 generated tokens per task and a
   fixed recorded generation seed; no retry to improve outputs. Evaluate that frozen learned setting,
   baseline, zero and the frozen random control once on final tasks. Preserve
   failures/negative results and mark final data consumed; never retune using
   it. A beneficial behavioral effect is not an engineering acceptance gate.
6. Export ordinary per-task/aggregate tables and base-R dose-response/paired
   uncertainty plots. For paired mean differences use 2000 paired bootstrap
   resamples of tasks with a fixed separately recorded seed and percentile
   95% intervals; retain all resampling settings and clearly state their
   small-sample/conditional scope. Reuse F6c comparison/timeline for one bounded
   observed example; withhold coordinate deltas if full prefixes diverge. Do
   not use ordinary `llm_trace()` on an intervened handle. Retain all numerical
   data underlying plots. Close each derived handle before the next run.
7. One integrated implementation review, affected corrections/tests, executed
   vignette and package check; final ordinary nine-check CI on one coherent
   milestone. No repeat of accepted F6a/b/c/native/sanitizer/RStudio/service
   suites, unrelated nightly matrix or new download. A new foreground GUI
   acceptance is unnecessary for this constructor/application increment unless
   a changed UI path introduces a concrete risk. Use the existing 20-minute
   sparse monitor for long work and preserve every failed/source-scoped receipt.

## 8 Decision and next action

Approved: the two functions, one printing method, strict single-layer
paired-matrix profile, caller RDS persistence, bounded temporary checksum writes
and explicit recorded-provenance limitation above. This provides construction,
reuse and evaluation without a new inference framework or loader API.

Alternatives: automatic loaded-weight identity requires a separate load-binding
design and broader native/ownership acceptance; a prompt-to-experiment runner
duplicates existing generation/capture and adds orchestration/retention scope.
Neither is hidden inside this proposal. F6e projection remains the next increment.

The founder approved D-045. Next action: freeze the independent arithmetic and
encoding reference, then implement the bounded R constructor and
existing-steering adapter. No F6d API is implemented or accepted yet.
