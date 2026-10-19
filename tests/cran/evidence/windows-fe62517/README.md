# Windows API target ordering correction

The Windows job on `fe62517f68fc21037d41fbd3e1b486507eddcbab`
(run 39154760342, job 117755578511) failed in the new Rtools declaration
preflight: `SetThreadInformation` was undeclared. The seven path/link controls
passed; the full package-check step was skipped. The preflight compiled only a
small fixture, not the engine. The original job remains failed.

The relm adapter force-included `windows.h` before the pinned `ggml.h` selected
`_WIN32_WINNT`. MinGW could consequently hide the API and the engine's conditional
thread-throttling branch. The correction includes the actual pinned `ggml.h`
first, preserving its default Windows 10 target and any explicit caller override.
It does not duplicate the target constant in production or change vendor bytes,
scheduling calls, compiler versions, ABI, kernels or numerical criteria.

Focused Linux controls now emulate the SDK's earlier target default. The old
adapter from the failed commit is rejected by both target/order assertions.
The corrected adapter passes the default 0x0A00 and explicit 0x0602 cases,
12-byte structure/0,4,8 offsets, missing/existing declarations, one-source CMake
scope, paths with spaces and non-Windows no-op. Positive compiles deny warnings;
expected negative errors are retained. This is mocked SDK evidence, not actual
Windows acceptance. The existing hosted preflight will use real Rtools headers
and link a retained typed API pointer without invoking a scheduling call.

`source-sha256.json` binds the correction and unchanged protected inputs.
`owner.json` verifies retained raw outputs without replaying the engine or models.
Small compiled control artifacts remain local; this archive contains source,
receipts and original logs only. Earlier failed archives remain unchanged.
