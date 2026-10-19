#ifndef TEST_WINDOWS_H
#define TEST_WINDOWS_H
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#if _WIN32_WINNT >= 0x0602
#define RELM_TEST_SDK_TARGET_READY 1
#else
#define RELM_TEST_SDK_TARGET_READY 0
#endif
typedef unsigned int ULONG;
#endif
