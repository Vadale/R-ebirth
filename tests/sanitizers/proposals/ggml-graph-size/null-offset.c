/* Standalone reduction of b10828 ggml.c:7365-7375; no ggml/R/Rust linkage. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#define GGML_PAD(x, n) (((x) + (n) - 1) & ~((n) - 1))

static void * incr_ptr_aligned(void ** p, size_t size, size_t align) {
    void * ptr = *p;
    ptr = (void *) GGML_PAD((uintptr_t) ptr, align);
    *p = (void *) ((char *) ptr + size);
    return ptr;
}

int main(void) {
    void * p = NULL;
    incr_ptr_aligned(&p, 96, 1);
    printf("Unexpectedly reached after null-pointer arithmetic: %zu\n", (size_t)p);
    return 0;
}
