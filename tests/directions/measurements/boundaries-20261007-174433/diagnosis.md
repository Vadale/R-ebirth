# First installed F6d attempt: test harness failure

The fresh R-only install succeeded using the unchanged accepted DLL. The overall run FAILED because `expect_s3_class()` in the installed testthat version does not accept `info`. This stopped the expected-refusal case before its first assertion; it is not a product failure or numerical result. All other recorded cases passed, with no test warnings. The external testthat/nanoarrow build-version warnings and documentation link-resolution messages are retained.

Correction replaces that assertion with `expect_true(inherits(...), info=id)`, requiring the identical expected condition class. No product source, tolerance or fixture changed. Only this incomplete case and the unexecuted codetools check resume; no reinstall or repeat of accepted cases.
