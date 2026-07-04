# Licensing

All original R-ebirth code — the `rebirth` R package and the `rebirth-ffi`,
`rebirth-llm`, and future workspace crates — is dual-licensed under either of

- **MIT license** ([LICENSE-MIT](LICENSE-MIT)), or
- **Apache License, Version 2.0** ([LICENSE-APACHE](LICENSE-APACHE))

at your option. `SPDX-License-Identifier: MIT OR Apache-2.0`.

This means any person, lab, startup, or company may use, modify, embed, and
redistribute the code, including in proprietary products.

The R package declares this in `DESCRIPTION` as
`License: MIT + file LICENSE | Apache License (== 2.0)`; its bundled `LICENSE`
and `LICENSE.md` carry the MIT text in the form R tooling expects.

## Vendored third-party code

Vendored dependencies carry their own licenses, recorded in [NOTICE](NOTICE).
The pinned, patched `llama.cpp` (MIT) is added under `vendor/` in WP1 — it is not
present in the current scaffold.

## The name is not licensed

The code is free; the **name** is not. Modified redistributions must rename —
see [TRADEMARK.md](TRADEMARK.md).

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual-licensed as above, without any additional terms or conditions.
