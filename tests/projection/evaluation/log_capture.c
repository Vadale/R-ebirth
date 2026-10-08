/* Test-process-only logging adapter. No model access or product-code changes.
 * Invoke after relm's one-time quiet logger initialization, before model load.
 * The official callback runs on native threads and never calls R. */
#include "llama.h"
#include <dlfcn.h>
#include <stdio.h>

static FILE *capture;
static void *library;
static void (*set_log)(ggml_log_callback, void *);

static void record_log(enum ggml_log_level level, const char *text, void *data) {
    (void)data;
    if (text == NULL) return;
    if (capture != NULL) {
        flockfile(capture);
        fprintf(capture, "[%d] %s", (int)level, text);
        fflush(capture);
        funlockfile(capture);
    }
    if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR) {
        fputs(text, stderr);
        fflush(stderr);
    }
}

void f6e_log_start(char **dll, char **path, int *status) {
    *status = 1;
    if (library != NULL || capture != NULL) return;
    library = dlopen(*dll, RTLD_NOW | RTLD_NOLOAD);
    if (library == NULL) return;
    set_log = (void (*)(ggml_log_callback, void *))dlsym(library, "llama_log_set");
    if (set_log == NULL) { dlclose(library); library = NULL; return; }
    capture = fopen(*path, "wx");
    if (capture == NULL) { dlclose(library); library = NULL; return; }
    set_log(record_log, NULL);
    *status = 0;
}

/* Call only after all model owners and workers have been closed/joined. */
void f6e_log_stop(int *status) {
    *status = 1;
    if (library == NULL || capture == NULL) return;
    set_log(NULL, NULL);
    int result = fclose(capture);
    capture = NULL;
    dlclose(library);
    library = NULL;
    set_log = NULL;
    *status = result == 0 ? 0 : 1;
}
