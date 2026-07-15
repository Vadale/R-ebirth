---
name: golden-update
description: Regenerate reference goldens (logits/activations) safely. The ONLY sanctioned way to create or modify files in tests/llm-golden/. Use when adding a numerical feature or when a justified upstream change shifts reference values.
---

# Regenerating goldens

Goldens are the project's trust anchor. A golden changed without a documented reason is corruption of the trust layer, even if all tests pass afterwards.

1. **State the reason first**, in writing, before regenerating. Valid reasons: new feature needs new goldens; vendored llama.cpp bump changed sampling/kernel order (link the `vendor-bump` run); a golden-generation script bug (explain the bug). Invalid reason: "tests fail and regenerating makes them pass" — that is a defect to investigate, not a golden to refresh.
2. **Use only the pinned scripts** in `tests/llm-golden/` with the pinned Python venv (torch/transformers versions recorded in the lockfile there). Never hand-edit a golden file.
3. **Regenerate the minimum set** — only the goldens affected by the stated reason. A full regeneration requires founder approval.
4. **Regenerate the `.machine` sidecar WITH the golden it belongs to.** Some goldens are bit-exact only on the machine that recorded them (today: `tests/llm-golden/vision/goldens/embed-red-square-mean.csv`, whose pin is gated on a derived machine fingerprint — D-026 fifth addendum). Each such golden carries `<name>.machine` holding `machine:` (the recording machine, from `helper-llm.R::machine_fingerprint()`) and `golden-md5:` (that golden's digest). **Re-recording the golden without rewriting the sidecar is a defect**, not an oversight: the pin would stay gated on the machine that no longer recorded it, and would skip everywhere — silently — forever. The digest turns that into a loud per-commit failure; do not "fix" such a failure by deleting the check.
   ```sh
   Rscript -e 'source("rebirth/tests/testthat/helper-llm.R"); cat(machine_fingerprint())'
   Rscript -e 'cat(unname(tools::md5sum("<path/to/golden>")))'
   ```
5. **Diff review:** inspect the numeric diff (max abs delta, which layers/positions moved). Deltas must be explainable by the stated reason. Unexplained movement → stop, investigate, report.
6. **Cross-check:** after regeneration, harness B must pass on the synthetic in-repo model (exact) and on the unpatched-llama.cpp legs (exact). Against the **HF fp32** reference the bar is Spearman/cosine ≈ 0.94, anchored by the exact residual-decomposition identity (Δ = 0) + top-k logit agreement — **not** rank-correlation ≥ 0.999/layer. **D-018 established that 0.999 is not achievable** against an independent HF reference: the divergence is intrinsic to llama.cpp-vs-PyTorch, not quantization or backend. Do not resurrect that figure — it is the criterion D-018 corrected, and it survived here after the ROADMAP's copy was fixed.
7. **Commit hygiene:** goldens in their own commit, message = the stated reason + script + versions used. Add a line to `DECISIONS.md` only if the reason was an upstream behavioral change (those are decisions); routine new-feature goldens just need the commit message.
8. **Never** merge a golden regeneration in the same commit as the code change it validates — reviewer must be able to see them separately.
