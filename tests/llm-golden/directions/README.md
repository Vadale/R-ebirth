# F6d independent direction and encoding reference

Reason for new goldens: the newly approved D-045 paired-matrix direction feature
needs an independent arithmetic and canonical-checksum reference before R
implementation. These fixtures contain no model-derived activations. They do
not replace, regenerate or widen acceptance of any existing model/golden.

The producer is `reference_directions.py`, version 1, run with the existing
repository `.golden-venv/bin/python` (Python 3.13.5; reference environment pins
NumPy 2.5.1 and gguf 0.19.0). This producer uses only Python's standard library;
it never imports relm, R, a native engine or an inference model. Actual producer,
encoding, environment and generated-file hashes are recorded separately from
the deterministic example artifact's producer metadata. See `ENCODING.md` for
the canonical bytes and field mapping shared with the R implementation owner.

Double comparisons use the predeclared absolute-plus-relative rule
`abs(actual - expected) <= 1e-12 + 1e-12 * abs(expected)`. Digest comparisons
are byte-exact. No platform-specific floating-point sidecar is required for
these arithmetic fixtures; they are not engine/kernel floating-point pins.

Only the new files under this directory may be generated. The new goldens must
be committed separately from the implementation by the owner. The existing
synthetic/HF/native model suites are outside this model-free feature's scope
and are not rerun by this producer.

## Reproduction and checks

From the repository root, the single read-only verification command is:

```sh
.golden-venv/bin/python tests/llm-golden/directions/reference_directions.py --check
```

Initial creation used the same command with `--write`. That mode refuses a
nonempty golden directory; replacing a frozen reference requires a newly
documented reason and the golden-update workflow. `--check` recomputes only
these fixtures in a temporary directory, exercises every control, compares the
exact inventory and every byte, then removes its temporary files. It does not
write the checked-in goldens. A failure never refreshes an expected value.

The first generation and check passed with CPython 3.13.5 in `.golden-venv`:
16 accepted arithmetic cases, 16 expected refusals, 52 expected direction
coordinates, 19 canonical byte vectors and 77 explicit controls. There are
50 generated files, totaling 78,441 bytes. No native build, model call or
previous golden suite was run. The independent Decimal calculation uses 90
digits; the public comparison tolerance remains 1e-12, not 90-digit equality.

## R implementation mapping

| Generated file | Purpose and consumption |
|---|---|
| `cases.csv` | Mode flags, matrix dimensions, expected acceptance/refusal reason and offending pair ID. Flags are 0/1. |
| `inputs.csv` | 192 ordered target/control coordinate pairs. Assemble by explicit `row`/`neuron`, retaining `pair_id`; do not sort away a mismatch. |
| `expected.csv` | 52 final unit-direction coordinates; compare using the absolute-plus-relative rule above. |
| `diagnostics.csv` | 112 scalar diagnostics mapped directly to the agreed names in `ENCODING.md`. |
| `pair-norms.csv` | 38 per-pair records, in original order, with input, raw-difference and used-difference norms. |
| `encoding.csv` | Domain, byte count, exact SHA-256, binary/hex paths and maximum write size for all 19 encoding vectors. |
| `encoding-fields.csv` | 295 preorder typed-node records. `path` gives the location, `kind` is the encoding tag, and container counts precede children. `scalar_hex` is the raw scalar payload (UTF-8 bytes for S; no length/tag), permitting exact base-R `readBin()` recovery. |
| `artifact-digests.csv` | All six persisted digest fields. The `artifact` node/byte fixture excludes only `payload`; append its listed digest when assembling persisted R metadata. |
| `prompts.csv` | The six literal UTF-8 prompt strings whose byte digests appear in the synthetic context. These are encoding examples, not a corpus used for model evaluation. |
| `controls.csv` | Named passed arithmetic, mutation, primitive-rejection and bounded-stream controls. Every `--check` reruns them. |
| `provenance.csv`, `manifest.csv` | Interpreter/environment/source/encoding pins and generated-file byte/hash receipts. The manifest excludes its own hash; the command prints that hash. |

Use `read.csv(..., colClasses="character", check.names=FALSE)` before explicit
conversions, so digests, pair IDs and signed-zero text are not altered by type
guessing. The `.bin` vectors are authoritative for bytes; `.hex` contains those
same bytes as lowercase hexadecimal plus one newline. No jsonlite, RDS loader
or new R dependency is needed. The example artifact's producer versions are
deliberately fixed strings (`0.0.0`, `4.6.1`), not claims about the Python producer.

The accepted cases cover all four options with unequal pair magnitudes and a
nonorthogonal control mean, sign reversal, very large/small finite norms, a
simple encoding artifact and a difference just above the relative guard.
Refusals cover zero/near-zero pairs under both weighting modes, the exact guard,
cancelled means, normalized-pair cancellation, zero/cancelled original-control
means, parallel/nearly parallel projection, nonfinite inputs/differences and
overflowing true norms. Failure labels identify numerical categories for R's
classed conditions; this reference does not prescribe R error text.

Controls reject wrong signs, omitted normalization, wrong pair weighting,
normalizing control rows before taking their mean, wrong matrix traversal or
pair order, noncanonical field order, missing domain/type/length distinctions,
Unicode normalization, loss of signed zero and invalid primitives. They also
prove a 4096-byte maximum write and refusal before exceeding an exact byte cap.

## Frozen identities

- Producer SHA-256: `0e6924eb169ebaf2fb32b63b04b7957d70154ca1b9fe79d402c74c56c34d12d6`
- Encoding specification SHA-256: `40092826e6bd4db5d80bbbc33c2ea2ab768a2e30a5cb058abc9fcbde4a04abf0`
- Generated manifest SHA-256: `9c114697be309228de7c3836f72cba958e06ab11ffca5af90c9b4472870e9685`
- Full artifact payload: 2,723 bytes; SHA-256 `e25d0f60aecaf480b884663d6d9aa1073656e4f541a90e0b749dc82e185c9bda`
- Full context: 1,527 bytes; SHA-256 `cfa4d52c175dde2e6c9b00a4f41802626eefb8eafa4107fee5db68040fc07c90`

These are arithmetic/serialization oracles. They do not establish R memory
admission, temporary-file cleanup, RDS compatibility, artifact authenticity,
native application or held-out behavioral efficacy; those remain separate
implementation and acceptance gates.
