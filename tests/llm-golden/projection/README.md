# F6e independent projection references

Reason recorded before generation: approved D-046 adds a new component-bound
projection feature, schema-2 direction artifacts and exact pre-residual editing
sites. These new references establish its arithmetic, byte encoding and causal
forward expectations before native product arithmetic. Existing accepted model
and golden files are immutable inputs; no old fixture is regenerated.

The producer uses the pinned `.golden-venv` (CPython 3.13.5, NumPy 2.5.1,
gguf 0.19.0) and never imports or calls product R/Rust code or a llama engine.
It reads the existing seeded three-layer F6b Llama GGUF, checks its SHA-256 and
all tensors against the independent seed producer, and writes only this new
feature's `goldens/` directory. Model weights are never rewritten.

Frozen comparison tolerances, declared before generation:

- Scalar/direction binary64 arithmetic: absolute plus relative `1e-12`.
- Checked binary32 projection site writes: absolute plus relative `2e-6`.
- Tiny-model downstream activations/logits: existing absolute `0.01`.

The independent forward uses binary64 model kernels with binary32 rounding at
component boundaries and one checked binary32 projection write. It is a
mathematical reference, not a model-engine execution or CPU/Metal acceptance.
Native callback placement, buffer mutation, synchronization, final-row pruning,
resources, lifecycle and throughput remain separate acceptance requirements.

## Frozen commands and results

From the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 .golden-venv/bin/python tests/llm-golden/projection/reference_projection.py --check
```

The initial `--write` command creates only a new empty `goldens/` directory and
refuses to overwrite one. `--check` recomputes this feature into a temporary
directory, runs every positive/negative control, and requires the same inventory
and exact bytes for every frozen output. No old producer entry point runs.
The producer emits `D046_REFERENCE_OK` only after completion.

Both initial write and check passed with CPython 3.13.5 / NumPy 2.5.1 /
gguf 0.19.0: 13 accepted arithmetic cases, 11 refusals, 52 expected coordinates,
11 schema-2 byte vectors (364 typed nodes), 3 pure site cases, 15 tiny-forward
cases and 191 explicit controls. The tiny forward covers 584 token inputs,
21,888 activation values, 3,648 logits, 2,944 pre/post site coordinate pairs and
1,108 executed projection-row witnesses. This is independent reference
acceptance only; no engine, native test, R model call or build was run.

## Fixture mapping

Every table is ordinary CSV; base R can use `read.csv()` and `readBin()` without
a JSON dependency. `manifest.json` is a convenience provenance/case summary;
all numerical inputs and expected outputs also exist in CSV/binary fixtures.

| Files in `goldens/` | Meaning |
|---|---|
| `arithmetic-cases.csv`, `arithmetic-inputs.csv`, `arithmetic-expected.csv` | F32 input rows, F64 directions/coefficient/dot, F64 updates and final F32 values/bits |
| `arithmetic-refusals.csv` | Nonunit/zero/nonfinite direction, invalid row/coefficient, width and checked F32 overflow guards; semicolon-delimited small vector inputs |
| `encoding-index.csv`, `encoding-fields.csv`, `*.bin`, `*.hex`, `artifact-digests.csv`, `prompts.csv` | Schema-2 typed primitive/matrix/context/full-artifact vectors; see [ENCODING.md](ENCODING.md) |
| `site-math.csv`, `site-math-inputs.csv` | Tiny explicit pre-add equations, including Llama post-Wo bias/scale and Qwen2 raw MLP output; no full Qwen model |
| `forward-cases.csv`, `forward-projections.csv`, `forward-tokens.csv` | Case settings, F64 projection directions and static coefficients, exact source token sequence/phase and dynamic additive coefficients |
| `forward-residual-interventions.csv` | Original additive direction at layer 2, followed by neuron-3 ablation to 0.25 in the two composition cases |
| `forward-sites.csv` | Component producer values immediately before and after projection |
| `forward-activations.csv`, `forward-logits.csv` | Post-edit attention/MLP, post-steer/ablate residual, full unsampled logits |
| `forward-row-witnesses.csv` | One dot/write/norm witness per executed projection row, including every long-prefix row |
| `controls.csv`, `sources.csv`, `provenance.csv`, `manifest.csv` | Named controls with measured deltas, source/input/version receipt, and output byte counts/SHA-256 |

`layer`, `neuron` and `source_pos` are public 1-based coordinates;
`token_id_native` is explicitly native 0-based. Tiny cases use fixed token IDs,
so token selection does not manufacture a causal logit difference. Non-long
cases have 3 prefill plus 2 decode tokens. The long case has 513 prefill plus
1 decode token, suitable for an eventual `n_batch=512` / smaller `n_ubatch`
native gate with context at least 768. It retains full vectors at positions
1, 2, 128, 512, 513 and 514 and scalar witnesses for every row. Its projections
are in the first layer; final-layer output pruning is not inferred from this
sequential mathematics.

## Arithmetic and comparison boundaries

The dot uses a plain binary64 addition loop in ascending coordinate order.
Updates evaluate `h[j] - (coef * v[j]) * dot` in binary64, check finite/F32 range,
and cast once. The reference refuses clearly nonunit inputs without correcting
them; its constructed unit vectors are checked within 1e-12. Zero coefficients
return the input F32 row without evaluating the dot or claiming a write (the
fixture's zero dot is a bypass marker). F32 inputs preserve signed-zero bits.
Decimal-90 controls independently verify scalar arithmetic. General/axis cases
cover removal, amplification, reversal, sign invariance and preservation of
the orthogonal component. Early F32 rounding of direction or coefficient fails
explicit controls. F32 overflow is reachable and refused; the valid bounded
input domain does not need an artificial binary64-overflow fixture.

The `2e-6` absolute-plus-relative site bound applies to projection arithmetic
on the **same supplied F32 input row**, as in `arithmetic-expected.csv` and the
small site equations. Tiny-model `forward-sites.csv`, captures and logits are
whole-forward references and use the existing absolute `0.01` downstream bound:
upstream independent F64 and engine F32 model kernels differ. This distinction
does not change either tolerance. The native gate must independently establish
both accurate row editing and causal consumption by subsequent nodes.

The forward's unprojected path differs from the existing independent F64
incremental oracle by at most 2.4489926353510327e-7 because component boundaries
are rounded to F32. Zero projections give bit-identical new-reference logits.
All components are edited before their residual addition, then residual steer
precedes ablation. Dynamic additive updates retain previous K/V without replay.
The deliberately wrong newest-coefficient full replay differs by at least
1.302269086223391 in logits. Missing/no-op/read-only/residual-site variants fail
fixed downstream comparisons; editing only the last long-prefill row differs
by 0.31714396870191075 at the final logits. No tolerance was selected from these
outcomes; controls require a gap greater than twice the predeclared 0.01 bound.

## Explicit limits

The read-only tiny GGUF has 3 layers, hidden width 32, vocabulary 48, F32 weights
and seed 20260705. Its SHA-256 remains
`e255ed5db07f318cbc3bd1d4d5a5a261bdef0867b3bbd1e26228f015b872bd05`.
Every tensor is compared against the accepted seed generator before use.
It has no optional output bias/scale; the pure site equations cover that order.
Schema-2 artifacts use small synthetic supplied matrices and example provenance,
not model-capture claims. D045 construction arithmetic is reused unchanged;
its accepted modes/guards/schema-1 fixtures are neither rewritten nor rerun.

Qwen2 has a pure mathematical MLP-site reference only. These files do not prove
Qwen2 graph classification, CPU/Metal callback editing, shared/staged backend
buffers, microbatch scheduling, final-row pruning, model quality, native memory
bounds, cancellation/reset/close or performance. Those require the separately
authorized product gates. The new goldens must be committed separately from
that implementation by the owner, following `golden-update`.
