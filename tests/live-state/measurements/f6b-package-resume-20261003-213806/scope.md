# Affected-case recovery and remaining package stages

The initial package run remains failed. Eighteen successful cases are carried
from its exact source; this run executes only the failed steering/ablation case
with separate row-name and exact numeric assertions. The two manifests differ
only in that test file. The same fresh F6b installation is used; no native or R
production code changes or repeated installation. All nineteen cases are now
covered, including three actual cached-Qwen cases, with no test skips or warnings.
Previously unexecuted source build and scoped check passed with zero errors and
two expected omitted-rendered-vignette warnings. Full CI remains required.
