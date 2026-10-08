#!/usr/bin/env python3
"""F6e-only Linux memory acceptance; standard library, no source/runtime edits.

Reuse the established sanitizer command/runtime/native-object auditors unchanged.
Only the two frozen default-production tests below may build and execute. This
file is also the strict raw-receipt collector used by instrumented_controls.py.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("relm_existing_sanitizers", ROOT / "tests/sanitizers/run.py")
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)
require, digest = BASE.require, BASE.digest
MARKER = "F6E_PROJECTION_PRODUCTION_TEST "
CASES = {
    "projection_production": {
        "id": "default_constructor_routes_and_owned_lifecycle",
        "source": "rebirth/src/rust/rebirth-llm/tests/projection_production.rs",
        "cases": 13, "refusals": 9, "values": 288, "constructors": 2, "cfg_test": False,
    },
    "rebirth_llm": {
        "id": "async_job::tests::projection_static_live_restore_cancel_and_poison",
        "source": "rebirth/src/rust/rebirth-llm/src/projection_production_worker_tests.rs",
        "cases": 10, "refusals": 2, "values": 3, "constructors": 1, "cfg_test": True,
    },
}
FUNCTIONS = ("relm_projection_classify", "relm_projection_row", "relm_projection_consumer")
FIXTURE = "tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"
FIXTURE_SHA256 = "e255ed5db07f318cbc3bd1d4d5a5a261bdef0867b3bbd1e26228f015b872bd05"
FEATURES = ["default", "spill"]


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result
    def nonfinite(value):
        raise RuntimeError(f"nonfinite JSON constant: {value}")
    return json.loads(text, object_pairs_hook=pairs, parse_constant=nonfinite)


def expected_marker(case):
    return {"test": case["id"].split("::")[-1], "status": "passed",
            "expected_cases": case["cases"], "executed_cases": case["cases"],
            "expected_rejections": case["refusals"], "rejected_cases": case["refusals"],
            "expected_values": case["values"], "compared_values": case["values"],
            "model_loads": 1, "constructor_calls": case["constructors"],
            "library_cfg_test": case["cfg_test"], "private_feature": False}


def collect_test(output, errors, binary):
    require(binary in CASES, "unselected test binary")
    case = CASES[binary]
    BASE.check_test_events(output, case["id"])
    events = [strict_json(line) for line in output.splitlines() if line.strip()]
    captured = events[2].get("stdout")
    require(isinstance(captured, str), "missing named libtest captured stdout")
    require(not BASE.FINDING.search(output + errors + captured), "sanitizer finding in test output")
    lines = [line for line in captured.splitlines() if line.startswith(MARKER)]
    require(len(lines) == 1 and captured.count(MARKER) == 1, "missing/duplicate/misplaced production marker")
    record = strict_json(lines[0][len(MARKER):])
    expected = expected_marker(case)
    require(isinstance(record, dict) and set(record) == set(expected), "production marker field set differs")
    for key, value in expected.items():
        require(type(record[key]) is type(value) and record[key] == value,
                f"production marker mismatch: {key}")
    return record


def collect_artifacts(output, target):
    events = BASE.cargo_build_events(output)
    artifacts, libraries = {}, []
    for event in events:
        if event.get("reason") != "compiler-artifact":
            continue
        name = event.get("target", {}).get("name")
        if name not in CASES:
            require(not event.get("executable"), "unselected executable artifact")
            continue
        require(sorted(event.get("features", [])) == FEATURES, "not exact default spill features")
        executable = event.get("executable")
        if executable:
            require(event["profile"].get("test") is True, "selected executable is not a test")
            require(name not in artifacts, "duplicate test executable")
            artifacts[name] = Path(executable)
        elif name == "rebirth_llm":
            require(event["profile"].get("test") is False and event["target"].get("kind") == ["lib"],
                    "production library must have profile.test=false")
            paths = [Path(p) for p in event.get("filenames", []) if p.endswith(".rlib")]
            require(len(paths) == 1, "missing/ambiguous production rlib")
            libraries.extend(paths)
    require(set(artifacts) == set(CASES) and len(libraries) == 1, "missing production library or selected test")
    debug = target / BASE.TARGET / "debug"
    for path in [*artifacts.values(), *libraries]:
        require(path.is_absolute() and path.parent in (debug, debug / "deps"), "artifact outside fresh target")
    return artifacts, libraries[0]


def collect_valgrind(text, binary, expected_fault=None):
    doc = ET.fromstring(text)
    require(doc.tag == "valgrindoutput" and doc.findtext("protocoltool") == "memcheck",
            "missing actual Memcheck XML protocol")
    require(doc.findtext("protocolversion") == "4", "unexpected Memcheck protocol")
    states = [item.findtext("state") for item in doc.findall("status")]
    require(states == ["RUNNING", "FINISHED"], "Memcheck did not finish exactly once")
    require(doc.findtext("args/argv/exe") == str(binary), "Memcheck ran a different binary")
    kinds = [item.findtext("kind") for item in doc.findall("error")]
    if expected_fault is None:
        require(not kinds and not doc.findall("errorcounts/pair"), "Memcheck finding")
    else:
        require(expected_fault in kinds, "fault control lacks expected Memcheck finding")
    require(not doc.findall("suppcounts/pair"), "unexpected applied suppression")
    return {"tool": "memcheck", "protocol": 4, "states": states, "error_kinds": kinds}


def verify_sources(root, manifest):
    require(manifest.get("schema") == 1 and manifest.get("fixture_sha256") == FIXTURE_SHA256,
            "wrong instrumented scope schema/fixture")
    sources = manifest.get("source_hashes")
    require(isinstance(sources, dict) and bool(sources), "empty source freeze")
    required = {case["source"] for case in CASES.values()} | {
        "rebirth/src/rust/rebirth-llm/native/projection.cpp", "tests/sanitizers/run.py", FIXTURE,
        "tests/projection/instrumented.py", "tests/projection/instrumented_controls.py",
        "tests/projection/instrumented_memcheck_probe.c"}
    require(required <= set(sources), "incomplete instrumented source freeze")
    for name, expected in sources.items():
        path = Path(name)
        require(not path.is_absolute() and ".." not in path.parts, "invalid source path")
        require(digest(root / path) == expected, f"source drift: {name}")
    require(digest(root / FIXTURE) == FIXTURE_SHA256, "tiny fixture drift")


def build_command(mode):
    command = ["cargo", "test", "--locked", "-p", "rebirth-llm", "--target", BASE.TARGET,
               "--no-run", "--lib", "--test", "projection_production", "--message-format=json", "-vv"]
    if mode == "sanitizers":
        command += ["-Zbuild-std"]
    return command


class ProjectionRun(BASE.Run):
    def __init__(self, evidence, target, mode, manifest_path):
        super().__init__(ROOT, evidence, target)
        self.mode, self.selection = mode, "projection-only"
        self.cases = {binary: [case["id"]] for binary, case in CASES.items()}
        self.manifest_path = manifest_path
        self.manifest_sha256 = digest(manifest_path)
        self.manifest = strict_json(manifest_path.read_text())
        self.env["OMP_NUM_THREADS"] = "1"
        # No environment wrapper can change which process the receipt names.
        self.env.pop("VALGRIND_OPTS", None)
        self.env.pop("RUSTC_BOOTSTRAP", None)
        if mode == "valgrind":
            for key in ("RELM_NATIVE_SANITIZERS", "ASAN_OPTIONS", "UBSAN_OPTIONS", "ASAN_SYMBOLIZER_PATH"):
                self.env.pop(key, None)
            self.env["CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS"] = "-Cforce-frame-pointers=yes -Cdebuginfo=2"
            self.env["CFLAGS"] = "-g"
            self.env["CXXFLAGS"] = "-g"

    def save(self, name, value):
        (self.evidence / name).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")

    def preflight(self):
        verify_sources(self.root, self.manifest)
        require(sys.platform == "linux" and os.uname().machine == "x86_64", "Linux x86_64 required")
        require(not self.target.exists(), "target must be a fresh nonexistent path")
        self.target.mkdir(parents=True)
        _, rust, _ = self.command(["rustc", "-vV"], "rust-version")
        require("LLVM version: 19." in rust, "pinned Rust must use LLVM19")
        for compiler in ("clang-19", "clang++-19"):
            _, version, _ = self.command([compiler, "--version"], compiler + "-version")
            require(f"clang version {BASE.CLANG_VERSION}" in version, "unexpected Clang version")
        for tool in ("cargo", "cmake", "llvm-nm-19", "llvm-objdump-19"):
            self.command([tool, "--version"], tool + "-version")
        self.command(["uname", "-a"], "platform")
        self.command(["dpkg-query", "-W", "clang-19", "llvm-19", "libclang-rt-19-dev"], "packages")
        _, head, _ = self.command(["git", "rev-parse", "HEAD"], "source-head", cwd=self.root)
        self.save("provenance.json", {"source_commit": head.strip(), "mode": self.mode,
                  "selection": self.selection, "source_manifest_sha256": digest(self.manifest_path),
                  "scope": self.manifest, "selected_tests": self.cases,
                  "controlled_environment": {k: self.env[k] for k in (
                      "RUSTUP_TOOLCHAIN", "CC", "CXX", "CARGO_TARGET_DIR", "CARGO_INCREMENTAL",
                      "CARGO_BUILD_JOBS", "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS",
                      "RELM_NATIVE_SANITIZERS", "SOURCE_DATE_EPOCH", "ASAN_OPTIONS", "UBSAN_OPTIONS",
                      "CCACHE_DISABLE", "SCCACHE_DISABLE", "CFLAGS", "CXXFLAGS") if k in self.env},
                  "ci": {k: os.environ.get(k) for k in ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB")}})
        for case in CASES.values():
            BASE.check_unconditional_source((self.root / case["source"]).read_text(), case["id"])
        if self.mode == "sanitizers":
            _, resource, _ = self.command(["clang-19", "--print-resource-dir"], "clang-resource-dir")
            runtimes = sorted((Path(resource.strip()) / "lib/linux").glob("*san*x86_64*"))
            require(any("asan" in path.name for path in runtimes), "missing compiler ASan runtime")
            self.save("runtime-digests.json", {str(p): digest(p) for p in runtimes if p.is_file()})
            self.probes()  # Existing safe, Rust/C/C++ faults, plain-control refusal.
        else:
            self.valgrind_probes()

    def valgrind_args(self, binary, label, arguments):
        return ["valgrind", "--tool=memcheck", "--error-exitcode=1", "--leak-check=full",
                "--errors-for-leak-kinds=definite,indirect", "--show-leak-kinds=definite,indirect",
                "--track-origins=yes", "--gen-suppressions=all", "--xml=yes",
                f"--xml-file={self.evidence / (label + '.xml')}",
                f"--suppressions={self.root / 'tests/valgrind/relm.supp'}", binary, *arguments]

    def valgrind_probes(self):
        self.command(["valgrind", "--version"], "valgrind-version")
        self.command(["dpkg-query", "-W", "valgrind"], "valgrind-package")
        binary = self.evidence / "memcheck-probe"
        self.command(["clang-19", "-O0", "-g", self.root / "tests/projection/instrumented_memcheck_probe.c",
                      "-o", binary], "memcheck-probe-build")
        for mode, fault in (("safe", None), ("invalid-write", "InvalidWrite"), ("leak", "Leak_DefinitelyLost")):
            label = "memcheck-control-" + mode
            status, _, _ = self.command(self.valgrind_args(binary, label, [mode]), label, check=False)
            require(status == (0 if fault is None else 1), "incorrect Memcheck control exit")
            collect_valgrind((self.evidence / (label + ".xml")).read_text(), binary, fault)
        self.save("memcheck-controls.json", {"safe": True, "invalid_write_refused": True,
                                             "definite_leak_refused": True, "probe_sha256": digest(binary)})

    def build(self):
        _, output, _ = self.command(build_command(self.mode), "build", timeout=4200)
        artifacts, library = collect_artifacts(output, self.target)
        require(all(p.is_file() for p in [*artifacts.values(), library]), "declared artifact missing")
        self.save("library-artifact.json", {"archive": str(library), "sha256": digest(library),
                                           "profile_test": False, "features": FEATURES})
        if self.mode == "sanitizers":
            self.audit_objects()  # Unchanged both-database/all-native-object checks.
            self.audit_projection()
            self.audit_rust(output, library)
        else:
            self.audit_baseline()
        self.save("binary-artifacts.json", {name: {"path": str(path), "sha256": digest(path)}
                                             for name, path in artifacts.items()})
        return artifacts

    def audit_projection(self):
        records = strict_json((self.evidence / "native-objects.json").read_text())
        rows = [r for r in records if Path(r["source"]).resolve() ==
                self.root / "rebirth/src/rust/rebirth-llm/native/projection.cpp"]
        require(len(rows) == 1 and rows[0]["asan"] is True and rows[0]["ubsan"] is True,
                "actual projection.cpp object lacks both sanitizers")
        _, asm, _ = self.command(["llvm-objdump-19", "-dr", "--demangle", rows[0]["object"]],
                                 "projection-disassembly")
        parts = re.split(r"(?m)^[0-9a-f]+ <", asm)
        for function in FUNCTIONS:
            found = [part for part in parts if part.startswith(function + ">:")]
            require(len(found) == 1 and "__asan_" in found[0] and "__ubsan_" in found[0],
                    f"compiled projection access function lacks ASan/UBSan: {function}")
        self.save("projection-object.json", {**rows[0], "functions": list(FUNCTIONS),
                                             "disassembly_sha256": digest(self.evidence / "projection-disassembly.out")})

    def audit_rust(self, output, library):
        log = (self.evidence / "build.err").read_text()
        records = []
        for crate, archives in BASE.rust_archive_artifacts({"build": output}).items():
            lines = [line for line in log.splitlines() if re.search(r"--crate-name " + crate + r"\s", line)
                     and "--target x86_64-unknown-linux-gnu" in line]
            require(lines and all("-Zsanitizer=address" in line and "-Zexternal-clangrt" in line for line in lines),
                    f"missing actual Rust ASan command for {crate}")
            for index, (archive, stages) in enumerate(archives.items()):
                require(archive.is_file() and archive.parent in (self.target / BASE.TARGET / "debug",
                        self.target / BASE.TARGET / "debug/deps"),
                        "Rust archive missing or outside target deps")
                if crate == "rebirth_llm":
                    require(archive == library, "production library differs from audited archive")
                label = f"rust-object-{crate}-{index}"
                _, symbols, _ = self.command(["llvm-nm-19", "--undefined-only", archive], label)
                require("__asan_" in symbols, "compiled Rust archive lacks ASan references")
                records.append({"crate": crate, "archive": str(archive), "sha256": digest(archive),
                                "cargo_stages": stages, "symbols_file": label + ".out"})
        self.save("rust-objects.json", records)

    def audit_baseline(self):
        caches = []
        for path in self.target.rglob("CMakeCache.txt"):
            text = path.read_text()
            if "GGML_NATIVE:BOOL=" not in text:
                continue
            for flag in ("GGML_NATIVE", "GGML_AVX", "GGML_AVX2", "GGML_AVX512", "GGML_CUDA", "GGML_METAL"):
                require(re.search(r"(?m)^" + flag + r":BOOL=OFF$", text), f"Memcheck nonbaseline engine: {flag}")
            caches.append({"path": str(path), "sha256": digest(path)})
        require(len(caches) == 1, "missing/duplicate baseline engine CMake cache")
        self.save("baseline-native.json", caches)

    def execute(self, artifacts):
        receipts = []
        for name in CASES:  # Fixed ordering; one execution per exact test.
            binary, case = artifacts[name], CASES[name]
            _, symbols, _ = self.command(["llvm-nm-19", "--defined-only", binary], f"binary-{name}-symbols")
            self.command(["ldd", binary], f"binary-{name}-linkage")
            for function in FUNCTIONS:
                require(re.search(r"\b[TtWw] " + function + r"$", symbols, re.M),
                        f"projection access function absent from actual binary: {function}")
            if self.mode == "sanitizers":
                BASE.check_runtime_symbols(symbols)
            else:
                require(not re.search(r"\b[TtWw] __(?:asan|ubsan)_", symbols), "Memcheck cannot run sanitizer binary")
            label = BASE.test_log_label(case["id"])
            argv = ["--exact", case["id"], "--test-threads=1", "--format=json", "-Zunstable-options", "--show-output"]
            command = [binary, *argv] if self.mode == "sanitizers" else self.valgrind_args(binary, label, argv)
            _, out, err = self.command(command, label, timeout=600 if self.mode == "valgrind" else 180)
            marker = collect_test(out, err, name)
            memory = None
            if self.mode == "valgrind":
                memory = collect_valgrind((self.evidence / (label + ".xml")).read_text(), binary)
            receipts.append({"selection": self.selection, "mode": self.mode, "binary": name,
                             "test": case["id"], "source_file": case["source"],
                             "source_sha256": digest(self.root / case["source"]),
                             "binary_sha256": digest(binary), "production_marker": marker, "memcheck": memory,
                             "stdout_file": label + ".out", "stderr_file": label + ".err",
                             "stdout_sha256": digest(self.evidence / (label + ".out")),
                             "stderr_sha256": digest(self.evidence / (label + ".err")), "status": "executed_ok"})
            self.save("executed-tests.json", receipts)
        require(len(receipts) == 2, "incomplete projection acceptance")
        verify_sources(self.root, self.manifest)
        require(digest(self.manifest_path) == self.manifest_sha256, "source manifest changed during run")
        summary = {"status": "passed", "mode": self.mode, "selection": self.selection,
                   "executed_tests": 2, "executed_cases": 23, "rejected_cases": 11, "compared_values": 291,
                   "reported_model_loads": 2, "reported_constructor_calls": 3,
                   "default_features": FEATURES, "source_manifest_sha256": digest(self.manifest_path)}
        self.save("projection-summary.json", summary)
        self.save("artifact-sha256.json", {str(p.relative_to(self.evidence)): digest(p)
                  for p in sorted(self.evidence.rglob("*")) if p.is_file()})
        (self.evidence / "SUCCESS.txt").write_text("F6e projection-only CPU memory checks passed.\n"
            "No R/SEXP, GPU, ThreadSanitizer, new numerical accuracy or performance claim.\n")
        print("F6E_PROJECTION_INSTRUMENTED " + json.dumps(summary, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("sanitizers", "valgrind"), required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path,
                        default=Path(__file__).with_name("instrumented-scope.json"))
    args = parser.parse_args()
    require(not args.evidence.exists(), "evidence directory must be new; retain every prior failure")
    args.evidence.mkdir(parents=True)
    runner = ProjectionRun(args.evidence.resolve(), args.target.resolve(), args.mode, args.source_manifest.resolve())
    try:
        runner.preflight()
        runner.execute(runner.build())
    except Exception as error:
        (runner.evidence / "FAILURE.txt").write_text(f"{type(error).__name__}: {error}\n")
        raise


if __name__ == "__main__":
    main()
