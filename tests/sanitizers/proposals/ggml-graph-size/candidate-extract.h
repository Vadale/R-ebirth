size_t ggml_hash_size(size_t min_sz) {
    // next primes after powers of two
    static const size_t primes[] = {
        2, 3, 5, 11, 17, 37, 67, 131, 257, 521, 1031,
        2053, 4099, 8209, 16411, 32771, 65537, 131101,
        262147, 524309, 1048583, 2097169, 4194319, 8388617,
        16777259, 33554467, 67108879, 134217757, 268435459,
        536870923, 1073741827, 2147483659
    };
    static const size_t n_primes = sizeof(primes)/sizeof(primes[0]);

    // find the smallest prime that is larger or equal than min_sz
    size_t l = 0;
    size_t r = n_primes;
    while (l < r) {
        size_t m = (l + r)/2;
        if (primes[m] < min_sz) {
            l = m + 1;
        } else {
            r = m;
        }
    }
    size_t sz = l < n_primes ? primes[l] : min_sz | 1;
    return sz;
}

static void * incr_ptr_aligned(void ** p, size_t size, size_t align) {
    void * ptr = *p;
    ptr = (void *) GGML_PAD((uintptr_t) ptr, align);
    *p = (void *) ((char *) ptr + size);
    return ptr;
}

static size_t ggml_graph_nbytes(size_t size, bool grads) {
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
