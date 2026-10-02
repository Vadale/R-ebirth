/* Isolated nightly controls only; never compiled into the package or vendor tree.
 * Compile once as C and once as C++, with a distinct PROBE_NAME. */
#include <limits.h>

static __attribute__((noinline)) int read_at(volatile int *values, int index) {
    return values[index];
}

#ifdef __cplusplus
extern "C"
#endif
int PROBE_NAME(int mode) {
    volatile int values[4] = {42, 0, 0, 0};
    if (mode == 1) {
        volatile int index = 4;
        return read_at(values, index); /* Expected ASan stack-buffer-overflow. */
    }
    if (mode == 2) {
        volatile int maximum = INT_MAX;
        return maximum + 1; /* Expected UBSan signed integer overflow. */
    }
    return values[0];
}
