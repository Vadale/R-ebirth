"""Keep installed base-R fixtures byte-identical to the independent reference."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / "tests/llm-golden/directions/goldens"
dest = root / "rebirth/tests/testthat/fixtures/directions"
expected = {p.name for p in source.iterdir() if p.suffix in {".csv", ".bin"}}
assert {p.name for p in dest.iterdir()} == expected, "Direction fixture inventory drift"
for name in sorted(expected):
    assert (source / name).read_bytes() == (dest / name).read_bytes(), name
print(f"DIRECTION_FIXTURE_MIRROR_OK {len(expected)} files")
