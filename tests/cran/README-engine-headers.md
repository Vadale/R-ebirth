# Engine standard-header portability regression

Run `python3 tests/cran/engine-headers.py --evidence /path/to/new-evidence`.
The existing Linux and native macOS Rust jobs run this control. It requires only
Python and the already used C++ compiler; it loads no engine library or model.

The actual `llama-graph.h` must directly include `<cstdlib>`, and is the first
include in a compiled translation unit. A concrete subclass exposes the existing
constructor's debug value. Seven independent expected values cover an absent
variable, zero, positive/negative numbers, nonnumeric text, whitespace and the
existing trailing-text behavior. There is no parsing or behavior change.

The direct dependency assertion matters: Clang with libstdc++ and GCC can compile
the defective header through incidental includes. Clang with libc++23 reproduces
CRAN's undeclared `getenv`/`atoi` errors. The test accepts `--cxx`, `--cxxflags` and `--ldflags`
for an isolated alternative standard library; it never downloads tooling.
Preserve compiler diagnostics and case outputs in the evidence directory.

D-061 fixes the declarations in owned patch0009, on the same b10828 engine.
It does not enable libc++'s compatibility macro or relax compiler/test flags.
Full engine compilation with libc++ and current platform package CI are separate
acceptance scopes; this focused test is not a complete Fedora R check.

The same direct dependency is required by `llama-mmap.cpp` (POSIX allocation and
free) and `llama-vocab.cpp` (integer conversion). Both complete translation units
are syntax-compiled with the selected standard library. The full libc++23 engine
build exposed these after the first graph-header correction; no arithmetic,
allocation strategy or parsing behavior changes.
