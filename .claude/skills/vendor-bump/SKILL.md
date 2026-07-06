---
name: vendor-bump
description: Update the vendored llama.cpp to a newer pinned tag and re-apply the activation-tap patch. Run quarterly, or sooner if a needed feature/model architecture (e.g. a new MedGemma) requires it. High-risk maintenance - follow exactly.
---

# Vendored llama.cpp bump

The tap patch is the project's most fragile asset (risk #1 in `ROADMAP.md` §6). This procedure keeps bumps boring.

1. **Pick the target tag** (a llama.cpp release tag, never a random commit). Record: old tag, new tag, reason for the bump (quarterly cadence / needed feature / model support).
2. **Read upstream changes** touching our patch points (the files listed in `vendor/README` under "tap patch surface") and the GGUF/model-arch code for the pinned model families (Qwen, Gemma/MedGemma, Llama). Note anything that moved.
3. **Branch:** `git checkout -b vendor-bump-<newtag>`.
4. **Update `vendor/`** to the new tag; record tag + SHA256 in `vendor/README`.
5. **Re-apply the patch set** from `rebirth/src/llama.cpp/patches/` (DECISIONS.md D-015: the tree is committed WITH the patches applied — `build.rs` compiles it as-is; there is no build-time patch step). Apply each `*.diff` to the fresh upstream checkout (`git apply patches/<name>.diff` from `rebirth/src/llama.cpp/`). If a hunk fails, port it by hand *minimally* — the patch stays as small as upstream allows — and **regenerate the diff** (`git diff --relative`) so the committed tree and the diff never diverge.
   - After re-applying, **re-record all three `VENDORING.md` SHAs** (upstream tarball, pre-patch tree, post-patch tree) and run `sh rebirth/src/llama.cpp/patches/verify_vendored_tree.sh`, which asserts the committed tree hashes to the post-patch SHA (gate G4) and that the diffs reverse-apply to the pre-patch SHA (coherence check, D-015). This must pass before proceeding.
6. **Rebuild the unpatched reference build** at the same new tag (harness B compares against the same-version reference, never across versions).
7. **Full verification, in order:** `verify_vendored_tree.sh` (G4 + patch coherence, step 5) → `cargo test` → harness B on the synthetic model (must be exact; the un-intervened goldens must stay byte-identical after re-applying the patch) → harness B nightly suite on the CI model → the two demos on the founder's Mac. Any golden movement goes through the `golden-update` skill with reason = this bump.
8. **Overhead check:** tap-off generation overhead still < 2% (Phase 2 acceptance holds permanently).
9. **Document:** `DECISIONS.md` entry (bump = a decision): tags, why, what moved, golden impact. `NEWS.md` if user-visible (new model architectures supported).
10. **One PR, reviewed by `reviewer` + `security-auditor`** (vendored parsing code changed = audit trigger).
