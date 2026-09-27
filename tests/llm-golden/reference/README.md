# Unpatched text-logit comparator — deferred

This directory reserves the planned comparison of relm's text logits against an
unpatched llama.cpp build at the same vendored tag, using identical model bytes
and inputs. That comparator is not implemented or wired into CI yet.

The active references live elsewhere:

- `../synthetic/`: independent numpy oracle for synthetic-model numerical paths,
  checked on every commit without downloads.
- `../qwen/`: independent HF fp32 activation reference and pinned tooling,
  exercised by the model-tolerance nightly (D-018's scale-robust checks).
- `../vision/`: upstream vision artifacts and same-runner reference tools. This
  is a separate gate; it does not supply the deferred text-logit comparison.

The future comparator should use the pinned, checksummed small CI model and
record engine provenance, model hash, token IDs, backend, and numerical criteria.
It must not require a large-model download in per-commit tests. See
`../../../docs/validation-status.md` for the acceptance ledger.
