/*
 * dump-encode.c — the WP-V4 reference harness for the vision embedding golden
 * (D-026 first addendum, the BINDING embd-ATOL leg).
 *
 * Dumps the raw image-encoder output embeddings (`mtmd_get_output_embd` after
 * `mtmd_encode_chunk`) for one image under one text model + mmproj pair, using
 * ONLY the upstream C API — build it against the PRISTINE upstream llama.cpp
 * at the pinned tag b9726 (tarball SHA256 117e95a5...f2e0), never against the
 * vendored tree. Output: line 1 = "<n_tokens> <n_embd>", then one "%.8e" float
 * per line, row-major (token-major). See the README for the exact build and
 * run commands used to produce the committed reference.
 *
 * Usage: dump-encode <text-model.gguf> <mmproj.gguf> <image> <out.txt>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

static unsigned char * read_file(const char * path, size_t * len_out) {
    FILE * f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char * buf = (unsigned char *) malloc((size_t) len);
    if (!buf || fread(buf, 1, (size_t) len, f) != (size_t) len) {
        fprintf(stderr, "cannot read %s\n", path);
        fclose(f);
        free(buf);
        return NULL;
    }
    fclose(f);
    *len_out = (size_t) len;
    return buf;
}

int main(int argc, char ** argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <model.gguf> <mmproj.gguf> <image> <out.txt>\n", argv[0]);
        return 2;
    }
    llama_backend_init();

    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0; /* CPU-only, matching the reference build */
    struct llama_model * model = llama_model_load_from_file(argv[1], mparams);
    if (!model) { fprintf(stderr, "model load failed\n"); return 1; }

    struct mtmd_context_params cparams = mtmd_context_params_default();
    cparams.use_gpu = false;
    cparams.print_timings = false;
    mtmd_context * mctx = mtmd_init_from_file(argv[2], model, cparams);
    if (!mctx) { fprintf(stderr, "mmproj load failed\n"); return 1; }

    size_t len = 0;
    unsigned char * bytes = read_file(argv[3], &len);
    if (!bytes) return 1;
    struct mtmd_helper_bitmap_wrapper wrapper =
        mtmd_helper_bitmap_init_from_buf(mctx, bytes, len, false);
    free(bytes);
    if (!wrapper.bitmap) { fprintf(stderr, "image decode failed\n"); return 1; }

    /* marker-only text: the chunk list is [delimiter text][image][delimiter
     * text]; the encoder output depends only on the bitmap + projector. */
    mtmd_input_text text;
    text.text          = mtmd_default_marker();
    text.add_special   = false;
    text.parse_special = false;
    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    const mtmd_bitmap * bitmaps[1] = { wrapper.bitmap };
    if (mtmd_tokenize(mctx, chunks, &text, bitmaps, 1) != 0) {
        fprintf(stderr, "tokenize failed\n");
        return 1;
    }

    const mtmd_input_chunk * image_chunk = NULL;
    for (size_t i = 0; i < mtmd_input_chunks_size(chunks); i++) {
        const mtmd_input_chunk * c = mtmd_input_chunks_get(chunks, i);
        if (mtmd_input_chunk_get_type(c) == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            image_chunk = c;
            break;
        }
    }
    if (!image_chunk) { fprintf(stderr, "no image chunk produced\n"); return 1; }

    if (mtmd_encode_chunk(mctx, image_chunk) != 0) {
        fprintf(stderr, "encode failed\n");
        return 1;
    }
    const float * embd = mtmd_get_output_embd(mctx);
    if (!embd) { fprintf(stderr, "no encoder output\n"); return 1; }

    size_t n_tokens = mtmd_input_chunk_get_n_tokens(image_chunk);
    int n_embd = llama_model_n_embd_inp(model);

    FILE * out = fopen(argv[4], "w");
    if (!out) { fprintf(stderr, "cannot write %s\n", argv[4]); return 1; }
    fprintf(out, "%zu %d\n", n_tokens, n_embd);
    for (size_t i = 0; i < n_tokens * (size_t) n_embd; i++) {
        fprintf(out, "%.8e\n", embd[i]);
    }
    fclose(out);
    fprintf(stderr, "wrote %zu x %d encoder embeddings to %s\n", n_tokens, n_embd, argv[4]);
    return 0;
}
