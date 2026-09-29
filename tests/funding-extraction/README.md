# Restartable extraction acceptance tests

The model-free process harness runs the real application setup, JSON parser,
canonical writer, manifests, record publication, locks and resume code. A private
engine injection returns constructed funding records or controlled failures.
It performs no model loading, inference, package installation or download.

Run on local macOS or Linux after preparing the installed application packages:

```sh
python3 tests/funding-extraction/test_restart.py \
  --relm-library /absolute/path/to/installed/library
```

The library must provide relm 0.3.0; jsonlite 2.0.0 and nanoarrow must also be
available in that library or R's ordinary library paths. The harness invokes the
real setup CLI to snapshot these packages and reference its own temporary copy
of the tiny in-repository synthetic GGUF, with an explicit independently computed
SHA256. This tiny file is only a setup identity fixture; it is never loaded.
The application CI on macOS/Linux runs this harness without a model download.

Use `--work-dir /new/empty/path` to choose the artifact directory. The default is
a fresh temporary directory. Artifacts are retained for inspection: setup output,
worker controls/logs, immutable records, attempted seeds, manifests and recovery
quarantines. The runner bounds subprocess timeouts and always kills/reaps its
own paused children on failure.

The checks cover:

- Exact R canonical bytes and SHA256 against S0's independently specified
  manifest/output digests and Python's sorted compact UTF-8 encoder, including
  empty objects/arrays, nulls, Unicode, combining characters and JSON escapes.
- Duplicate decoded keys, malformed Unicode, valid surrogate pairs and escaped
  backslash literals, decimal/exponent number rejection before rounding,
  unknown fields, invalid input types, duplicate IDs and unsafe result IDs.
- Content-based identity changes to model, prompt, schema, source target/text,
  seed, configuration and the prepared native package build; refusal of a
  namespace already loaded from outside the prepared library.
- Corrupt records, altered identities with recomputed outer digests and unknown
  committed filenames, with no generation or committed-file replacement.
- Competing writers and explicit recovery refusal for a live PID, wrong nonce,
  different hostname or missing confirmation.
- Real SIGKILL at both sides of the second record's rename: previously committed
  bytes survive; unfinished computation repeats with the same seed; an already
  renamed record is skipped.
- Constructed ownerless-lock states, including a temporary owner file before
  publication, plus abandoned record temporary files and a truncated diagnostic
  event. The two record-rename checkpoints above use actual process termination.
- Terminal invalid/error records preserve raw output/conditions and remain
  committed on resume.

These assertions concern process interruption on the tested local filesystems.
They do not establish power-loss durability, network-filesystem behavior,
extraction usefulness or a universal exactly-once inference guarantee.
The separate model runner measures actual clean-session operation.
