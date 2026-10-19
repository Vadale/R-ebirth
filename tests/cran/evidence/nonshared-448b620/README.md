# Non-shared R header discovery

The original GitHub job failed during the package C-accessor compilation;
its failure is preserved. The R build and two dependency installs passed before
that failure. All seven stage-log hashes and the original 118,903-byte ZIP
SHA256 were verified. Raw logs are losslessly compressed; original ZIP and
compiled binaries stay local.

The exact official R4.6.1 config script returns empty stdout, status zero and
`R was not built as a library` for --cppflags when LIBR and STATIC_LIBR are empty.
The focused driver supplies controlled Makeconf values to that unchanged script
and runs the complete original/current owned build scripts against real local
R headers and the unchanged C accessor. This reproduces the old failure and
checks the correction without a relm engine build or any model call. It is not
a complete local non-shared-R installation. Ordinary hosted CI must establish
that scope. The invalid-header refusal and original missing-header diagnostics
are intentional retained failures, not warning suppression.

The special include path/architecture case proves successful compilation with
that argument path; it is not acceptance of an actual multi-architecture R.
The standalone control uses local installed R, independently of install variables.
No old model, package-installation, or numerical acceptance was replayed.

The first matrix ended with eleven SUCCESS jobs and this one FAILURE, according
to the compact PR status. Full successful-route verification is reserved for the
corrected final head; no current whole-matrix acceptance is claimed.
