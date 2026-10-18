# WP15 source packaging review

Date: 2026-10-18. Scope: first source packaging/CPU portability milestone.
Reviewer: separate read-only `wp15_packaging_review` agent. The parent implements
changes and executes validation; no independent test-execution claim is made.

The initial review requested two P2 corrections:

1. Extracting directly into `src/llama.cpp` could leave an incomplete directory
   that a later configure would accept. Extraction now uses owned temporary
   staging, validates completion and publishes by rename. The regression uses a
   real incomplete archive and checks failure cleanup followed by successful
   extraction.
2. Windows Git newline conversion could break exact-byte verification before
   compilation. `.gitattributes` disables newline conversion without disabling
   textual diffs.

The same reviewer inspected both concrete corrections and approved the affected
closure. It independently inspected 766 regular engine members (including Git
executable modes), 81 locked crates and 3,479 vendor archive members. Retained
Cargo file checksums matched; the only original-vendor delta is the disclosed
wit-bindgen checksum inventory for four omitted wasm-only compiled assets.
Original source/license files remain unchanged.

The review did not execute configure, tests, Cargo, native builds or models.
Actual source installation, Windows compilation and final CRAN checks are
separate gates. This is not acceptance of all WP15 requirements or of a CRAN
submission.
