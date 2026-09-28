# Restartable funding extraction

Run a local GGUF through relm, inspect a normal CSV, and resume after a stopped
process. This is the D2 reference application: one R process, one model and one
writer. It adds no relm API or package dependency. Its sole additional runtime
dependency is application-only **jsonlite 2.0.0**, approved in D-031.

The example uses three **development** cases and the frozen D1 prompt/schema.
`success` means the output passes field/type and exact-source-quote checks. It
does **not** mean the extracted value is correct or the quote supports it.
[D1's negative quality evaluation](../../docs/d1-extraction-evaluation.md)
remains unchanged; review extracted values before using them.

## Prepare once

Run commands from the repository root on macOS or Linux. Start with R >= 4.5
and an installed **relm 0.2.0.9000** build from this checkout, including nanoarrow.
The released relm 0.2.0 predates constrained generation and is insufficient.
The normal [source installation](../../docs/getting-started.md) applies; this recipe does not
install a compiler, R, or the initial relm build for you.

If jsonlite 2.0.0 is absent, install this exact application dependency during
preparation, in the same selected library or another ordinary R library:

```r
install.packages(
  "https://cran.r-project.org/src/contrib/Archive/jsonlite/jsonlite_2.0.0.tar.gz",
  repos = NULL, type = "source"
)
```

Prepare a private library snapshot and verify the model already on disk:

```sh
Rscript --vanilla examples/funding-extraction/setup.R \
  --relm-library /absolute/path/to/checked-R-library \
  --model /absolute/path/to/Spark-X2.5-4B-Q8_0.gguf
```

The default alias is `spark-x2.5-4b-q8_0`. Setup verifies its registry SHA256 and
size, references the GGUF in place (no second 4.38 GB copy), and copies the three
installed packages into `.funding-extraction/environment/library`. It records
their versions and complete file fingerprints, the R version/platform, model
SHA256 and setup time. Keep the model at the recorded absolute path.

If `--model` is omitted, **setup explicitly downloads** the selected registry
alias. For the small CPU integration model, use
`--model-alias qwen2.5-0.5b-instruct-q8_0`. A custom trusted local GGUF requires
`--model FILE --model-sha256 EXPECTED_SHA256` instead of an alias. Supply
`--environment DIR` to choose a different prepared directory. Setup refuses an
existing directory; create a new one when upgrading a build or R version.

This is a snapshot of a trusted installed build, not a portable image or an
independent verification of its publisher. System libraries and drivers remain
host prerequisites. Prepare separately for another OS, architecture or R version.

## Run and inspect

```sh
Rscript --vanilla examples/funding-extraction/run.R
```

The defaults use the prepared environment, the adjacent `config.json`, and
`.funding-extraction/run`. There are no installs, downloads or network calls in
the run/resume path. Always use a fresh R session (`--vanilla`): a namespace
already loaded from another library is rejected.

Options are `--environment DIR --config FILE --output DIR`. Configuration paths
are relative to the configuration file. The checked-in configuration uses Metal;
set `backend` to `"cpu"` for Linux. Automatic backend selection is intentionally
absent so the recorded execution choice is explicit.

The JSON configuration contains file paths for the prompt, domain schema and
documents; context/output-token limits; chat mode; and sampling parameters.
Temperature/top-p are decimal **strings** (`"0"`, `"0.95"`). All JSON numbers use
integer notation. Documents are an array of `{id, target, text, seed}`. IDs are
unique ASCII filenames of at most 64 characters. The input JSON is limited to
8 MiB and 10,000 documents; each text to 1 MiB. Size the context for your actual
inputs: exceeding the model context produces a visible per-document failure.
The domain validator targets this funding schema; adapting the task requires
adapting the validator, not merely changing schema text.

Inspect these files in the output directory:

| File | Purpose |
|---|---|
| `results.csv` | Ordinary table of values, source quotes, status and error details |
| `records/<id>.json` | Authoritative immutable result, raw model output, source/run identities, seed, timing and SHA256 |
| `manifest.json` | Pinned model, R/build, backend, prompt/schema/input/application identities |
| `summary.json` | Counts, newly processed/reused records, first-result and elapsed time |
| `events.jsonl` | Diagnostic events with IDs/status/classes, without source text |

Exit **0** means all records pass application checks; **2** means the batch
completed but contains invalid extractions or generation errors; **1** means a
configuration, integrity, environment or execution failure prevented completion.
Failed/invalid document records remain visible and terminal. Re-running does
not selectively retry them. Use a new output directory for a deliberate new run.

## Resume after interruption

After an ordinary completed run, repeat the same command. Every committed record
is checked before the model loads; a fully completed run loads no model. Records
stay byte-for-byte unchanged. CSV and summary are derived views and are rebuilt.
Changed input, seed, prompt, schema, application code, model or prepared build
refuses stale reuse; choose a new output directory for changed work.

A hard termination can leave `.lock/owner.json`. Stop all writers and recovery
processes, inspect its host/PID, and copy its exact nonce. Then explicitly recover:

```sh
Rscript --vanilla examples/funding-extraction/run.R \
  --recover-lock NONCE_FROM_OWNER_JSON --confirm-owner-stopped
Rscript --vanilla examples/funding-extraction/run.R
```

Include your original `--output`/`--environment` options when using custom paths.
Recovery refuses a live PID, mismatched host or mismatched nonce. A lock left
before publishing `owner.json` may contain only temporary files: after stopping
all writers, use the literal recovery nonce `empty`. Recovery quarantines the
directory as `.recovered-lock-<nonce>` rather than deleting evidence. Age alone
never makes a lock recoverable. An unrecognized/corrupt owner requires manual
inspection; do not remove a lock while another process might own the run.

The unfinished document may be computed again with its original seed. A closed
temporary file is published by same-directory rename; already published records
are never replaced. Orphan `.tmp-*` files are ignored. Events are diagnostic and
may contain an incomplete entry after a kill; readers should skip blank/broken
lines and use committed records as authority.

The tested guarantee covers **process interruption on local Mac/Linux
filesystems** and one cooperating writer. It does not cover power loss, network
filesystems, concurrent recovery, malicious filesystem modification, or identical
floating-point inference across different machines. Keep run directories private;
raw results and CSVs contain document-derived data. Inspect untrusted values as
data when opening CSVs in spreadsheet software.

## Validation

The independent Python-standard-library harness tests real R processes and
SIGKILL at both sides of rename, competing writers, explicit recovery, corrupted
records, changed identities and canonical JSON byte agreement with S0:

```sh
python3 tests/funding-extraction/test_restart.py \
  --relm-library /absolute/path/to/checked-R-library
```

It uses an injected deterministic engine and the tiny committed GGUF for setup
verification; it never loads a model. It runs in ordinary Mac/Linux PR CI.
The native harness uses an already downloaded pinned model, disables networking
for each run/recovery process, and records setup/first-result time and peak RSS:

```sh
python3 tests/funding-extraction/run-model.py \
  --model /absolute/path/to/Spark-X2.5-4B-Q8_0.gguf \
  --model-alias spark-x2.5-4b-q8_0 --backend metal \
  --r-library /absolute/path/to/checked-R-library --output /tmp/d2-measurement
```

On Mac, network isolation uses `sandbox-exec`; on Linux, it uses `sudo unshare
--net` and drops to the caller UID. Linux CPU runs alongside the nightly pinned
0.5B integration model; no large-model download enters ordinary PR CI.

## Planned local service

D2 remains a runnable batch application. The separate
[WP12a service contract](../../docs/service-contract.md) proposes a persistent
single-worker local HTTP template and recovery/load limits. Its D-034 dependency
proposal still needs approval; no service command or runtime acceptance is
included in this batch example.
