# relm_direction/1 canonical encoding — frozen version 1

This is a typed, language-independent byte stream for checksums, not a public
file import format. Validate exact schema, names, types, dimensions, limits and
finite values before encoding. A checksum detects accidental modification;
neither this encoding nor the supplied model record authenticates loaded weights.

Every stream begins with ASCII `relm_direction/1` followed by one NUL byte,
then an encoded scalar string naming its domain, then one typed value. Domains
are `primitive`, `matrix`, `pairs`, `splits`, `context`, `values`, and `artifact`.
There is no byte-order mark, newline, padding or trailing byte. Domain names
are case-sensitive. UTF-8 bytes are retained without newline or Unicode
normalization. NUL within strings and invalid UTF-8 are rejected.

All lengths/counts/dimensions below are unsigned 32-bit little-endian, admitted
within `0..2147483647` so base R can write them with `writeBin(..., size=4,
endian="little")`. Integers are signed 32-bit little-endian; `-2147483648` is
excluded because it represents R's missing integer. Doubles are finite IEEE-754
binary64 little-endian. Preserve every double bit, including the sign of zero;
NaN/Inf are rejected. Boolean payloads are exactly one byte, `00` or `01`.

| ASCII tag | Value | Payload following the one-byte tag |
|---|---|---|
| `N` | NULL | None |
| `L` | Logical scalar | One Boolean byte |
| `I` | Integer scalar | One signed 32-bit integer |
| `D` | Double scalar | One binary64 double |
| `S` | Character scalar | UTF-8 byte length, then exactly those bytes |
| `l` | Logical vector | Element count, then Boolean bytes |
| `i` | Integer vector | Element count, then signed 32-bit integers |
| `d` | Double vector | Element count, then binary64 doubles |
| `s` | Character vector | Element count, then for each string its byte length and bytes; no repeated `S` tag |
| `R` | Fixed-schema record | Field count, then each field's `S`-encoded name followed by its typed value |
| `F` | Fixed-schema data frame | Row count, column count, then each column's `S`-encoded name and typed vector (including its element count) |
| `M` | Matrix | Row count, column count, `s` row names, `s` column names, `d` values in row-major order |

Scalar and length-one vector encodings differ. A data frame's column vector
lengths must equal its row count; matrix name lengths and value count must equal
its dimensions. R automatic data-frame row names, class attributes and vector
names are not encoded: the artifact validator checks their allowed structure
separately. No arbitrary attributes or unknown record fields are admitted.

Fixed-schema record/data-frame fields use the order listed below, after checking
that every required field occurs exactly once and no unknown field occurs.
Reordering named fields for canonical encoding does not permit reordering any
rows, pair IDs, splits, neurons, matrix coordinates or corresponding values.

## Domains and fixed schemas

- `primitive`: one explicitly typed fixture value; test tooling only.
- `matrix`: one `M`, including its ordered pair and neuron names. Both target
  and control use this domain and separate digest fields.
- `pairs`: the `F` used as `context$pairs` below.
- `splits`: the `F` used as `context$splits` below.
- `context`: the full context `R` below; exported as a cross-language encoding
  fixture. The artifact embeds this context directly, with no extra prefix.
- `values`: `R(neuron=i, value=d)`, preserving neuron/value correspondence.
- `artifact`: `R(neuron=i, value=d, direction=R)`. `direction` contains the
  metadata below. Its `digests` omits only its own `payload` field while hashing;
  all five other digest fields are included. The persisted artifact's digest
  record contains all six fields. Do not omit its other hashes or replace its
  payload field with an empty string or NULL.

`direction` field order and types:

1. `schema`: S, exactly `relm_direction/1`.
2. `layer`: I, public 1-based layer.
3. `component`: S, exactly `residual`.
4. `context`: R in the schema below.
5. `method`: R(`algorithm`=S, `normalize_pairs`=L, `orthogonalize`=L).
   Algorithm is exactly `paired_difference_mean/1`.
6. `diagnostics`: R in the schema below.
7. `producer`: R(`relm_version`=S, `r_version`=S).
8. `digests`: R(`target`=S, `control`=S, `pairs`=S, `splits`=S,
   `values`=S, `payload`=S). Every digest is lowercase 64-character SHA-256 hex.
   The payload domain omits the last field, as specified above.

`context` field order and types:

1. `model`: R(`sha256`=S, `architecture`=S, `quantization`=S,
   `hidden_size`=I, `layers`=I, `engine_revision`=S).
2. `capture`: R(`component`=S, `positions`=S, `input_format`=S,
   `tokenizer`=S, `add_special`=L, `parse_special`=L,
   `template_sha256`=N, `context_length`=I, `backend`=S, `relm_version`=S).
3. `pairs`: F(`pair_id`=s, `target_sha256`=s, `control_sha256`=s,
   `target_pos`=i, `control_pos`=i).
4. `splits`: F(`prompt_sha256`=s, `split`=s).
5. `seed`: N or I.

The model/capture semantic restrictions and limits are exactly D-045 section 2.
The checksum fixture's model digest is synthetic data, not a model identity.

`diagnostics` field order and types:

1. `guard_relative`: D, exactly `64 * 2^-52`.
2. `pairs`: F(`pair_id`=s, `target_norm`=d, `control_norm`=d,
   `difference_norm`=d, `used_norm`=d), in construction-pair order.
3. `mean_pair_norm`: D, mean of the used difference norms; pair-normalized
   rows have unit norm. The original difference norms remain separately above.
4. `control_mean_norm`: D, norm of the mean original control vector.
5. `mean_control_norm`: D, mean of the original control-row norms.
6. `pre_projection_norm`: D, norm of the mean used difference.
7. `post_projection_norm`: D, norm after optional orthogonalization; equal
   to `pre_projection_norm` when projection is disabled.
8. `final_norm`: D, measured norm of the returned unit vector.

Compute the original control mean even when projection is disabled, for its
diagnostic norm; its degeneracy is a refusal only when projection is enabled.
Means are accumulated in recorded row order after scaling each contribution by
the row count, so a representable mean need not first form an overflowing sum.
Norms use max-absolute-value scaling. Reject nonfinite intermediate results.
Arithmetic comparisons allow the frozen 1e-12 absolute-plus-relative tolerance;
the byte encoder itself never rounds, reformats or normalizes a supplied double.

## Streaming implementation contract

Encoding is a sequence of writes, not a concatenation of all encoded inputs.
The reference writer splits every write into at most 4096 bytes, updates SHA-256
incrementally and counts bytes before writing. The R implementation can use
the same bound with one unique temporary binary file and `tools::sha256sum()`.
Check the admitted canonical byte estimate before each chunk; close and unlink
that file on success, error or interrupt. Only one checksum file may exist at
a time. Stream matrices one row at a time; never allocate a complete transposed
matrix, difference matrix, UTF-8 concatenation or full binary artifact buffer.

Fixtures include CSV indices/specifications plus `.bin` and `.hex` streams.
Base R can consume them with `read.csv(..., colClasses="character")`,
`readBin(..., what="raw", n=...)` and ordinary scalar conversion; no JSON
parser or package dependency is needed. Decode a fixture double's `scalar_hex`
with `readBin(rawConnection(raw_bytes), "double", n=1, size=8, endian="little")`
when exact signed-zero/bit recovery matters. Actual software provenance is in
separate receipts; the artifact fixture uses deterministic example versions.
