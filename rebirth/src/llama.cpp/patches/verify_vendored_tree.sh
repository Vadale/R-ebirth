#!/usr/bin/env sh
# Verify the vendored, patched llama.cpp tree (DECISIONS.md D-008 gate G4 + D-015).
#
#   1) G4 — recompute the pruned-tree SHA256 and assert it matches VENDORING.md's
#      "post-patch" row (catches a SILENT change to the committed engine; a
#      deliberate patch that updates VENDORING.md is not silent).
#   2) Patch coherence (D-015) — reverse-apply patches/*.diff to a copy of the
#      tree, recompute the digest, and assert it matches the "pre-patch" row
#      (catches the committed tree and the patch diff silently diverging).
#
# Uses the exact digest command documented in VENDORING.md (shasum -a 256, which
# is present on macOS and on the CI ubuntu runners). Run from anywhere; it
# resolves its own location. Exits non-zero on any mismatch.
set -eu

# POSIX sh has no `pipefail`; enable it where the running shell supports it (bash,
# ksh, zsh, busybox ash) so a failure mid-pipe (e.g. shasum on an unreadable file)
# is not masked by a succeeding tail stage. Harmless where unsupported — digest()
# below is also robust on its own via explicit status capture (F-5).
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

# rebirth/src/llama.cpp — one dir up from this script's patches/ dir.
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vend="$here/VENDORING.md"

# The documented pruned-tree digest of $1, excluding VENDORING.md and patches/.
# Fail-closed (F-5): materialize the sorted file list, then capture the per-file
# `xargs shasum` status EXPLICITLY (POSIX sh has no pipefail) so an unreadable file
# fails the function instead of being masked by the succeeding reduce/`cut`.
digest() {
    (
        cd "$1" || exit 1
        list=$(find . -type f -not -path './VENDORING.md' -not -path './patches/*' \
            | LC_ALL=C sort)
        manifest=$(printf '%s\n' "$list" | xargs shasum -a 256) || exit 1
        printf '%s\n' "$manifest" | shasum -a 256 | cut -d' ' -f1
    )
}

# The 64-hex SHA on the VENDORING.md table row containing $1.
sha_row() {
    grep -F "$1" "$vend" | grep -oE '[0-9a-f]{64}' | head -n1
}

pre_expected=$(sha_row "Pruned tree SHA256 (pre-patch)")
post_expected=$(sha_row "Pruned tree SHA256 (post-patch)")
if [ -z "$pre_expected" ] || [ -z "$post_expected" ]; then
    echo "FAIL: could not read the pre/post-patch SHA rows from $vend" >&2
    exit 1
fi

# 1) G4 — the committed tree hashes to the documented post-patch SHA.
post_actual=$(digest "$here")
if [ "$post_actual" != "$post_expected" ]; then
    echo "FAIL (G4): vendored tree SHA256" >&2
    echo "  computed:  $post_actual" >&2
    echo "  VENDORING: $post_expected (post-patch)" >&2
    echo "A change to src/llama.cpp/ must update VENDORING.md's post-patch row (and, if" >&2
    echo "it is a new patch, land the diff in patches/ and re-record both SHAs)." >&2
    exit 1
fi
echo "OK (G4): vendored pruned tree matches VENDORING.md post-patch SHA256"

# 2) Patch coherence — reverse-applying patches/*.diff yields the pre-patch tree.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R "$here/." "$tmp/"
# Capture the reverse-apply subshell status EXPLICITLY (F-5): under `set -e` a bare
# `git apply -R` failure would abort with no diagnostic, so wrap it in `if !` (which
# `set -e` does not trip) and emit the intended coherence message. Fail-closed.
if ! (
    cd "$tmp"
    for p in patches/*.diff; do
        [ -e "$p" ] || continue
        git apply -R -p1 "$p"
    done
); then
    echo "FAIL (coherence): patches/*.diff did not reverse-apply cleanly to the committed tree" >&2
    echo "The committed tree and patches/*.diff have diverged; re-generate the diff." >&2
    exit 1
fi
pre_actual=$(digest "$tmp")
if [ "$pre_actual" != "$pre_expected" ]; then
    echo "FAIL (coherence): reverse-applying patches/*.diff does not restore the pre-patch tree" >&2
    echo "  computed:  $pre_actual" >&2
    echo "  VENDORING: $pre_expected (pre-patch)" >&2
    echo "The committed tree and patches/*.diff have diverged; re-generate the diff." >&2
    exit 1
fi
echo "OK (coherence): patches/*.diff reverse-apply to the VENDORING.md pre-patch SHA256"
