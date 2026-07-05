# patches/

Activation-tap patch set for the vendored llama.cpp (DECISIONS.md D-006,
ARCHITECTURE.md §5). **Empty in WP1 — zero patches are applied.**

Populated in WP4: each patch is a unified diff against the pinned tag (`b9726`),
applied by `../../rust/rebirth-llm/build.rs` before the cmake build, and every
hunk is annotated with why it exists. The patch set is kept as small as upstream
allows so the quarterly `vendor-bump` skill stays mechanical.
