"""D-056/D-057: exact requirements transition for approved transport security fixes.

Historical producer manifests keep their original requirements hash. Recomputed
metadata records the current file; only this one approved transition may differ.
This does not authorize any arithmetic dependency or producer change.
"""
import csv
import hashlib
import io
import importlib.metadata
from pathlib import Path

REQUIREMENTS = Path(__file__).with_name("requirements.txt")
REQUIREMENTS_KEY = "tests/llm-golden/requirements.txt"
HISTORICAL_SHA = "58557e747b0d19c9eb0dd24ecf2317bb9d28e9bc4337bd43a85b43f614363086"
CURRENT_SHA = "d01884102a8eca63c540107a7d2a79175085a3676566642bdf46e8a57a42278a"


def check_transition(actual, expected):
    assert expected == HISTORICAL_SHA, "unknown historical requirements"
    assert actual == CURRENT_SHA, "unapproved requirements change"
    assert hashlib.sha256(REQUIREMENTS.read_bytes()).hexdigest() == CURRENT_SHA, "current requirements changed"


def check_csv(actual, expected, key):
    """Keep every CSV byte exact except the one approved requirements digest."""
    rows = list(csv.reader(io.StringIO(expected.decode("utf-8"))))
    assert [row for row in rows if row and row[0] == key] == [[key, HISTORICAL_SHA]], "requirements row changed"
    old, new = HISTORICAL_SHA.encode(), CURRENT_SHA.encode()
    assert expected.count(old) == 1, "ambiguous historical digest"
    check_transition(CURRENT_SHA, HISTORICAL_SHA)
    assert actual == expected.replace(old, new), "CSV differs outside approved requirements digest"


def check_runtime():
    check_transition(hashlib.sha256(REQUIREMENTS.read_bytes()).hexdigest(), HISTORICAL_SHA)
    assert importlib.metadata.version("certifi") == "2026.10.19", "install the approved certifi version"
    assert importlib.metadata.version("urllib3") == "2.8.0", "install the approved urllib3 version"
    print("D056_TRANSPORT_PROVENANCE historical=" + HISTORICAL_SHA + " current=" + CURRENT_SHA + " certifi=2026.10.19 urllib3=2.8.0")


if __name__ == "__main__":
    check_runtime()
