#include "ggml.h"
#include <windows.h>
#include <stddef.h>
#include <stdio.h>
_Static_assert(_WIN32_WINNT == 0x0602, "preserve ggml Windows API target");
#ifndef RELM_REAL_WINDOWS
_Static_assert(RELM_TEST_SDK_TARGET_READY == 1, "SDK read before ggml target selection");
#endif
_Static_assert(sizeof(ULONG) == 4, "Windows ULONG ABI");
_Static_assert(sizeof(THREAD_POWER_THROTTLING_STATE) == 12, "thread state ABI");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, Version) == 0, "version offset");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, ControlMask) == 4, "control offset");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, StateMask) == 8, "state offset");
_Static_assert(THREAD_POWER_THROTTLING_CURRENT_VERSION == 7, "preserve header version");
_Static_assert(THREAD_POWER_THROTTLING_EXECUTION_SPEED == 32, "preserve header flag");
int unaffected(void);
int main(void) {
    THREAD_POWER_THROTTLING_STATE t = {THREAD_POWER_THROTTLING_CURRENT_VERSION,
        THREAD_POWER_THROTTLING_EXECUTION_SPEED, 0};
#ifdef RELM_REAL_WINDOWS
    BOOL (WINAPI *volatile function)(HANDLE, THREAD_INFORMATION_CLASS, LPVOID, DWORD) = SetThreadInformation;
    if (function == NULL) return 2; /* retain API symbol without calling it */
#endif
    if (t.Version != 7 || t.ControlMask != 32 || t.StateMask != 0 || unaffected()) return 1;
    puts("RELM_THREAD_COMPAT_OK existing-declarations size=12 offsets=0,4,8 version=7 mask=32 winnt=0x0602");
    return 0;
}
