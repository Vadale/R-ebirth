# patches/

Provenance diffs for the vendored llama.cpp (DECISIONS.md D-006, D-012, D-015;
ARCHITECTURE.md §5). **The patches are applied to the committed `src/llama.cpp/`
tree** (D-015) — `build.rs` compiles the tree as-is, with no build-time patch
step and no diff-applier dependency (CRAN/`R CMD INSTALL`-robust). Each `*.diff`
here is the human-readable delta of the committed tree against pristine upstream
`b9726`, kept so the quarterly `vendor-bump` skill stays mechanical.

Paths in each diff are relative to `rebirth/src/llama.cpp/` (`git diff
--relative`), so from this directory's parent:

```sh
git apply    patches/<name>.diff   # re-apply to a fresh upstream checkout
git apply -R patches/<name>.diff   # revert to pristine upstream
```

## Applied patches

| Patch | Files/hunks | ADR |
|---|---|---|
| `0001-rebirth-wp5-ablation-intervene.diff` | 7 files, 14 hunks — `llama_adapter_intervene` at `build_cvec` for `llm_ablate()` | D-012 / D-016 |

Every hunk also carries an inline `rebirth WP5` code comment stating why it
exists. The un-intervened forward pass is byte-identical to the unpatched build
(the `intervene->apply_to` no-op emits no graph node), so the WP2/WP3/WP4
synthetic goldens pass unchanged after the patch.

## Integrity

`verify_vendored_tree.sh` asserts, and CI runs (the `vendored-tree` job):

- **G4 (D-008):** the committed tree hashes to `VENDORING.md`'s post-patch SHA.
- **Coherence (D-015):** reverse-applying `*.diff` reproduces the pre-patch SHA.

`VENDORING.md` records all three SHAs (upstream tarball, pre-patch tree,
post-patch tree). WP4 added zero patches (observation is zero-patch, D-012); this
WP5 ablation hook is the project's first vendored patch.
