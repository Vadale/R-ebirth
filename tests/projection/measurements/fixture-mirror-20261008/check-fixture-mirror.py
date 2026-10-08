"""Bind the installed schema-2 fixtures to the frozen independent reference."""
import csv
import hashlib
from pathlib import Path


def check(root):
    source = root / "tests/llm-golden/projection/goldens"
    dest = root / "rebirth/tests/testthat/fixtures/projection"
    with (source / "encoding-index.csv").open(newline="") as stream:
        index = list(csv.DictReader(stream))
    binaries = {row["binary"] for row in index}
    if len(index) != 11 or len(binaries) != 11:
        raise ValueError("Projection encoding inventory must contain 11 distinct vectors")
    if any(Path(name).name != name or not name.endswith(".bin") for name in binaries):
        raise ValueError("Projection vector filenames must be local .bin names")
    expected = binaries | {"encoding-index.csv", "encoding-fields.csv", "artifact-digests.csv"}
    if {p.name for p in dest.iterdir()} != expected:
        raise ValueError("Projection package fixture inventory drift")
    for row in index:
        data = (source / row["binary"]).read_bytes()
        if len(data) != int(row["bytes"]) or hashlib.sha256(data).hexdigest() != row["sha256"]:
            raise ValueError("Projection reference encoding digest mismatch: " + row["binary"])
    for name in sorted(expected):
        if (source / name).read_bytes() != (dest / name).read_bytes():
            raise ValueError("Projection fixture byte mismatch: " + name)
    return len(expected)


if __name__ == "__main__":
    count = check(Path(__file__).resolve().parents[2])
    print(f"PROJECTION_FIXTURE_MIRROR_OK {count} files")
