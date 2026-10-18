# Rtools thread declarations (2026-10-18)

Windows job117751709897, run39153465878, head965ba4b79f81ba471ad736e047f7fae17b3d24f3
remains FAILED. The full610661-byte raw log and job metadata are retained.

## Actual progress and new failure

All seven build-path/link controls passed on the real Windows host. CMake now
receives an ordinary source path without the verbatim prefix. MSYS Makefiles
compiled vendor-hash and ggml-base; the earlier prerequisite-parsing failure and
CMake object-path warnings did not recur. This closes those observed build-path
failures in this run, not whole Windows/package acceptance or final link proof.

Compilation then failed in ggml-cpu.c:2605 because the installed Rtools MinGW
headers lack THREAD_POWER_THROTTLING_STATE and its VERSION/EXECUTION_SPEED
constants. The function SetThreadInformation and the ThreadPowerThrottling enum
were not missing. The package did not reach model execution or tests. CMake/GNU
compilation failed before the new GNU library plan could be validated at link.

## Bounded compatibility layer

Microsoft specifies the structure as three ULONG fields. The current MinGW
header defines version1 and execution-speed0x1. The relm-owned compatibility
header supplies these declarations only on MinGW when the version macro is
absent. A present SDK definition wins. It preserves the existing upstream
SetThreadInformation call, state masks, priority handling and numerical code.

A Windows-only CMAKE_PROJECT_INCLUDE hook defers a source property until the
engine target exists. Only ggml-cpu.c receives the forced include; all other C
sources, C++ sources and the native boundary retain their original options.
The hook uses CMake APIs below the already-declared3.28 minimum. No suppression,
SDK/compiler update, copied system header, kernel patch or dependency change.
Both shipped source archives and Cargo.lock remain byte-identical to965ba4b.

## Targeted controls and limits

On Linux, a tiny two-source CMake fixture (explicitly a mocked SDK, not Windows)
reproduced the missing-type refusal without the adapter, then compiled/linked
and ran with the adapter. A second fixture supplies existing declarations with
sentinel constants7/32 and proves they remain untouched. Both assert the Windows
12-byte ABI and offsets0/4/8; an unrelated translation unit fails if the adapter
leaks into it. Paths contain spaces. A separate non-Windows compile/run proves
the header has no platform effect. Positive compiles deny warnings; the expected
negative compile errors are preserved. No native engine build or model calls.

The Windows CI preflight uses the actual Rtools GCC/SDK, verifies ABI/constants,
and takes the typed address of the existing API to check linking without calling
it or changing scheduling policy. Actual SDK and complete package results remain
pending the new automatic matrix; local fixture success is not Windows proof.
The seven previous Rust controls are unchanged and were not rerun locally.
Formatting, Python syntax, workflow YAML and protected source hashes passed.

Original failure statuses remain failed. Small compiled fixture executables and
CMake output stay local; raw log, generated fixture sources and receipts here
allow inspection without inference replay. No Phase8 or consumed holdout replay.

## Primary references checked

- https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-thread_power_throttling_state
- https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadinformation
- https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-headers/include/processthreadsapi.h
