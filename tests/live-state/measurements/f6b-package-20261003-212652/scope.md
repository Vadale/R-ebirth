# Initial F6b package acceptance — failed

Fresh installation and documentation generation passed. The installed R run
executed all 19 cases (three actual cached-Qwen cases): 18 cases passed, and
one steering/ablation case failed with three outer assertions after an on_state
callback error. No test was skipped; test warning counts were zero. External
installation duplicate-lc++ and testthat patch-version warnings are retained.
The callback parent condition was not retained by the original fixture. A
single-case diagnostic reproduction is needed, with the installed binary and
unchanged assertions. No package acceptance is claimed. Source build and the
scoped package check were not executed. All frozen input hashes still match.
