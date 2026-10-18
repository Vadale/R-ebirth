/* Declaration-only compatibility for the older MinGW headers shipped in Rtools.
 * Windows SDK ABI: three ULONG fields; version 1 and execution-speed flag 0x1.
 * https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-thread_power_throttling_state
 * Keep the engine's existing SetThreadInformation call and scheduling policy.
 */
#ifndef RELM_WINDOWS_THREAD_COMPAT_H
#define RELM_WINDOWS_THREAD_COMPAT_H

#if defined(_WIN32) && defined(__MINGW32__)
/* ggml chooses its Windows API target before any system header. Preserve that
 * order (and any caller override) when this adapter is force-included. */
#include "ggml.h"
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#ifndef THREAD_POWER_THROTTLING_CURRENT_VERSION
#define THREAD_POWER_THROTTLING_CURRENT_VERSION 1
#define THREAD_POWER_THROTTLING_EXECUTION_SPEED 0x1
typedef struct _THREAD_POWER_THROTTLING_STATE {
    ULONG Version;
    ULONG ControlMask;
    ULONG StateMask;
} THREAD_POWER_THROTTLING_STATE;
#endif
#endif
#endif
