# R-hosted wrapper generation — focused local evidence

The existing production DLL supplies its actual extendr metadata. The new R
script reproduces the committed wrapper file byte for byte; 31 installed wrapper
bodies/formals and namespace membership pass 95 expectations. This is parent-DLL
metadata evidence, not a fresh native build.

Two miniature C packages exercise actual post-link generation and R installation
for production and selftest metadata with space-bearing paths. Their wrappers
execute and return the expected value. Both compile without warnings. Invalid
metadata and a missing DLL are intentional negative controls: they exit nonzero
and preserve an existing output file. Their raw errors are retained.

Configure controls preserve literal CMake paths, require one Cargo build and one
R-hosted generator per template, and retain the previous bad-replacement refusal.
No models, inference, full relm build, benchmark or old suite ran locally.

`owner.json` binds the exact scripts and prior DLL. The new real non-shared-R
installation and all changed-package platform checks are pending automatic CI.
R4.6.1 and nanoarrow0.9.0 checking-tool archives are verified and retained locally;
no compiler, dependency version or native source archive changed in the package.
