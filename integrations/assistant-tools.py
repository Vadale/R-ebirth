#!/usr/bin/env python3
"""Install, verify and bundle the statistical skill without changing client config.

Python standard library only. Install/bundle require an explicit new destination
whose parent already exists. Doctor inspects an existing R installation only.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import zipfile


INTEGRATIONS = Path(__file__).resolve().parent
SKILL_NAME = "r-statistical-analysis"
SKILL_SOURCE = INTEGRATIONS / "skills" / SKILL_NAME
PLUGIN_MANIFEST = INTEGRATIONS / "plugin.json"
RECEIPT_NAME = ".installation-receipt.json"
# Release boundary: a new payload file requires an intentional packaging change.
PAYLOAD_FILES = (
    "LICENSE-APACHE", "LICENSE-MIT", "SKILL.md", "agents/openai.yaml",
    "references/method-routing.md", "references/output-contract.md",
    "references/statistical-checks.md", "scripts/inspect-environment.R",
    "scripts/run-analysis.R",
)
PAYLOAD_DIRS = {str(Path(name).parent) for name in PAYLOAD_FILES} - {"."}


class ToolError(Exception):
    """An actionable local setup or content error."""


def read_tree(root):
    """Read regular files only; never follow a source or installed symlink."""
    files, directories = {}, set()

    def visit(path):
        mode = path.lstat().st_mode
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(mode):
            raise ToolError(f"Symlinks are not allowed: {path}")
        if stat.S_ISDIR(mode):
            if path != root:
                directories.add(relative)
            for child in sorted(path.iterdir()):
                visit(child)
        elif stat.S_ISREG(mode) and path != root:
            files[relative] = path.read_bytes()
        else:
            raise ToolError(f"Expected a directory or regular file: {path}")

    visit(root)
    return files, directories


def source_payload():
    files, directories = read_tree(SKILL_SOURCE)
    missing = sorted(set(PAYLOAD_FILES) - files.keys())
    extra = sorted(files.keys() - set(PAYLOAD_FILES))
    extra_dirs = sorted(directories - PAYLOAD_DIRS)
    if missing or extra or extra_dirs:
        raise ToolError(f"Skill source differs from the release allowlist: "
                        f"missing={missing}, extra={extra}, extra_dirs={extra_dirs}")
    return files


def receipt_for(files):
    hashes = {name: hashlib.sha256(data).hexdigest()
              for name, data in sorted(files.items())}
    canonical = json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode()
    return {"format": 1, "skill": SKILL_NAME, "files": hashes,
            "content_sha256": hashlib.sha256(canonical).hexdigest()}


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def new_destination(path):
    # Do not resolve the leaf: resolve() would hide a dangling destination link.
    path = Path(os.path.abspath(path))
    if os.path.lexists(path):
        raise ToolError(f"Destination already exists; choose a new path: {path}")
    if not path.parent.is_dir():
        raise ToolError(f"Destination parent must already exist: {path.parent}")
    if path.resolve().is_relative_to(SKILL_SOURCE.resolve()):
        raise ToolError("Destination must be outside the skill source directory")
    return path


def remember(created, path, info):
    created.append((path, info.st_dev, info.st_ino))


def write_new(path, data, created):
    with path.open("xb") as stream:
        remember(created, path, os.fstat(stream.fileno()))
        stream.write(data)


def cleanup_created(created):
    # No recursive deletion: preserve any file added/replaced by another actor.
    for path, device, inode in reversed(created):
        try:
            info = path.lstat()
            if (info.st_dev, info.st_ino) == (device, inode):
                if stat.S_ISDIR(info.st_mode):
                    path.rmdir()
                else:
                    path.unlink()
        except OSError:
            pass  # Nonempty or changed directories must remain for inspection.


def install(destination):
    destination = new_destination(destination)
    files = source_payload()
    receipt = receipt_for(files)
    created = []
    try:
        destination.mkdir()
        remember(created, destination, destination.lstat())
        for name in sorted(PAYLOAD_DIRS):
            directory = destination / name
            directory.mkdir()
            remember(created, directory, directory.lstat())
        for name, data in sorted(files.items()):
            write_new(destination / name, data, created)
        write_new(destination / RECEIPT_NAME, json_bytes(receipt), created)
    except BaseException:
        cleanup_created(created)
        raise
    return {"destination": str(destination), **receipt}


def verify(destination):
    expected = source_payload()
    files, directories = read_tree(Path(destination))
    saved = files.pop(RECEIPT_NAME, None)
    missing = sorted(expected.keys() - files.keys())
    extra = sorted(files.keys() - expected.keys())
    changed = sorted(name for name in expected.keys() & files.keys()
                     if files[name] != expected[name])
    extra_dirs = sorted(directories - PAYLOAD_DIRS)
    if missing or extra or changed or extra_dirs:
        raise ToolError(f"Installed content differs from source: missing={missing}, "
                        f"extra={extra}, changed={changed}, extra_dirs={extra_dirs}")
    receipt = receipt_for(expected)
    if saved != json_bytes(receipt):
        raise ToolError("Installation receipt is missing or differs from source; "
                        "install to a new destination to obtain a verified copy")
    return {"verified": True, "destination": str(Path(destination).absolute()),
            **receipt}


def bundle(destination):
    destination = new_destination(destination)
    files = {f"skills/{SKILL_NAME}/{name}": data
             for name, data in source_payload().items()}
    if not stat.S_ISREG(PLUGIN_MANIFEST.lstat().st_mode):
        raise ToolError("Plugin manifest must be a regular file, not a symlink")
    manifest = PLUGIN_MANIFEST.read_bytes()
    if not isinstance(json.loads(manifest), dict):
        raise ToolError("Plugin manifest must be a JSON object")
    files["plugin.json"] = manifest
    buffer = io.BytesIO()
    # Stored entries avoid compressor-version variation for this small payload.
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(entry, data)
    data = buffer.getvalue()
    created = []
    try:
        write_new(destination, data, created)
    except BaseException:
        cleanup_created(created)
        raise
    return {"destination": str(destination), "files": sorted(files),
            "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def doctor(rscript, packages):
    if any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9.]*", name) for name in packages):
        raise ToolError("Provide R package names, not expressions or paths")
    executable = shutil.which(rscript)
    if not executable:
        raise ToolError(f"Rscript executable not found: {rscript}. Install R or "
                        "provide its existing executable with --rscript PATH")
    script = SKILL_SOURCE / "scripts" / "inspect-environment.R"
    try:
        result = subprocess.run([executable, "--vanilla", str(script), *packages],
                                text=True, capture_output=True, timeout=30,
                                check=False)
    except subprocess.TimeoutExpired as error:
        raise ToolError("R environment inspection exceeded 30 seconds; check "
                        "the selected R installation") from error
    print(f"Rscript\t{executable}")
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode:
        raise ToolError(f"R environment inspection failed (exit {result.returncode})")
    missing = [line.split("\t")[0] for line in result.stdout.splitlines()
               if line.endswith("\tmissing")]
    if missing:
        raise ToolError("Requested R packages are missing: " + ", ".join(missing)
                        + ". Choose available packages or install only approved "
                        "requirements in the intended library separately")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command, help_text in (
        ("install", "Copy the skill into a new explicit directory"),
        ("verify", "Compare an installed copy and receipt with this source"),
        ("bundle", "Write a new deterministic skills-only plugin ZIP"),
    ):
        subparser = commands.add_parser(command, help=help_text)
        subparser.add_argument("destination", type=Path)
    subparser = commands.add_parser("doctor", help="Inspect R without installation")
    subparser.add_argument("--rscript", default="Rscript")
    subparser.add_argument("--package", action="append", dest="packages",
                           help="Requested R package; repeat as needed (default: stats, nlme)")
    args = parser.parse_args(argv)
    try:
        if args.command == "doctor":
            doctor(args.rscript, args.packages or ["stats", "nlme"])
        else:
            action = {"install": install, "verify": verify, "bundle": bundle}[args.command]
            print(json.dumps(action(args.destination), indent=2, sort_keys=True))
    except (ToolError, OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
