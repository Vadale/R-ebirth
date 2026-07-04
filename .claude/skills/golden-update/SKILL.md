---
name: golden-update
description: Regenerate reference goldens (logits/activations) safely. The ONLY sanctioned way to create or modify files in tests/llm-golden/. Use when adding a numerical feature or when a justified upstream change shifts reference values.
---

# Regenerating goldens

Goldens are the project's trust anchor. A golden changed without a documented reason is corruption of the trust layer, even if all tests pass afterwards.

1. **State the reason first**, in writing, before regenerating. Valid reasons: new feature needs new goldens; vendored llama.cpp bump changed sampling/kernel order (link the `vendor-bump` run); a golden-generation script bug (explain the bug). Invalid reason: "tests fail and regenerating makes them pass" — that is a defect to investigate, not a golden to refresh.
2. **Use only the pinned scripts** in `tests/llm-golden/` with the pinned Python venv (torch/transformers versions recorded in the lockfile there). Never hand-edit a golden file.
3. **Regenerate the minimum set** — only the goldens affected by the stated reason. A full regeneration requires founder approval.
4. **Diff review:** inspect the numeric diff (max abs delta, which layers/positions moved). Deltas must be explainable by the stated reason. Unexplained movement → stop, investigate, report.
5. **Cross-check:** after regeneration, harness B must pass on BOTH the synthetic in-repo model (exact) and the CI model (tolerance + rank-correlation ≥ 0.999/layer).
6. **Commit hygiene:** goldens in their own commit, message = the stated reason + script + versions used. Add a line to `DECISIONS.md` only if the reason was an upstream behavioral change (those are decisions); routine new-feature goldens just need the commit message.
7. **Never** merge a golden regeneration in the same commit as the code change it validates — reviewer must be able to see them separately.
