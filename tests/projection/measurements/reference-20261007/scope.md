# Independent F6e reference acceptance

New-feature reason and references were frozen before product arithmetic in
commit d8a4800. The producer write and read-only check passed191 controls using
Python3.13.5/NumPy2.5.1/gguf0.19.0. The owner checked all49 source/fixture files
(1,859,807bytes), both command-log digests, positive per-table counts and191
unique passed controls. Existing tracked goldens/model/runtime/workflows had
no diff; the three-layer model hash was checked again without inference.

The producer marker names the manifest.csv digest78729e5f; the native plan's
observed digestab9e0361 names manifest.json. Both exact files are independently
verified in reference-owner-verification.json. This was a filename distinction,
not drift or a failed producer. Neither receipt is relabelled.

These are arithmetic/encoding/independent model mathematics only. No actual
engine/CPU/Metal/R execution or native memory acceptance occurred. Qwen2 is a
pure site equation, not a full-model numerical oracle. Same-input-row arithmetic
uses abs+rel2e-6; whole-forward model comparisons retain existing abs0.01.
Native placement, every-row scheduling, lifecycle, bounds and performance remain
unexecuted gates. No earlier accepted suite was rerun.
