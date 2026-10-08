# relm_direction/2 canonical encoding — frozen version 1

D046 extends the [D045 typed encoding](../directions/ENCODING.md) without
changing any tag, payload, field order, signed-zero rule or streaming limit.
Every schema-2 stream starts with exact ASCII `relm_direction/2` and one NUL,
then the D045 encoded scalar domain name and typed value. This applies to all
seven domains: `primitive`, `matrix`, `pairs`, `splits`, `context`, `values`,
`artifact`. Schema-1 streams retain their exact `relm_direction/1` prefix and
accepted bytes. Do not infer the version from vector length or rewrite old data.

For schema 2 the direction metadata's `schema` is `relm_direction/2`,
`component` is exactly `mlp_out` or `attn_out`, and `layer` is a public 1-based
integer in `1:L`. The embedded `context$capture$component` must equal the
metadata component. Both component strings and the layer are encoded and bound
by the payload checksum. No new field is introduced. All other D045 schemas,
restrictions, diagnostics and paired-difference arithmetic remain unchanged.

Validate exact field names/types and admitted values before canonical ordering.
Never sort matrix coordinates, neurons, construction pairs or split rows.
The artifact hashing record omits only its own `digests$payload` field; the
persisted artifact includes that computed field last. Every other digest is
computed with the schema-2 prefix, even where the underlying matrix/pair/value
body is identical to a schema-1 body. SHA-256 covers exact bytes without text
formatting, normalization, host endian or R serialization.

The fixtures use small supplied matrices and a synthetic recorded model digest;
they do not assert those matrices came from the tiny GGUF or certify loaded
weights. Model forward fixtures are a separate independent numerical leg.
The artifact fixture producer/version strings are deterministic data. Actual
Python/library/source versions and hashes belong to the producer manifest.

`encoding-fields.csv` supplies preorder typed nodes, using the same columns as
D045: `case,path,kind,field,length,nrow,ncol,value,scalar_hex`. The scalar hex
preserves exact double bits, including negative zero. `encoding-index.csv`
records domain, bytes, digest and binary/hex filenames. Read with base R
`read.csv(..., colClasses="character")` and `readBin(..., what="raw")`; no JSON
parser dependency is needed. The optional manifest JSON is provenance only.

The writer streams in chunks of at most 4096 bytes, checks the byte cap before
each write, and incrementally hashes the result. Product writers retain the
same single temporary checksum-file/cleanup and bounded-row contract as D045.
