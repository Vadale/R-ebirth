#!/usr/bin/env python3
"""Bind the same-runner encoder oracle to verified bytes (D-026 maintenance C).

Python's hashlib supplies SHA256. The consumer hashes one immutable snapshot
and sends that same object to the exact Rust comparator over stdin, never a
reference pathname. This is provenance/integrity evidence, not a signature.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys


ENCODER_TEST = "encoder_output_matches_the_unpatched_reference_within_atol"
CONSUMED_MARKER = "VISION_REFERENCE_CONSUMED"
SUCCESS_MARKER = "VISION_REFERENCE_COMPARISON_PASSED"
ROOT = Path(__file__).resolve().parents[4]


class EvidenceError(ValueError):
    """Required provenance or the snapshot does not match independent inputs."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def file_identity(path: Path) -> dict:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return {"sha256": digest.hexdigest(), "bytes": size}


def dimensions(snapshot: bytes) -> list[int]:
    lines = snapshot.decode("ascii").splitlines()
    require(bool(lines), "empty reference")
    header = lines[0].split()
    require(len(header) == 2, "reference header must contain exactly two dimensions")
    dims = [int(value) for value in header]
    require(all(value > 0 for value in dims), "nonpositive reference dimension")
    require(len(lines) - 1 == dims[0] * dims[1], "reference value count disagrees with dimensions")
    for line in lines[1:]:
        value = float(line)
        require(math.isfinite(value) and abs(value) <= 3.4028234663852886e38,
                "reference contains a nonfinite or out-of-f32-range value")
    return dims


def identities(paths: dict[str, Path], pins: dict[str, str]) -> dict:
    result = {name: file_identity(path) for name, path in sorted(paths.items())}
    for name, expected in pins.items():
        require(re.fullmatch(r"[0-9a-f]{64}", expected) is not None, f"invalid independent {name} pin")
        require(result[name]["sha256"] == expected, f"independent {name} SHA256 mismatch")
    return result


def make_manifest(snapshot: bytes, context: dict, artifacts: dict, expected_dims: list[int],
                  build: dict) -> dict:
    dims = dimensions(snapshot)
    require(dims == expected_dims, "producer dimensions disagree with independent expected dimensions")
    return {
        "schema": 1,
        "context": context,
        "artifacts": artifacts,
        "build": build,
        "reference": {"sha256": sha256(snapshot), "bytes": len(snapshot), "dimensions": dims},
    }


@dataclass(frozen=True)
class VerifiedReference:
    snapshot: bytes
    digest: str
    dims: tuple[int, int]
    context: dict

    def marker(self) -> str:
        return (f"{CONSUMED_MARKER} sha256={self.digest} bytes={len(self.snapshot)} "
                f"tokens={self.dims[0]} embedding={self.dims[1]}")


def verify_snapshot(snapshot: bytes, manifest: dict, context: dict, artifacts: dict,
                    expected_dims: list[int], build: dict) -> VerifiedReference:
    # Reconstruct every required field from independent job state/current files;
    # neither a path nor a digest echoed by the caller establishes verification.
    expected = make_manifest(snapshot, context, artifacts, expected_dims, build)
    require(manifest == expected, "manifest does not match snapshot, inputs, build or current job identity")
    return VerifiedReference(snapshot, expected["reference"]["sha256"], tuple(expected_dims), context)


def load_verified(reference: Path, manifest_path: Path, context: dict, artifacts: dict,
                  expected_dims: list[int], build: dict) -> VerifiedReference:
    # Exactly one reference read. A later replacement at this pathname cannot
    # change the bytes passed to the comparator.
    snapshot = reference.read_bytes()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    return verify_snapshot(snapshot, manifest, context, artifacts, expected_dims, build)


def run_comparator(verified: VerifiedReference, command: list[str]) -> None:
    # Protect the handoff itself too: substituting an object after verification
    # must fail before the comparator or any numerical-success receipt runs.
    require(sha256(verified.snapshot) == verified.digest, "substituted verified snapshot")
    require(dimensions(verified.snapshot) == list(verified.dims), "substituted snapshot dimensions")
    env = os.environ.copy()
    env.update({
        "RELM_REQUIRE_VISION_REFERENCE": "1",
        "RELM_VISION_REFERENCE_STDIN": "1",
        "RELM_VISION_REFERENCE_SHA256": verified.digest,
        "RELM_VISION_REFERENCE_BYTES": str(len(verified.snapshot)),
        "RELM_VISION_REFERENCE_TOKENS": str(verified.dims[0]),
        "RELM_VISION_REFERENCE_EMBEDDING": str(verified.dims[1]),
    })
    result = subprocess.run(command, input=verified.snapshot, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env=env, check=False)
    output = result.stdout.decode("utf-8", errors="replace")
    sys.stdout.write(output)
    require(result.returncode == 0, f"encoder comparator exited {result.returncode}")
    require(output.splitlines().count(verified.marker()) == 1,
            "exact comparator did not emit its digest-bearing numerical-success marker")
    context = verified.context
    print(f"{SUCCESS_MARKER} sha256={verified.digest} nonce={context['job_nonce']} "
          f"source={context['source_sha']} run={context['run_id']} "
          f"attempt={context['run_attempt']} job={context['job']}")


def required_env(name: str) -> str:
    value = os.environ.get(name, "")
    require(bool(value), f"required environment field {name} is missing")
    return value


def job_context() -> dict:
    names = {
        "source_sha": "GITHUB_SHA", "repository": "GITHUB_REPOSITORY",
        "run_id": "GITHUB_RUN_ID", "run_attempt": "GITHUB_RUN_ATTEMPT",
        "job": "GITHUB_JOB", "workflow_ref": "GITHUB_WORKFLOW_REF",
        "workflow_sha": "GITHUB_WORKFLOW_SHA", "runner_name": "RUNNER_NAME",
        "runner_os": "RUNNER_OS", "runner_arch": "RUNNER_ARCH",
        "job_nonce": "RELM_VISION_JOB_NONCE",
    }
    context = {key: required_env(name) for key, name in names.items()}
    require(re.fullmatch(r"[0-9a-f]{64}", context["job_nonce"]) is not None,
            "job nonce must be a fresh 256-bit hexadecimal value")
    require(context["run_attempt"].isdigit() and int(context["run_attempt"]) > 0,
            "invalid independent run attempt")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(head == context["source_sha"], "checkout HEAD does not match independent CI source SHA")
    context["platform"] = {
        "system": platform.system(), "release": platform.release(),
        "machine": platform.machine(), "node": platform.node(),
        "python": platform.python_version(),
    }
    return context


def configuration() -> tuple:
    context = job_context()
    build_dir = Path(required_env("RELM_VISION_BUILD_DIR"))
    paths = {
        "upstream_archive": Path(required_env("RELM_VISION_UPSTREAM_ARCHIVE")),
        "model": Path(required_env("RELM_TEST_MODEL_VLM")),
        "projector": Path(required_env("RELM_TEST_MMPROJ_VLM")),
        "image": ROOT / "tests/vision/red-square.png",
        "producer_source": Path(__file__).with_name("dump-encode.c"),
        "producer_binary": Path(required_env("RELM_VISION_PRODUCER_BINARY")),
        "manifest_tool": Path(__file__),
        "comparator_source": ROOT / "rebirth/src/rust/rebirth-llm/tests/vlm_golden.rs",
        "cmake_cache": build_dir / "CMakeCache.txt",
        "build_info": Path(required_env("RELM_VISION_BUILD_INFO")),
    }
    # dump-encode dynamically links these native artifacts; executable hashing
    # alone would omit the implementation that actually produced the values.
    libraries = sorted(path for path in (build_dir / "bin").glob("lib*")
                       if path.is_file() and (".so" in path.name or path.suffix == ".dylib"))
    require(bool(libraries), "pristine shared-library build artifacts are missing")
    paths.update({f"library/{path.name}": path for path in libraries})
    pins = {
        "upstream_archive": required_env("TARBALL_SHA256"),
        "model": required_env("MODEL_SHA256"),
        "projector": required_env("MMPROJ_SHA256"),
        "image": "0f0791f704392f0ad330857b782c65ae8369b9d44d98e6fe2b6d1eb58c914db4",
    }
    build = json.loads(paths["build_info"].read_text(encoding="utf-8"))
    require(build.get("upstream_tag") == required_env("RELM_VISION_UPSTREAM_TAG"),
            "build configuration upstream tag mismatch")
    require(all(build.get(field) for field in ("configure", "producer_compile", "cc", "cxx", "cmake")),
            "build configuration/versions are incomplete")
    artifacts = identities(paths, pins)
    return (Path(required_env("RELM_VISION_ENCODER_REFERENCE")),
            Path(required_env("RELM_VISION_REFERENCE_MANIFEST")), context, artifacts,
            [64, 1536], build)


def exact_test_binary(artifacts_path: Path) -> str:
    paths = []
    for line in artifacts_path.read_text(encoding="utf-8").splitlines():
        item = json.loads(line)
        if (item.get("reason") == "compiler-artifact" and item.get("executable")
                and item.get("target", {}).get("name") == "vlm_golden"
                and item.get("profile", {}).get("test") is True):
            paths.append(item["executable"])
    require(len(paths) == 1, "expected exactly one built vlm_golden test binary")
    require(Path(paths[0]).is_file(), "built encoder comparator is missing")
    return paths[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "compare"))
    parser.add_argument("--cargo-artifacts", type=Path)
    args = parser.parse_args()
    reference, manifest_path, context, artifacts, dims, build = configuration()
    if args.action == "create":
        manifest = make_manifest(reference.read_bytes(), context, artifacts, dims, build)
        # A nonce identifies one producer handoff; accidental reuse is an error.
        with manifest_path.open("x", encoding="utf-8") as stream:
            json.dump(manifest, stream, indent=2, sort_keys=True)
            stream.write("\n")
        print(f"VISION_REFERENCE_MANIFEST_CREATED sha256={manifest['reference']['sha256']}")
    else:
        require(args.cargo_artifacts is not None, "compare requires --cargo-artifacts")
        verified = load_verified(reference, manifest_path, context, artifacts, dims, build)
        command = [exact_test_binary(args.cargo_artifacts), "--exact", ENCODER_TEST, "--nocapture"]
        run_comparator(verified, command)


if __name__ == "__main__":
    try:
        main()
    except (EvidenceError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"VISION_REFERENCE_REJECTED: {error}", file=sys.stderr)
        sys.exit(1)
