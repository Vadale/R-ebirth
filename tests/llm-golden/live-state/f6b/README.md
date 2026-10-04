# Independent F6b history reference

## Reason recorded before generation

The newly authorized F6b feature changes an existing steering coefficient only
before the next token decode, without replaying earlier tokens. A new fixture is
necessary to make an incorrect replay numerically observable. The existing
two-layer model permits native cvec only on its final block (native block 1),
after its KV projections, so it cannot establish this history boundary.

This directory alone adds a three-layer synthetic model with the existing seed
20260705, width 32, 4 heads and vocabulary size 48. An intervention on native
block 1 now affects block 2 keys and values. No existing model or golden changes,
and no model is downloaded. The parent explicitly authorized this bounded new
fixture for the new feature.

`reference_dynamic_state.py` produces the model and CSV fixtures using the
existing pinned `.golden-venv` (Python 3.13, NumPy 2.5.1, gguf 0.19.0). It reuses
the seeded weight builder with a process-local configuration override and the
existing GGUF writer conventions. It does not edit that builder or invoke its
ordinary output-writing entry point. The generated manifest content-binds the
producer sources, model and artifacts with SHA256.

`incremental_reference.py` performs one pure-NumPy token decode at a time,
appending to explicit per-block K/V arrays while checking prior entries remain
identical. It does not call relm/llama.cpp, consult engine results or recompute
old hidden states. Constant-coefficient runs are checked independently against
the existing full-prefix mathematical forward pass before dynamic generation.

Generation and verification follow `.claude/skills/golden-update/SKILL.md`.
The generated files belong in a separate golden commit from runtime changes.

## Contract and cases

The two cases `dynamic_steer` and `dynamic_both` use native prompt IDs `[1, 7]`
and deliver five greedy source states. Native block 1 receives the existing
alternating `+1.5, -1.5` direction. The submitting coefficient is 1. Replies
after states 1, 2, 3 and 4 respectively set it to 0, -1, 1 and leave it unchanged.
Therefore the state source coefficients are `[1, 0, -1, 1, 1]`. The first reply
affects decoding the sampled first token and first appears in state 2. State 1
still describes prefill with the original coefficient. A reply after the fifth
state has no subsequent state to affect.

`dynamic_both` additionally forces native block 1 neuron 2 to 0.25 after
steering. That coordinate must equal 0.25 under every coefficient, including
zero, proving ablation precedence on the steered block.

The CSV schema matches the F6a directory: indices and positions in CSV are
1-based; explicitly named `*_native` lists in the manifest are 0-based.
`states.csv` has 10 rows, `activations.csv` 2,880 scalar values (3 blocks ×
3 components × 32 neurons per state), `logits.csv` 480 rows and `top.csv` 50.
The full-vocabulary logits/probabilities accompany top 5 rows. The manifest
describes test commands; it does not define a public R audit schema.

The wrong-replay control holds token IDs fixed while recomputing the entire
prefix with the newest coefficient. Its disagreement with the proper cache
after zero-removal, sign change and restoration is the decisive history guard.
Holding token IDs fixed isolates history corruption from greedy cascades. The
manifest records both logit disagreement and block 3 key disagreement. A
second no-op control keeps the original coefficient throughout; it must differ
after the requested zero-removal. Restoring the initial coefficient does not
restore prior KV entries.

## Commands and ownership

From the repository root:

```sh
.golden-venv/bin/python tests/llm-golden/live-state/f6b/reference_dynamic_state.py
.golden-venv/bin/python tests/llm-golden/live-state/f6b/reference_dynamic_state.py --check
```

`--check` is read-only for the repository. It reconstructs the model inside an
automatically removed temporary directory and requires byte equality, checks
all GGUF tensors against seeded weights, verifies the manifest's source/model/
artifact digests, recomputes every CSV value and repeats the computation for
same-machine byte determinism. Constant-coefficient incremental/full-prefix
agreement uses 1e-12; committed float64 fixtures use the established synthetic
oracle tolerance (`atol=1e-8`, `rtol=1e-6`). The static cross-check is performed
for 6 tokens, 3 coefficients and both ablation modes. The engine comparison
retains the existing F32-versus-float64 activation/logit tolerance of 1e-2.

Run the read-only producer check in the golden-tooling CI leg. The intended
native consumer is the download-free `cargo test -p rebirth-llm` CPU leg. No
native comparison is claimed by the producer's own self-check. This fixture
does not validate callback acknowledgement, sampler randomness, lifecycle
restoration of the real handle, spill, R payload types, chat offsets, or Metal;
those require their separate runtime gates. It uses ordinary multi-head
attention and full-width RoPE, as does the existing synthetic model.
