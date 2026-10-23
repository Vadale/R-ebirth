# Recorded CPU run — 2026-10-23

One pass over six newly authored synthetic notices. Inputs, labels, prompt and
settings were fixed before generation. No warm-up, retry, output repair or prompt
tuning followed the results. This is a worked example, not a held-out evaluation.

**Six complete JSON responses, six correct amounts (including missing values),
and five matching amount/evidence pairs.** One response requires correction:
Harbour correctly returned a null amount but supplied evidence about a per-project
cap. The task required null for both fields when no total budget was stated.

| ID | Expected EUR | Model EUR | Amount + evidence | Generation (s) |
| --- | ---: | ---: | --- | ---: |
| N01 | 250000 | 250000 | matches | 19.087 |
| N02 | missing | missing | **fails: non-null evidence** | 18.701 |
| N03 | 120000 | 120000 | matches | 20.474 |
| N04 | 300000 | 300000 | matches | 19.877 |
| N05 | missing | missing | matches | 15.324 |
| N06 | 600000 | 600000 | matches | 22.086 |

The actual N02 response is preserved without repair:

```json
{"amount_eur":null,"evidence":"Harbour 2026 offers grants of up to EUR 40000 per project."}
```

A quotation appearing in a document does not necessarily support the requested
fact. All six rows remain marked for human review in real use. The scorer checks
the declared toy-case contract; it is not a general factuality judge.

## Measured resources

- **Generation:** 115.549 seconds total for six sequential calls; 15.324–22.086
  seconds per notice. Includes prompt processing and constrained generation.
- **Model load:** 0.939 seconds after the model-file verification pass.
- **Model verification:** 4.201 seconds. Verification reads the file first, so
  the subsequent load is not a cold-cache loading benchmark.
- **Run:** 120.792 seconds inside the script; 121.16 seconds for the R process
  measured by the shell, including startup and shutdown.
- **Peak resident memory:** 1,336,537,088 bytes (**1.245 GiB**) for the R process,
  from Linux `VmHWM` sampled after generation. Includes R, the model and working
  buffers. It is not the machine's total memory or an additive allocation total.
- **Model file:** 1,117,320,736 bytes, about 1.12 GB on disk.
- **Online model preparation:** 107.49 seconds for download and verification on
  this connection. Package installation is excluded. No paid inference API was
  called; electricity, monetary cost and review time were not measured.

Environment: Linux x86_64, AMD Ryzen 7 4800H, four configured CPU threads,
R 4.6.1, published relm 0.6.1 and jsonlite 2.0.0. The CPU time can exceed wall time
because native threads execute concurrently. This single observation is not a
throughput estimate for 1,000 documents or a platform comparison.

## Inspect or reproduce

- [Every raw answer](results.csv), including the failed evidence field.
- [Per-case review](review.csv) and [measured metrics](metrics.json).
- [Package/model identity and settings](provenance.json),
  [environment and preparation costs](environment.json), and [input hashes](inputs.csv).
- [Dataset](../notices.csv), [expected values](../expected.csv), [prompt](../prompt.txt),
  [schema](../schema.json), [settings](../settings.json) and [executed R script](../run.R).

The documentation check binds this recording to those exact input/script bytes.
Recalculate the saved review without a model:

```sh
Rscript --vanilla examples/funding-extraction/quickstart/run.R score examples/funding-extraction/quickstart/recorded
```

To generate new results, follow the [recipe](../README.md), use a new output
directory and retain all cases. No guarantee of byte-identical generation across
builds or hardware is implied. This run neither replaces the project's earlier
[negative D1 evaluation](../../../../docs/d1-extraction-evaluation.md) nor establishes
real-document accuracy, independent human usability or clinical suitability.
