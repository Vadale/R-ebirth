"""Verify D057's exact owned extendr patch and its offline bundle copies."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
OWNED = ROOT / "vendor/extendr"
CHANGED = {
    "extendr-ffi-0.9.0/src/backports.rs",
    "extendr-api-0.9.0/src/robj/rinternals.rs",
    "extendr-api-0.9.0/src/wrapper/environment.rs",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify():
    record = json.loads((OWNED / "manifest.json").read_text())
    config = tomllib.loads((ROOT / ".cargo/config.toml").read_text())
    assert config["paths"] == ["vendor/extendr/extendr-ffi-0.9.0", "vendor/extendr/extendr-api-0.9.0"], "Developer override changed"
    assert set(record["changed"]) == CHANGED, "Extendr patch scope changed"
    assert digest((ROOT / "rebirth/src/rust/Cargo.lock").read_bytes()) == record["cargo_lock_sha256"]
    expected = set(record["files"]) | set(record["checksum_files"])
    actual = {p.relative_to(OWNED).as_posix() for d in OWNED.glob("extendr-*") for p in d.rglob("*") if p.is_file()}
    assert actual == expected, "Owned extendr inventory changed"
    for name, hashes in record["files"].items():
        assert digest((OWNED / name).read_bytes()) == hashes["patched"], name
        assert (hashes["upstream"] != hashes["patched"]) == (name in CHANGED), name
    for name, sha in record["checksum_files"].items():
        assert digest((OWNED / name).read_bytes()) == sha, name
        checksum = json.loads((OWNED / name).read_text())
        for rel, expected_sha in checksum["files"].items():
            assert digest((OWNED / name).parent.joinpath(rel).read_bytes()) == expected_sha
    # Reversing the committed patch must recover every pinned upstream byte.
    with tempfile.TemporaryDirectory(prefix="relm-extendr-") as tmp:
        for crate in ("extendr-api-0.9.0", "extendr-ffi-0.9.0"):
            shutil.copytree(OWNED / crate, Path(tmp) / crate)
        subprocess.run(["git", "apply", "--no-index", "--reverse", str(OWNED / "r-api-lookup.patch")], cwd=tmp, check=True)
        for name, hashes in record["files"].items():
            assert digest((Path(tmp) / name).read_bytes()) == hashes["upstream"], name
    return record


def bundle_overrides(vendor):
    record = verify()
    for name, hashes in record["files"].items():
        assert digest((vendor / name).read_bytes()) == hashes["upstream"], name
    return {name: (OWNED / name).read_bytes() for name in CHANGED | set(record["checksum_files"])}


def check_bundle(archive):
    record = verify()
    for name in set(record["files"]) | set(record["checksum_files"]):
        assert archive.extractfile("vendor/" + name).read() == (OWNED / name).read_bytes(), name
    print("EXTENDR_PATCH_OK crates=2 changed_sources=3 same_online_offline=true lock_unchanged=true")
