# D1 evaluation artifacts — macOS arm64 / Metal

These are measured model outputs, including unsuccessful candidates. They do
not establish useful extraction. See the [evaluation report](../../../../docs/d1-extraction-evaluation.md).

Each run directory retains the original `report.json`, prompt template and both
prediction JSONL files. Each JSONL `output` string decodes to the exact UTF-8
bytes of the corresponding original `output-N.json`; the report records that
SHA256. This packing avoids duplicating those bytes in dozens of tiny files.
If a failed call returned partial bytes, they are retained separately under the
mode directory. Absolute command/library paths in reports describe the original
machine; they are provenance, not portable instructions.

Inputs, source snapshots, schema and reference labels are the unchanged files
in `tests/structured-output/`, pinned by each report. Reconstruct the label-free
prompts with the recorded template and `evaluate-model.py`; substitutions do not
interpret braces inside source text. No model weights are included. Model pins
are in `rebirth/inst/models.csv`.

- `development-1p5-v1-exploratory`: initial prompt; predates explicit native/
  runtime identity checks. Its earlier driver source is not archived here;
  treat it as historical output evidence, not the frozen candidate's provenance.
- `development-1p5-v2`: second and final prompt version.
- `development-0p5-v1`: optional smaller-model comparison, using the first prompt.
- `development-1p5-v1-runtime`: identical selected configuration with runtime
  identity checks; predictions exactly match the first run. Predates the
  interrupted-metadata reporting fix.
- `development-final`: unchanged selected configuration with the reviewed
  evaluator at Git commit `8edeee2`; supplies freeze provenance.
- `candidate.json`: written before held-out inference; binds the complete
  selected configuration and the final development report digest.
- `held-out`: the one held-out evaluation. A failed quality gate is retained as
  a failed result, never converted to success by artifact checks.

The driver records native-library bytes and R/package versions. It does not
digest installed R wrapper bytes; the installed S1 library was left unchanged
throughout. Development repetitions after instrumentation/reporting fixes are
not independent quality samples. Human review time remains unmeasured.

Offline verification, also run by the Rust CI golden job:

```sh
python3 tests/structured-output/verify.py --self-test
python3 tests/structured-output/test-evaluate-model.py
python3 tests/structured-output/check-evaluation-artifacts.py
```

The artifact check verifies original prediction bytes and recalculates scores.
It validates the report's honesty, not whether the model passed its quality gate.
