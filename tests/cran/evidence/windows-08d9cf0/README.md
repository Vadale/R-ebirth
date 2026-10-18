# Windows CPU native build correction (2026-10-18)

The first Windows CPU job on `08d9cf0d3a46408497214a4cd9a93f81027526bb`
failed during the native installation used to build package vignettes. It did
not reach package tests or model execution. The original failure stays failed.
Run 39151591857, job 117746180393; raw log and job metadata are preserved here.
The partial PR snapshot contains eight successful checks, this failure and one
Mac R-release check still running; it is not final matrix acceptance.

## Evidence and correction

CMake configured GNU C/C++ 14.3.0 and generated `MSYS Makefiles`. Make then
refused `ggml-base.dir/build.make:77` and `vendor-hash.dir/build.make:77` with
`target pattern contains no '%'`. The source argument in the actual CMake
command begins with the Windows extended-length prefix `\\?\`. It comes from
our unconditional `Path::canonicalize()`. Rust documents that this Windows
result may be incompatible when passed as an argument to another application.
The correction uses the ordinary absolute-path API on Windows, checking source
directory existence separately. Unix retains canonicalization. The native build
in CI, rather than these Linux controls, must establish actual resolution of
the MSYS parsing failure; the failed generated Makefile was not uploaded.

Three CMake configure warnings also reported a 233-character object directory
against the 250-character object-path limit. On Windows, CMake now uses
`<Cargo profile>/n/<Cargo build-unit hash>` and its boundary sub-build uses `g`.
This removes 20 characters from the engine output prefix and a further 13 from
the boundary sub-build name. Target triple, profile and build-unit hash remain
isolated; all outputs remain within normal owned Cargo/R target cleanup. No
object-path limit or warning is suppressed or raised. Actual Windows results
must confirm the remaining paths fit.

Inspection of the same build script found a separate deterministic Windows
link issue: every non-Linux target inherited `c++` and `Accelerate` framework
links. Windows GNU now uses the existing GNU archive-back-reference strategy
and `stdc++`; Unix `m`/`dl` and Darwin frameworks are excluded on Windows.
Linux and macOS link plans remain exact in the focused regression controls.
The existing Windows R shared-library link already uses `stdc++` and archive
groups. This is a build-only correction, not a runtime/kernel/API change.

## Focused validation

Seven standalone Rust controls passed with warnings denied: existing source
paths, spaces/parent components, missing-source refusal, shortened output
isolation, malformed output refusal, Windows link selection, and unchanged
Linux/macOS link plans. Format and Clippy checks were silent. Both edited YAML
files parsed. The same controls are now included in the existing Windows and
Linux CI jobs; there is no extra job, model call or local native engine rebuild.
The host-specific Windows path checks remain pending actual Windows execution.
`std::path::absolute` is stable since Rust 1.79, below the existing 1.85 MSRV.

Both source archives and Cargo.lock remain byte-identical to the failed parent.
No vendor source, locked crate version, dependency, model, numerical threshold,
compiler optimization or accepted Phase 8 experiment changes. Binary test
executables and metadata remain local. Hashes and commands are recorded in
`correction-controls.json`; previous local installation evidence remains scoped
to its original source and DLL.

## Primary references

- https://doc.rust-lang.org/std/fs/fn.canonicalize.html
- https://doc.rust-lang.org/std/path/fn.absolute.html
- https://cmake.org/cmake/help/latest/generator/MSYS%20Makefiles.html
- https://cmake.org/cmake/help/latest/variable/CMAKE_OBJECT_PATH_MAX.html
