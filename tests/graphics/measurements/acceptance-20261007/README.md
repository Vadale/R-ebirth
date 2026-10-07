# F6c local acceptance receipts — 2026-10-07

Read [the implementation report](../../../../docs/f6c-implementation.md) for scope,
counts and all retained failures. Overall failed status files remain failed;
successful stages can be carried forward only under their recorded source.

- `package-20261007-133713`: fresh installed 24-case acceptance, then managed-
  spill failure; includes original changed source and installed-file hashes.
- `package-resume-20261007-134046`: corrected R install, affected spill tests and
  actual three-run Qwen composition passed; later renderer harness failed.
- `docs-20261007-134232`: corrected installed renderer passed; Quarto sandbox
  architecture lookup failed before document execution.
- `checks-20261007-134534`: vignette/build/scoped check ran; two omitted-vignette
  warnings and one generated-asset path NOTE remain recorded.
- `package-clean-20261007-134937`: only build/check repeated after moving render
  artifacts out; zero errors, two omitted-vignette warnings, no NOTE, no drift.
- `figures`, `model-graphics.rds`, paired/timeline CSVs: bounded numerical
  results and inspected PNG/PDFs; no native model pointers or model files.
- `rstudio`: safe plotting/export/restoration receipts and execution script;
  private user workspace/preflight files are deliberately absent. The first
  failed restoration check and the corrected successful check are both retained.
- `verify-evidence.R` and its log independently check numerical, exported and
  restoration receipts. Scratch absolute paths in the original script record
  the actual execution; they are not portable repository paths.

`file-manifest.json` hashes the archived receipt files, excluding itself and this
index. No DLL, package archive, generated HTML asset tree or private backup is
included. Source manifests describe execution inputs; documentation-only changes
after execution are not falsely treated as new runtime verification.
