#!/usr/bin/env python3
"""Prepare/check source-only distribution bundles; maintainer tool, not install code.

First run cargo vendor --locked --versioned-dirs in a separate directory. This
command never downloads, compiles or updates Cargo.lock. The installed package
uses R's untar and Cargo, without a Python/Git dependency.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "rebirth"
LOCK = PACKAGE / "src/rust/Cargo.lock"
MANIFEST = PACKAGE / "tools/bundled-sources.json"
WASM_OMISSIONS = {
    "src/rt/libwit_bindgen_cabi.a": "a18a4de12821dd777e6003625cc33896984a91a55bbf03c70abc5675842c60c1",
    "src/rt/wit_bindgen_cabi_realloc.o": "f5bef0033f3baaada79949e9c8e506d1de1722259c24dc752d2084784317f8de",
    "src/rt/wit_bindgen_cabi_wasip3.o": "76a7b6bf1529c2657f0e7620a443db23294647b009916df1b3b55646879ef61a",
    "wasi-cli@0.2.0.wasm": "60b274319c9dce183269a0e3ad922b8ee4ead915f34d171de9da23a390863119",
}
WASM_CRATE = "wit-bindgen-0.57.1"
COMPILED_MAGIC = (b"\x7fELF", b"!<arch>\n", b"\x00asm", b"MZ", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_crate(directory, checksum):
    record = json.loads((directory / ".cargo-checksum.json").read_text())
    if record["package"] != checksum:
        raise ValueError(f"Cargo package checksum differs: {directory.name}")
    for name, expected in record["files"].items():
        path = directory / name
        if path.is_symlink() or not path.is_file() or sha(path.read_bytes()) != expected:
            raise ValueError(f"Cargo file checksum differs: {path}")


def write_archive(destination, source, prefix, files, overrides=None):
    overrides = overrides or {}
    records = {}
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    try:
        with tarfile.open(temporary, "w:xz", format=tarfile.USTAR_FORMAT, preset=6) as archive:
            for path in sorted(files):
                if path.is_symlink() or not path.is_file():
                    raise ValueError(f"Only regular source files may be bundled: {path}")
                relative = path.relative_to(source).as_posix()
                data = overrides.get(relative, path.read_bytes())
                if data.startswith(COMPILED_MAGIC):
                    raise ValueError(f"Compiled artifact in source bundle: {relative}")
                member = tarfile.TarInfo(f"{prefix}/{relative}")
                member.size = len(data)
                member.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                archive.addfile(member, io.BytesIO(data))
                records[member.name] = sha(data)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return records


def engine_files():
    prefix = "rebirth/src/llama.cpp/"
    names = subprocess.check_output(["git", "ls-files", "-z", "--", prefix], cwd=ROOT).decode().split("\0")
    return [ROOT / name for name in names if name]


def check():
    record = json.loads(MANIFEST.read_text())
    assert sha(LOCK.read_bytes()) == record["cargo_lock_sha256"], "Cargo.lock changed; regenerate sources"
    for name, bundle in record["bundles"].items():
        path = PACKAGE / name
        assert sha(path.read_bytes()) == bundle["sha256"], f"Bundle changed: {name}"
        with tarfile.open(path) as archive:
            members = archive.getmembers()
            assert all(m.isfile() and not m.name.startswith("/") and ".." not in Path(m.name).parts for m in members)
            actual = {m.name: sha(archive.extractfile(m).read()) for m in members}
            assert len(actual) == len(members), "Duplicate archive member"
            assert actual == bundle["files"], f"Bundle inventory changed: {name}"
    engine = PACKAGE / "src/llama.cpp"
    current = {"llama.cpp/" + p.relative_to(engine).as_posix(): sha(p.read_bytes()) for p in engine_files()}
    assert current == record["bundles"]["src/llama-sources.tar.xz"]["files"], "Engine bundle is stale"
    for name, expected in record["generated_files"].items():
        assert sha((PACKAGE / name).read_bytes()) == expected, f"Generated file changed: {name}"
    print(f"CRAN_SOURCES_OK engine={len(current)} crates={record['crate_count']} lock_unchanged=true")


def prepare(vendor):
    packages = [p for p in tomllib.loads(LOCK.read_text())["package"] if "source" in p]
    assert all(p["source"].startswith("registry+") for p in packages), "Review non-registry source before bundling"
    expected = {p["name"] + "-" + p["version"] for p in packages}
    assert {p.name for p in vendor.iterdir()} == expected, "Vendor inventory differs from Cargo.lock"
    authors = ["relm bundled source authorship and licenses", "", "Original relm: Alessandro Vadala; MIT OR Apache-2.0.",
               "llama.cpp and native dependencies: see THIRD-PARTY-NOTICES and", "src/llama-sources.tar.xz, including upstream LICENSE and retained notices.",
               "", "Rust dependencies below are the existing Cargo.lock graph. Original license", "texts and copyright notices are retained inside src/rust/vendor.tar.xz.", ""]
    for package in sorted(packages, key=lambda p: (p["name"], p["version"])):
        directory = vendor / (package["name"] + "-" + package["version"])
        verify_crate(directory, package["checksum"])
        metadata = tomllib.loads((directory / "Cargo.toml").read_text())["package"]
        authors.extend([directory.name, "  Authors: " + "; ".join(metadata.get("authors", ["See the retained upstream source and license notices"])),
                        "  License: " + metadata.get("license", metadata.get("license-file", "See upstream notices")), ""])
    # Omit four exact wasm-only compiled assets; retain every source/license.
    # Upstream build.rs returns before accessing these files on native targets.
    # Cargo's package checksum stays pinned; record the file-inventory delta.
    checksum_path = WASM_CRATE + "/.cargo-checksum.json"
    checksums = json.loads((vendor / checksum_path).read_text())
    omissions = []
    for name, expected_sha in WASM_OMISSIONS.items():
        relative = WASM_CRATE + "/" + name
        assert sha((vendor / relative).read_bytes()) == expected_sha, "Unreviewed wasm artifact"
        assert checksums["files"].pop(name) == expected_sha
        omissions.append(dict(path=relative, sha256=expected_sha, reason="Unsupported wasm-only compiled asset; native source unchanged"))
    overrides = {checksum_path: (json.dumps(checksums, sort_keys=True, separators=(",", ":")) + "\n").encode()}
    omitted = {x["path"] for x in omissions}
    files = [p for p in vendor.rglob("*") if p.is_file() and p.relative_to(vendor).as_posix() not in omitted]
    engine = PACKAGE / "src/llama.cpp"
    archives = [("src/llama-sources.tar.xz", engine, "llama.cpp", engine_files(), {}),
                ("src/rust/vendor.tar.xz", vendor, "vendor", files, overrides)]
    bundles = {}
    for name, source, prefix, members, replacements in archives:
        destination = PACKAGE / name
        inventory = write_archive(destination, source, prefix, members, replacements)
        bundles[name] = dict(sha256=sha(destination.read_bytes()), bytes=destination.stat().st_size, files=inventory)
    config = '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n'
    (PACKAGE / "src/rust/vendor-config.toml").write_text(config)
    (PACKAGE / "inst/AUTHORS").write_text("\n".join(authors))
    generated = {name: sha((PACKAGE / name).read_bytes()) for name in ("src/rust/vendor-config.toml", "inst/AUTHORS")}
    record = dict(schema=1, cargo_lock_sha256=sha(LOCK.read_bytes()), crate_count=len(packages), bundles=bundles,
                  generated_files=generated, omitted_compiled_artifacts=omissions)
    MANIFEST.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    check()
    print(json.dumps({name: {k: v for k, v in data.items() if k != "files"} for name, data in bundles.items()}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor-dir", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        check()
    elif args.vendor_dir:
        prepare(args.vendor_dir.resolve())
    else:
        parser.error("provide --vendor-dir or --check")
