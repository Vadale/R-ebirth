#!/usr/bin/env python3
"""Run the frozen strict reference check and retain failed generated observations.

This does not edit references, change comparisons or turn a failed check green.
Only the ordinary required CI reference check calls it; it is not a second run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import runpy
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PRODUCER = REPO / "tests/llm-golden/projection/reference_projection.py"
PRODUCER_SHA = "328660be8f80c96ce1b2ad41ce831bff1b5e017505f6a895c6cb875131b49f41"
GOLDENS = PRODUCER.parent / "goldens"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compare_files(actual, expected):
    """Describe byte differences only; do not apply a numerical acceptance test."""
    names = sorted({p.name for p in actual.iterdir()} | {p.name for p in expected.iterdir()})
    differences = []
    for name in names:
        a, e = actual / name, expected / name
        if not a.is_file() or not e.is_file():
            differences.append(dict(file=name, missing_actual=not a.is_file(), missing_expected=not e.is_file()))
        elif a.read_bytes() != e.read_bytes():
            differences.append(dict(file=name, actual_sha256=sha(a), expected_sha256=sha(e), actual_bytes=a.stat().st_size, expected_bytes=e.stat().st_size))
    return differences


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    assert sha(PRODUCER) == PRODUCER_SHA, "frozen producer changed"
    frozen = {p.name: sha(p) for p in GOLDENS.iterdir() if p.is_file()}
    import numpy
    # Preserve actual runtime/BLAS/SIMD details, without guessing from OS labels.
    with (output / "environment.txt").open("w") as stream:
        from contextlib import redirect_stdout
        with redirect_stdout(stream):
            print(sys.version)
            print(platform.platform(), platform.machine())
            numpy.show_config()
            numpy.show_runtime()
    (output / "input-hashes.json").write_text(json.dumps(dict(producer=PRODUCER_SHA, goldens=frozen), indent=2)+"\n")
    original = tempfile.TemporaryDirectory

    class RetainedDirectory(original):
        def __exit__(self, exc_type, value, tb):
            if exc_type is not None and Path(self.name).name.startswith("relm-f6e-reference-check-"):
                retained = output / "failed-generated"
                shutil.copytree(self.name, retained)
                report = dict(status="failed", exception_type=exc_type.__name__, exception=str(value), differences=compare_files(retained, GOLDENS))
                (output / "difference-report.json").write_text(json.dumps(report, indent=2)+"\n")
                print("F6E_REFERENCE_FAILURE_RETAINED " + str(output), file=sys.stderr)
            return super().__exit__(exc_type, value, tb)

    before_argv = sys.argv[:]
    before_path = sys.path[:]
    try:
        tempfile.TemporaryDirectory = RetainedDirectory
        sys.path.insert(0, str(PRODUCER.parent))
        sys.argv = [str(PRODUCER), "--check"]
        runpy.run_path(str(PRODUCER), run_name="__main__")
    finally:
        tempfile.TemporaryDirectory = original
        sys.argv = before_argv
        sys.path[:] = before_path
        assert {p.name: sha(p) for p in GOLDENS.iterdir() if p.is_file()} == frozen, "frozen references changed"


if __name__ == "__main__":
    main()
