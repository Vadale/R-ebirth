"""Prepare a proposal outside the checkout; do not apply it to the vendor tree."""
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
OUT = Path('/private/tmp/relm-maintenance/ggml-size-diagnosis')
source_path = ROOT / 'rebirth/src/llama.cpp/ggml/src/ggml.c'
source = source_path.read_text()
start = source.index('static size_t ggml_graph_nbytes(')
end = source.index('\nsize_t ggml_graph_overhead_custom', start)
old = source[start:end]
new = '''static size_t ggml_graph_nbytes(size_t size, bool grads) {
    size_t hash_size = ggml_hash_size(size * 2);
    // Size-only calculation: there is no backing allocation for pointer arithmetic.
    size_t nbytes = sizeof(struct ggml_cgraph);
    nbytes = GGML_PAD(nbytes, sizeof(struct ggml_tensor *)) + size * sizeof(struct ggml_tensor *); // nodes
    nbytes = GGML_PAD(nbytes, sizeof(struct ggml_tensor *)) + size * sizeof(struct ggml_tensor *); // leafs
    nbytes = GGML_PAD(nbytes, sizeof(int32_t)) + hash_size * sizeof(int32_t); // use_counts
    nbytes = GGML_PAD(nbytes, sizeof(struct ggml_tensor *)) + hash_size * sizeof(struct ggml_tensor *); // hash keys
    if (grads) {
        nbytes = GGML_PAD(nbytes, sizeof(struct ggml_tensor *)) + hash_size * sizeof(struct ggml_tensor *); // grads
        nbytes = GGML_PAD(nbytes, sizeof(struct ggml_tensor *)) + hash_size * sizeof(struct ggml_tensor *); // grad_accs
    }
    nbytes = GGML_PAD(nbytes, sizeof(ggml_bitset_t)) + ggml_bitset_size(hash_size) * sizeof(ggml_bitset_t);

    return nbytes;
}
'''
proposed = source[:start] + new + source[end:]
label = 'rebirth/src/llama.cpp/ggml/src/ggml.c'
patch = ''.join(difflib.unified_diff(source.splitlines(keepends=True), proposed.splitlines(keepends=True),
                                 fromfile='a/' + label, tofile='b/' + label))
patch_path = OUT.parent / 'ggml-size-proposal.patch'
patch_path.write_text(patch)
(OUT / 'ggml.c.proposed').write_text(proposed)

helper_start = source.index('static void * incr_ptr_aligned(')
helper = source[helper_start:start]
hash_start = source.index('size_t ggml_hash_size(')
hash_end = source.index('\nstruct hash_map {', hash_start)
# Compile only the small affected calculation/helper/hash selector, not the engine.
(OUT / 'candidate-extract.h').write_text(source[hash_start:hash_end] + '\n' + helper + new)
(OUT / 'original-extract.h').write_text(helper + old)
manifest = {
    'source_file': str(source_path),
    'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'proposed_source_sha256': hashlib.sha256(proposed.encode()).hexdigest(),
    'proposal_patch_sha256': hashlib.sha256(patch.encode()).hexdigest(),
    'changed_function': 'ggml_graph_nbytes',
    'unchanged_functions': ['incr_ptr_aligned', 'ggml_new_graph_custom', 'ggml_graph_overhead_custom', 'ggml_hash_size'],
}
(OUT / 'proposal-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
