#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* Link the unchanged official Windows R entry point to an observing CMD target.
   No Win32 API, R interpreter, engine or model is implemented by this stub. */
int rcmdfn(int cmdarg, int argc, char **argv) {
    if (cmdarg < 1 || cmdarg >= argc) return 21;
    const char *value = getenv("_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_");
    printf("command=%s inherited_skip=%s\n", argv[cmdarg], value ? value : "<unset>");
    if (strcmp(argv[cmdarg], "fail") == 0) return 17;
    return !value || strcmp(value, "FALSE") != 0 ? 19 : 0;
}
