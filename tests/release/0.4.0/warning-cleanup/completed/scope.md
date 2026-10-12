# Corrected production package — 2026-10-12

The actual source-package check and fresh Mac binary installation passed.
R CMD check --as-cran reports zero errors, zero warnings and one incoming NOTE
(new submission and a 5,152,966-byte source archive). Shell/pragma/HTML-manual
checks, examples, six vignette checks/rebuilds and PDF manual passed. Package
tests report 5,010 passes and 130 explicit skips: 62 production-omitted native
fixtures, 62 optional-model tests, four repository-only fixtures, one download
and one CRAN-gated model case. No assertion warning or compiler/linker warning
was emitted in the retained installation/test logs. Rust static-library link
instructions are ordinary informational notes, not hidden warnings.

Independent read-only inspection checked 816 staged source hashes, 797 current
repository inputs, 49 installed files and exact source/binary archive bytes.
The 814-file source archive has 794 exact repository files, 19 generated files
and DESCRIPTION with equivalent original DCF fields plus build metadata.
All 18 carried inst/doc files are unchanged. Every binary file matches the
fresh installation. The retained installed receipt has 250 matching function
bodies/formals, no registered native fixtures and 27 unchanged profile fields.

The driver's awaiting_owner_verification status is preserved. The separate
owner is passed. All inspection used retained outputs, with no builds, tests,
model calls or RNG replay. Parent website/RStudio/LLM observations retain their
original source and DLL; this gate does not claim they ran on the new DLL.
The earlier failures and warnings remain in their separate archives. No CRAN
submission, Windows/CUDA acceptance or generalized numerical/quality claim.

Source and binary assets and compiled DLLs stay local until publication.
