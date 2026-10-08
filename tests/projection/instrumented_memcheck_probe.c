/* Memcheck runner controls only. Never linked into relm or the engine. */
#include <stdlib.h>
#include <string.h>

static void leak(void) {
    volatile unsigned char *p = (volatile unsigned char *) malloc(37);
    if (!p) exit(2);
    p[0] = 7;
    /* Intentional lost allocation: the runner must reject this process. */
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "leak") == 0) { leak(); return 0; }
    volatile unsigned char *p = (volatile unsigned char *) malloc(8);
    if (!p) return 2;
    p[0] = 3;
    free((void *) p);
    if (strcmp(argv[1], "invalid-write") == 0) { p[0] = 4; return 0; }
    return strcmp(argv[1], "safe") == 0 ? 0 : 2;
}
