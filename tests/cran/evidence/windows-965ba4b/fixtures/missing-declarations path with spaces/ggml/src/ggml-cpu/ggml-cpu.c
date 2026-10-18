#include <windows.h>
#include <stddef.h>
#include <stdio.h>
_Static_assert(sizeof(ULONG) == 4, "Windows ULONG ABI");
_Static_assert(sizeof(THREAD_POWER_THROTTLING_STATE) == 12, "thread state ABI");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, Version) == 0, "version offset");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, ControlMask) == 4, "control offset");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, StateMask) == 8, "state offset");
_Static_assert(THREAD_POWER_THROTTLING_CURRENT_VERSION == 1, "preserve header version");
_Static_assert(THREAD_POWER_THROTTLING_EXECUTION_SPEED == 1, "preserve header flag");
int unaffected(void);
int main(void) {
    THREAD_POWER_THROTTLING_STATE t = {THREAD_POWER_THROTTLING_CURRENT_VERSION,
        THREAD_POWER_THROTTLING_EXECUTION_SPEED, 0};
#ifdef RELM_REAL_WINDOWS
    BOOL (WINAPI *function)(HANDLE, THREAD_INFORMATION_CLASS, LPVOID, DWORD) = SetThreadInformation;
    (void) function; /* link/signature only; no scheduling policy change */
#endif
    if (t.Version != 1 || t.ControlMask != 1 || t.StateMask != 0 || unaffected()) return 1;
    puts("RELM_THREAD_COMPAT_OK missing-declarations size=12 offsets=0,4,8 version=1 mask=1");
    return 0;
}
