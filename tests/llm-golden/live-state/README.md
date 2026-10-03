# Independent live-state reference

## Reason and provenance recorded before generation

F6a is a new numerical feature approved under D-041. These new fixtures pin the
source state that selects a token, including post-intervention residuals, raw
logits, full-vocabulary probabilities and the public position convention. They
are not regenerated to reconcile an engine failure. No existing model, synthetic
golden or metadata file is regenerated or edited.

The producer is `reference_live_state.py` in this directory. It imports the
existing pure-NumPy `synthetic/reference_forward.py` and seeded
`synthetic/synthetic_model.py` (seed 20260705), never relm or llama.cpp output.
Before writing or checking, it compares every committed GGUF tensor to the
seeded F32 weights and checks the canonical/package GGUF copies byte-for-byte.
The generated manifest records SHA256 for both copies, all producer sources,
the requirements file and every new CSV artifact.

Use the existing `.golden-venv` with Python 3.13 (recording interpreter 3.13.5),
NumPy 2.5.1 and gguf 0.19.0, as pinned in `../requirements.txt`. Computation is
float64 over the existing F32 weights. This is independent of the native engine;
there is no model download, native build or new dependency.

Regeneration is governed by `.claude/skills/golden-update/SKILL.md`. Keep these
fixtures in a separate commit from the runtime change they validate.

## Cases and schema

`goldens/manifest.json` specifies five cases: `baseline`, `steer`, `ablate` and
`both` each generate four states from native prompt IDs `[1, 7]`; `long_prefill`
generates two states from 513 prompt tokens. The latter exercises final-row
selection across a native `n_batch = 512` boundary with a sufficiently large
context. All cases capture both layers and all three components. `both` includes
steering and ablation on the same coordinate so ablation precedence is visible.
Exact directions, forced values, prompt IDs and greedy IDs are in the manifest.

| Artifact | Rows | Columns |
|---|---:|---|
| `states.csv` | 18 | `case,state_id,token_pos,token_id,context_pos,source_pos,source,source_token_id,prompt_token_count` |
| `activations.csv` | 3,456 | `case,state_id,layer,component,neuron,value` |
| `logits.csv` | 864 | `case,state_id,token_id,logit,prob` |
| `top.csv` | 90 | `case,state_id,rank,token_id,logit,prob` |

CSV IDs, positions, layers and neurons are 1-based. Explicit `*_native` fields
in the manifest use 0-based native indices. For a prompt of length `P`, state
`k` captures source position `P + k - 1`, selects generated token `k`, and records
its prospective context position `P + k`. It uses the final row of the prefix
before that sampled token is appended. The first source is `prompt`; later
sources are `generated`. Activation components are `attn_out` after projection,
`mlp_out` before residual addition, and `residual` after steering then ablation.

`logits.csv` holds all 48 raw pre-sampling logits and probabilities. `top.csv`
selects five rows by descending logit and ascending token ID on exact ties.
Probabilities are the full-vocabulary softmax at temperature 1, without
renormalizing the selected rows. These numerical fixtures do not supply token
display strings, elapsed times or the entire public R payload schema.

## Reproduction and tolerances

From the repository root, regenerate only this new fixture set or check it:

```sh
.golden-venv/bin/python tests/llm-golden/live-state/reference_live_state.py
.golden-venv/bin/python tests/llm-golden/live-state/reference_live_state.py --check
```

`--check` writes no files. It verifies model/source/artifact bytes, recomputes all
CSV values, requires exact keys and greedy IDs, and repeats computation for
same-machine byte determinism. Cross-machine float64 comparisons reuse the
existing synthetic oracle tolerance (`atol = 1e-8`, `rtol = 1e-6`). Native F32
activation/logit comparisons retain the existing absolute tolerance `1e-2`;
no live-state tolerance was introduced.

The minimum greedy top-two margin is 0.03054. Some lower top-five ranks differ
by only 0.000631, so exact top-five ordering is not asserted as a universal
cross-backend property: validate native rank/tie ordering against its own raw
logits and compare numerical values against this independent reference.

Controls reject corrupted source positions, token IDs, activation values and
probabilities; separate checks cover exact ties, full-softmax mass and empty
top selection. Every preceding-row substitution changes at least one captured
activation by more than 0.98. First-state intervention logit effects exceed
0.74, guarding against ignored interventions. Forced residual coordinates and
unchanged same-block component taps establish post-intervention capture.

The intended automated owners are the golden-tooling Python CI leg for
`--check` and the download-free `cargo test -p rebirth-llm` CPU leg for native
comparisons. This document does not claim that adding the fixtures alone wires
either gate into CI.

## Validation scope and limits

The producer's read-only self-check passed. Separately, the coordinating native
task reported four passing local debug synthetic tests against these 18 states:
3,840 activation-value comparisons including repeated 513-token-prefill coverage,
maximum activation difference 0.0034464 and maximum logit difference 0.0041723.
These are scoped numerical results, not whole-attempt acceptance.

The first broader attempt failed its active-observation performance gate in a
debug build. Its attempt-wide source-drift check also remains failed: that
manifest captured the draft `reference_dynamic_state.py` and
`incremental_reference.py` in this directory before their relocation into
`f6b/`. Neither draft path was a dependency in the F6a golden manifest; all six
F6a model/source dependencies and four CSV artifact digests remain separate.
This dependency distinction does not turn the attempt-wide drift result green.

These fixtures do not validate seeded stochastic sampling, EOG/stop handling,
chat/tokenizer offsets, R callback ordering, cancellation, spill, memory limits,
or backend performance. Such runtime gates remain separate. F6b has its own
[history-preserving reference](f6b/README.md) and three-layer fixture; no F6b
runtime acceptance is recorded here. Static two-layer prefix recomputation alone
cannot prove that changing coefficients preserves prior KV history.
