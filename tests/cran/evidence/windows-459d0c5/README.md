# Windows vignette failure and bounded correction

Original run39159055228/job117768281341 on459d0c5 remains failed. Full original
job output and real Rtools registry-import receipt are preserved. Read
`diagnosis.json` for the specific failure and acceptance boundaries. Three base
library-path controls pass; fourteen condition/body AST pairs and two unchanged
synthetic bodies are verified without executing models. Actual Quarto Windows
build/check and final package acceptance are pending; no native work was replayed.

The temporary-library issue is documented upstream in quarto-dev/quarto-r#217.
The small probe will fail before compiling relm if either Quarto source build or
vignette rebuilding still loses the package library. Original failed output is
not reclassified by these local controls. No full local rendering claim.
