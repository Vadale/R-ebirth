"""Check the unchanged D045 producer with explicit D056 transport provenance.

All numerical/encoding/control bytes remain exact. Both manifests are validated
against their own actual bytes; no saved or generated artifact is rewritten.
"""
import hashlib
import runpy
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests/llm-golden"))
sys.path.insert(0, str(REPO / "tests/projection"))
from transport_provenance import check_csv, check_runtime
from compare_reference import manifest

PRODUCER = REPO / "tests/llm-golden/directions/reference_directions.py"
PRODUCER_SHA = "0e6924eb169ebaf2fb32b63b04b7957d70154ca1b9fe79d402c74c56c34d12d6"
FROZEN_SHA = "9c114697be309228de7c3836f72cba958e06ab11ffca5af90c9b4472870e9685"
GOLDENS = PRODUCER.parent / "goldens"


def compare(actual, expected):
    assert hashlib.sha256((expected / "manifest.csv").read_bytes()).hexdigest() == FROZEN_SHA, "frozen manifest changed"
    names = manifest(expected)
    assert manifest(actual) == names, "manifest inventory/order changed"
    for name in names:
        a, e = actual / name, expected / name
        if name != "provenance.csv":
            assert a.read_bytes() == e.read_bytes(), ("exact reference bytes", name)
            continue
        check_csv(a.read_bytes(), e.read_bytes(), "requirements_sha256")


def main():
    check_runtime()
    assert hashlib.sha256(PRODUCER.read_bytes()).hexdigest() == PRODUCER_SHA, "frozen producer changed"
    sys.path.insert(0, str(PRODUCER.parent))
    producer = runpy.run_path(str(PRODUCER))
    # Keep the original CLI's environment guards before generate().
    assert producer["platform"].python_version() == "3.13.5"
    assert producer["importlib"].metadata.version("numpy") == "2.5.1"
    assert producer["importlib"].metadata.version("gguf") == "0.19.0"
    with tempfile.TemporaryDirectory(prefix="relm-directions-check-") as tmp:
        result = producer["generate"](Path(tmp))
        compare(Path(tmp), GOLDENS)
    print("D045_REFERENCE_OK", result)


if __name__ == "__main__":
    main()
