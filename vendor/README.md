# vendor/

Home of the vendored, pinned `llama.cpp` (patched for activation taps) together
with its upstream `LICENSE`/`NOTICE`. Populated in **WP1** (static-library
build, Metal on macOS / CPU fallback) and patched in **WP4** (activation taps).

Nothing is vendored yet.

When vendored (WP1), this directory records:

- the exact upstream tag + SHA256 (reproducibility);
- `vendor/patches/` — the activation-tap patch set, each hunk annotated with why
  it exists, kept as small as upstream allows so the `vendor-bump` skill stays
  routine (see `ARCHITECTURE.md` §5 and the roadmap risk register).
