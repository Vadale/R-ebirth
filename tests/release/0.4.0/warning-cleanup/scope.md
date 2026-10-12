# Warning cleanup preparation — 2026-10-12

D048 records the founder's request to correct the observed release diagnostics.
The installed tools are checkbashisms 2.26.12, Tidy HTML5 5.8.0 and the same
testthat 3.3.2 rebuilt under R4.5.1 in an isolated tools library. Tool binaries,
third-party source archives and native outputs stay local.

The vendor delta removes 64 GCC/Clang diagnostic directives from 14 files.
Computations and optimization directives are unchanged; patch 0005 reverses to
the same b10828 pre-patch tree. The first digest draft used component-wise Path
ordering, while the canonical manifest sorts complete path strings. Its failed
preflight and corrected digest are retained. Both canonical integrity checks
now pass. R's pragma scanner and checkbashisms complete without diagnostics.

The saved Demo A result plots without warnings, returns identical data and
closes its PNG device without opening an incidental default PDF. This check
uses saved results and performs zero model calls. Its earlier metric-selection
comparison is retained separately under demo-warning-fix.

Initial detached PID15909 stopped before any build, install or test because the
system Python lacks tarfile's data filter. The existing Python3.14 interpreter
supports it; the resumed driver retains the same safe extraction and stage logic
in a fresh output directory. Original status/source/traceback are retained.

PID15950 runs the affected production package build/check with 797 repository
input hashes, 71 isolated testthat files and exact checker executables bound.
Eighteen source overlay files change from the parent archive. All six rendered
vignettes are carried; the website and earlier real RStudio run retain their
parent source scope. This preparation is not package acceptance or publication.
