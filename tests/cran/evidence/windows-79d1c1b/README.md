# Windows Cargo registry import linkage

Run39157602817/job117763956932 on79d1c1b completed the native archives and Rust
FFI release static library (8m59s). The wrapper generator then failed to link:
RegOpenKeyExA, RegQueryValueExA and RegCloseKey imports were unresolved. The
original Cargo command lacks advapi32, whereas the unchanged R DLL command in
Makevars.win.in already includes it. ggml-cpu.cpp reads CPU identification from
the Windows registry using these functions. No final install/tests/models passed.

The Windows-only Cargo link plan now includes that existing OS import library.
No new package dependency, native source, vendor, API, math or policy change.
Unix plans and Windows canonical archive handling remain unchanged. A new
regression check pins the system library to the existing R DLL link. That check,
the affected complete Windows plan and the Unix-plan guard passed once each;
seven unrelated controls were not run. Formatting/helper Clippy deny warnings.
The existing Rtools preflight adds volatile typed pointers to the three imports
and links advapi32; it will check actual headers/import libraries without calling
registry or scheduling functions. New real Windows execution remains pending.

Raw624080-byte log, failed metadata and exact source hashes are retained. The
prior Rtools header/ABI control and archive collector progressed successfully;
the original whole job remains failed. Local engine/model execution was zero.
Current full CI still needs generator execution, final R DLL link/install/tests.
Local cache/compiler mismatch from the previous optional lint remains recorded
in the previous archive and was not retried. Compiled local controls stay local.

Official prototypes and import-library requirements checked on2026-10-18:
- https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regopenkeyexa
- https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regqueryvalueexa
- https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regclosekey
