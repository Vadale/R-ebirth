/* D-039: actual source extracts, independent layout oracle, no engine linkage. */
#include "ggml-impl.h"
#include <stdio.h>
#include <stdlib.h>
#include "source-extract.h"

static void check(size_t size, bool grads) {
    size_t hash_size = ggml_hash_size(size * 2);
    size_t lengths[] = {
        size * sizeof(struct ggml_tensor *), size * sizeof(struct ggml_tensor *),
        hash_size * sizeof(int32_t), hash_size * sizeof(struct ggml_tensor *),
        grads ? hash_size * sizeof(struct ggml_tensor *) : 0,
        grads ? hash_size * sizeof(struct ggml_tensor *) : 0,
        ggml_bitset_size(hash_size) * sizeof(ggml_bitset_t),
    };
    size_t aligns[] = {
        sizeof(struct ggml_tensor *), sizeof(struct ggml_tensor *), sizeof(int32_t),
        sizeof(struct ggml_tensor *), sizeof(struct ggml_tensor *),
        sizeof(struct ggml_tensor *), sizeof(ggml_bitset_t),
    };
    /* Independent alignment oracle uses remainder/division, not GGML_PAD. */
    size_t offsets[7];
    size_t expected = sizeof(struct ggml_cgraph);
    for (size_t i = 0; i < 7; ++i) {
        if (!grads && (i == 4 || i == 5)) continue;
        expected += (aligns[i] - expected % aligns[i]) % aligns[i];
        offsets[i] = expected;
        expected += lengths[i];
    }
    const size_t actual = ggml_graph_nbytes(size, grads);
    assert(actual == expected);
    /* An exact-sized real allocation is the other oracle: unchanged pointer
       arithmetic must give the same field offsets and final byte count. */
    unsigned char * buffer = malloc(actual);
    assert(buffer != NULL);
    assert((uintptr_t)buffer % GGML_MEM_ALIGN == 0);
    struct ggml_cgraph * graph = (struct ggml_cgraph *)buffer;
    void * cursor = graph + 1;
    for (size_t i = 0; i < 7; ++i) {
        if (!grads && (i == 4 || i == 5)) continue;
        unsigned char * field = incr_ptr_aligned(&cursor, lengths[i], aligns[i]);
        assert((size_t)(field - buffer) == offsets[i]);
        assert((uintptr_t)field % aligns[i] == 0);
        if (lengths[i]) {
            field[0] = (unsigned char)i;
            field[lengths[i] - 1] = (unsigned char)(i + 1);
        }
    }
    assert((size_t)((unsigned char *)cursor - buffer) == actual);
    free(buffer);
    printf("LAYOUT_CASE size=%zu grads=%d\n", size, grads);
}

int main(int argc, char ** argv) {
    if (argc == 2 && strcmp(argv[1], "--negative") == 0) {
        void * cursor = NULL;
        incr_ptr_aligned(&cursor, sizeof(struct ggml_cgraph), 1);
        puts("UNEXPECTED_NULL_ARITHMETIC_SURVIVED");
        return 0;
    }
    assert(argc == 1);
    const size_t sizes[] = {0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 32, 33,
        63, 64, 65, 127, 128, 129, 255, 256, 257, 511, 512, 513, 1023, 1024,
        1025, 4095, 4096, 4097, 65535, 65536};
    for (size_t i = 0; i < sizeof(sizes)/sizeof(sizes[0]); ++i) {
        check(sizes[i], false);
        check(sizes[i], true);
    }
    printf("PASS: 68 layout cases; header=%zu pointer=%zu bitset=%zu; zero and boundary sizes; both gradient modes\n",
           sizeof(struct ggml_cgraph), sizeof(struct ggml_tensor *), sizeof(ggml_bitset_t));
    return 0;
}
