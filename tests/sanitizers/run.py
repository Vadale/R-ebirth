#!/usr/bin/env python3
"""Download-free Linux native sanitizer acceptance. Python standard library only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

TOOLCHAIN = "nightly-2025-02-01"
TARGET = "x86_64-unknown-linux-gnu"
CLANG_VERSION = "19.1.1"
NATIVE_FLAGS = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                "-fno-omit-frame-pointer", "-O1", "-g"]
RUST_FLAGS = ["-Zsanitizer=address", "-Zexternal-clangrt", "-Cforce-frame-pointers=yes",
              "-Cdebuginfo=2", "-Clinker=clang++-19",
              "-Clink-arg=-fsanitize=address,undefined"]
# All selected functions are unconditional; model cases use the committed fixture.
# No model-gated/vision test is selected. Source guards below fail on skip/return
# additions; libtest JSON must independently report exactly one executed success.
CASES = {
    "synthetic_intervene": ["engine_interventions_match_numpy_oracle_and_are_reversible"],
    "synthetic_trace": ["engine_activations_match_numpy_oracle_within_tolerance"],
    "synthetic_spill": ["over_budget_spills_and_the_file_equals_the_in_memory_capture",
                        "an_existing_spill_file_is_rejected_without_truncation_or_cleanup",
                        "spill_creation_rejects_symlinks_and_preserves_their_targets"],
    "synthetic_generate": ["greedy_generation_matches_numpy_golden",
                           "sampling_is_deterministic_under_a_fixed_seed"],
    "synthetic_embed": ["engine_embeddings_match_numpy_oracle_within_tolerance"],
    "async_synthetic": ["async_synthetic_owned_handoff_preserves_golden_and_sampling"],
    "rebirth_llm": [
        "async_job::tests::async_cancel_busy_and_shutdown_return_ownership",
        "async_job::tests::async_worker_panic_and_error_release_the_domain",
        "async_job::tests::async_synthetic_failure_returns_original_context_and_shared_parent",
        "async_job::tests::async_cancel_real_prefill_sample_and_prompt_boundaries_recover",
        "async_job::tests::stream_full_queue_cancel_discard_and_drain_wake_producer",
        "async_job::tests::stream_shutdown_and_failures_after_backpressure_release_ownership",
    ],
}
WORK_MARKERS = {
    "synthetic_intervene": "intervene engine-vs-oracle max",
    "synthetic_trace": "engine-vs-oracle activations max",
    "synthetic_embed": "engine-vs-oracle embeddings max",
}
FINDING = re.compile(r"ERROR: (?:AddressSanitizer|LeakSanitizer)|"
                     r"SUMMARY: (?:AddressSanitizer|UndefinedBehaviorSanitizer)|runtime error:")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_fault(status, output, marker):
    require(status == 1, f"fault probe did not terminate with the expected sanitizer exit 1: {status}")
    require(marker in output, "fault probe failed without its sanitizer diagnostic")


def check_runtime_symbols(output):
    for symbol in ("__asan_init", "__ubsan_handle_add_overflow_abort"):
        require(re.search(r"\b[TtWw] " + symbol + r"$", output, re.M),
                f"binary lacks a defined runtime symbol: {symbol}")


def check_test_events(output, name):
    events = [json.loads(line) for line in output.splitlines() if line.strip()]
    tests = [(item.get("name"), item.get("event")) for item in events
             if item.get("type") == "test"]
    require(tests == [(name, "started"), (name, "ok")],
            f"missing, skipped, failed, duplicate or wrong executed test: {name}: {tests}")
    suites = [item for item in events if item.get("type") == "suite"]
    require(len(suites) == 2 and suites[0].get("event") == "started"
            and suites[0].get("test_count") == 1 and suites[1].get("event") == "ok"
            and suites[1].get("passed") == 1 and suites[1].get("failed") == 0
            and suites[1].get("ignored") == 0, f"not exactly one passing test: {name}")


def check_unconditional_source(source, name):
    # Selected bodies are the source between successive test attributes. This is
    # a conservative skip guard, not a Rust parser or proof of arbitrary control flow.
    short = name.split("::")[-1]
    parts = re.split(r"#\[test\]", source)
    bodies = [part for part in parts[1:] if re.match(r"\s*fn " + re.escape(short) + r"\(", part)]
    require(len(bodies) == 1, f"missing unconditional #[test] function: {name}")
    body = re.sub(r"//[^\n]*", "", bodies[0])
    require(not re.search(r"\breturn\b|#\[ignore|\b(?:option_env!|env::var)|\b(?:SKIP|skip!)", body),
            f"selected test contains a possible early-return/model skip: {name}")


class Run:
    def __init__(self, root, evidence, target):
        self.root, self.evidence, self.target = root, evidence, target
        self.workspace = root / "rebirth/src/rust"
        self.env = dict(os.environ)
        for key in list(self.env):
            if (key in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER",
                        "RUSTC_WORKSPACE_WRAPPER", "CFLAGS", "CXXFLAGS", "LDFLAGS",
                        "LD_PRELOAD", "ASAN_OPTIONS", "UBSAN_OPTIONS", "LSAN_OPTIONS")
                    or key.startswith("CARGO_TARGET_") or "COMPILER_LAUNCHER" in key):
                self.env.pop(key)
        self.env.update({
            "RUSTUP_TOOLCHAIN": TOOLCHAIN, "CC": "clang-19", "CXX": "clang++-19",
            "CARGO_TARGET_DIR": str(target), "CARGO_INCREMENTAL": "0", "CARGO_BUILD_JOBS": "2",
            "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS": " ".join(RUST_FLAGS),
            "RELM_NATIVE_SANITIZERS": "address,undefined", "SOURCE_DATE_EPOCH": "1700000000",
            "CCACHE_DISABLE": "1", "SCCACHE_DISABLE": "1", "RUST_TEST_THREADS": "1",
            "ASAN_OPTIONS": "detect_leaks=1:halt_on_error=1:abort_on_error=0:detect_stack_use_after_return=1",
            "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1",
            "ASAN_SYMBOLIZER_PATH": "/usr/bin/llvm-symbolizer-19",
        })
        self.commands = evidence / "commands.jsonl"

    def command(self, argv, label, timeout=120, check=True, cwd=None):
        argv = [str(arg) for arg in argv]
        with self.commands.open("a") as stream:
            stream.write(json.dumps({"command": argv, "cwd": str(cwd or self.workspace),
                                     "timeout_seconds": timeout, "label": label}) + "\n")
        if not label.startswith("object-"):
            print(f"Running {label}", flush=True)
        out_path, err_path = self.evidence / f"{label}.out", self.evidence / f"{label}.err"
        # Stream into files so a timeout/cancellation retains the original output.
        # GNU timeout kills descendants too; no orphaned engine build remains.
        with out_path.open("w") as out, err_path.open("w") as err:
            result = subprocess.run(["timeout", "--signal=TERM", "--kill-after=15", str(timeout), *argv],
                                    cwd=cwd or self.workspace, env=self.env, stdout=out, stderr=err)
        output, errors = out_path.read_text(errors="replace"), err_path.read_text(errors="replace")
        with self.commands.open("a") as stream:
            stream.write(json.dumps({"label": label, "status": result.returncode}) + "\n")
        if check:
            require(result.returncode == 0,
                    f"{label} exited {result.returncode}; see retained {out_path.name}/{err_path.name}")
        return result.returncode, output, errors

    def preflight(self):
        require(sys.platform == "linux" and os.uname().machine == "x86_64", "Linux x86_64 required")
        require(not self.target.exists(), "sanitizer target must be a new, empty path")
        self.target.mkdir(parents=True)
        _, rust, _ = self.command(["rustc", "-vV"], "rust-version")
        require("LLVM version: 19." in rust, "pinned Rust no longer uses LLVM 19")
        for compiler in ("clang-19", "clang++-19"):
            _, version, _ = self.command([compiler, "--version"], compiler + "-version")
            require(f"clang version {CLANG_VERSION}" in version, "unexpected Clang version")
        self.command(["cargo", "--version"], "cargo-version")
        self.command(["cmake", "--version"], "cmake-version")
        self.command(["uname", "-a"], "platform")
        self.command(["dpkg-query", "-W", "clang-19", "llvm-19", "libclang-rt-19-dev"], "packages")
        _, head, _ = self.command(["git", "rev-parse", "HEAD"], "source-head", cwd=self.root)
        _, files, _ = self.command(["git", "ls-files", "-z"], "source-files", cwd=self.root)
        source = {name: digest(self.root / name) for name in files.split("\0")
                  if name and (self.root / name).is_file()}
        manifest = {"source_commit": head.strip(), "tracked_file_sha256": source,
                    "flags": {key: self.env[key] for key in ("CARGO_TARGET_DIR", "CARGO_INCREMENTAL",
                        "CARGO_BUILD_JOBS", "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS",
                        "RELM_NATIVE_SANITIZERS", "ASAN_OPTIONS", "UBSAN_OPTIONS", "CCACHE_DISABLE",
                        "SCCACHE_DISABLE", "CC", "CXX", "SOURCE_DATE_EPOCH", "RUSTUP_TOOLCHAIN")},
                    "ci": {key: os.environ.get(key) for key in ("GITHUB_SHA", "GITHUB_RUN_ID",
                            "GITHUB_RUN_ATTEMPT", "GITHUB_JOB", "RUNNER_NAME")}}
        (self.evidence / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
        _, resource, _ = self.command(["clang-19", "--print-resource-dir"], "clang-resource-dir")
        runtimes = sorted((Path(resource.strip()) / "lib/linux").glob("*san*x86_64*"))
        require(any("asan" in path.name for path in runtimes), "missing Clang ASan runtime")
        (self.evidence / "runtime-digests.json").write_text(json.dumps(
            {str(path): digest(path) for path in runtimes if path.is_file()}, indent=2) + "\n")
        for binary, names in CASES.items():
            relative = "src/async_job.rs" if binary == "rebirth_llm" else f"tests/{binary}.rs"
            source = (self.workspace / "rebirth-llm" / relative).read_text()
            for name in names:
                check_unconditional_source(source, name)
        self.probes()

    def probes(self):
        controls = self.evidence / "controls"
        controls.mkdir()
        source = self.root / "tests/sanitizers"
        for instrumented in (True, False):
            suffix = "instrumented" if instrumented else "plain"
            objects = []
            for compiler, language, name in (("clang-19", "c", "c_probe"),
                                              ("clang++-19", "c++", "cpp_probe")):
                obj = controls / f"{name}-{suffix}.o"
                # ASan-only access probes must reach ASan rather than UBSan's
                # array-index check; a pointer dereference is used by the probe.
                flags = NATIVE_FLAGS if instrumented else ["-O1", "-g"]
                self.command([compiler, "-x", language, *flags, f"-DPROBE_NAME={name}",
                              "-c", source / "probe.c", "-o", obj], f"compile-{name}-{suffix}")
                objects.append(obj)
            binary = controls / f"probe-{suffix}"
            flags = RUST_FLAGS if instrumented else ["-Clinker=clang++-19"]
            self.command(["rustc", "--edition=2021", "--target", TARGET, *flags,
                          *[f"-Clink-arg={obj}" for obj in objects], source / "probe.rs",
                          "-o", binary], f"link-probe-{suffix}")
            _, out, err = self.command([binary, "safe"], f"safe-{suffix}")
            require("mixed-language safe control executed" in out and not FINDING.search(err),
                    "mixed-language safe control did not execute cleanly")
            _, symbols, _ = self.command(["llvm-nm-19", "--defined-only", binary], f"symbols-{suffix}")
            if instrumented:
                check_runtime_symbols(symbols)
                self.command(["ldd", binary], "runtime-linkage-probe")
                for mode in ("rust-asan", "c-asan", "cpp-asan", "cpp-ubsan"):
                    status, out, err = self.command([binary, mode], mode, check=False)
                    marker = "runtime error: signed integer overflow" if mode == "cpp-ubsan" else "ERROR: AddressSanitizer: stack-buffer-overflow"
                    check_fault(status, out + err, marker)
            else:
                try:
                    check_runtime_symbols(symbols)
                except RuntimeError:
                    (self.evidence / "uninstrumented-control.txt").write_text(
                        "PASS: the identical safe probe without instrumentation was rejected.\n")
                else:
                    raise RuntimeError("uninstrumented control was incorrectly accepted")
        print("Sanitizer runtime, fault and uninstrumented controls passed", flush=True)

    def build(self):
        command = ["cargo", "test", "--locked", "-p", "rebirth-llm", "--target", TARGET,
                   "-Zbuild-std", "--no-run", "--lib", "--message-format=json", "-vv"]
        for name in CASES:
            if name != "rebirth_llm":
                command += ["--test", name]
        _, output, _ = self.command(command, "build", timeout=4200)
        artifacts = {}
        for line in output.splitlines():
            event = json.loads(line)
            if event.get("reason") == "compiler-artifact" and event.get("executable"):
                name = event["target"]["name"]
                if name in CASES and event["profile"]["test"]:
                    require(name not in artifacts, f"duplicate artifact {name}")
                    artifacts[name] = Path(event["executable"])
        require(set(artifacts) == set(CASES), "missing selected test binary")
        self.audit_objects()
        # Evidence that Rust itself, dependencies and std were recompiled with ASan.
        build_log = (self.evidence / "build.err").read_text()
        rust_objects = []
        for crate in ("rebirth_llm", "arrow_array", "std"):
            lines = [line for line in build_log.splitlines()
                     if re.search(r"--crate-name " + crate + r"\s", line)
                     and "--target x86_64-unknown-linux-gnu" in line]
            require(lines and all("-Zsanitizer=address" in line and "-Zexternal-clangrt" in line
                                  for line in lines), f"missing ASan rustc command for {crate}")
            archives = list((self.target / TARGET / "debug/deps").glob(f"lib{crate}-*.rlib"))
            require(len(archives) == 1, f"missing or ambiguous compiled Rust archive: {crate}")
            _, symbols, _ = self.command(["llvm-nm-19", "--undefined-only", archives[0]],
                                         f"rust-object-{crate}")
            require("__asan_" in symbols, f"compiled Rust archive lacks ASan references: {crate}")
            rust_objects.append({"crate": crate, "archive": str(archives[0]),
                                 "sha256": digest(archives[0]), "asan": True})
        (self.evidence / "rust-objects.json").write_text(json.dumps(rust_objects, indent=2) + "\n")
        return artifacts

    def audit_objects(self):
        databases = sorted(self.target.rglob("compile_commands.json"))
        require(len(databases) == 2, "expected exactly engine and native-bridge compile databases")
        records, graph_object = [], None
        for index, database in enumerate(databases):
            shutil.copyfile(database, self.evidence / f"compile_commands-{index}.json")
            commands = json.loads(database.read_text())
            require(commands, "empty native compilation database")
            for entry in commands:
                args = entry.get("arguments") or shlex.split(entry["command"])
                require(Path(args[0]).name in ("clang-19", "clang++-19"), "compiler cache/wrong compiler")
                for flag in NATIVE_FLAGS:
                    require(flag in args, f"native compile lacks {flag}: {entry['file']}")
                require(not any(arg.startswith("-fno-sanitize=") for arg in args),
                        "native object disables a sanitizer")
                obj = Path(entry["directory"]) / args[args.index("-o") + 1]
                require(obj.is_file(), f"compiled native object missing: {obj}")
                label = f"object-{len(records):04d}"
                _, symbols, _ = self.command(["llvm-nm-19", "--undefined-only", obj], label)
                require("__asan_" in symbols, f"native object has no ASan references: {obj}")
                records.append({"source": entry["file"], "object": str(obj), "sha256": digest(obj),
                                "asan": True, "ubsan": "__ubsan_" in symbols})
                if Path(entry["file"]).name == "llama-graph.cpp":
                    require("__ubsan_" in symbols, "patched graph lacks UBSan references")
                    graph_object = obj
        for name in ("grammar.cpp", "abi.cpp", "spill_lease.cpp"):
            require(any(Path(record["source"]).name == name for record in records),
                    f"native bridge source not instrumented: {name}")
        require(any(record["ubsan"] and Path(record["source"]).name in
                    ("grammar.cpp", "abi.cpp", "spill_lease.cpp") for record in records),
                "native bridge objects lack UBSan references")
        require(any(record["ubsan"] and record["source"].endswith(".c") for record in records),
                "C engine objects lack UBSan references")
        require(graph_object is not None, "patched graph object missing")
        _, disassembly, _ = self.command(["llvm-objdump-19", "-dr", "--demangle", graph_object],
                                         "patched-build-cvec-disassembly")
        functions = re.split(r"(?m)^[0-9a-f]+ <", disassembly)
        cvec = [part for part in functions if part.startswith("llm_graph_context::build_cvec(")]
        require(len(cvec) == 1 and "__asan_" in cvec[0] and "__ubsan_" in cvec[0],
                "build_cvec machine code lacks ASan/UBSan calls")
        (self.evidence / "native-objects.json").write_text(json.dumps(records, indent=2) + "\n")

    def execute(self, artifacts):
        receipts = []
        for name, binary in artifacts.items():
            _, symbols, _ = self.command(["llvm-nm-19", "--defined-only", binary], f"binary-{name}-symbols")
            check_runtime_symbols(symbols)
            self.command(["ldd", binary], f"binary-{name}-linkage")
            for test in CASES[name]:
                label = f"test-{test}"
                _, output, errors = self.command([binary, "--exact", test, "--test-threads=1",
                    "--format=json", "-Zunstable-options", "--nocapture"], label, timeout=180)
                check_test_events(output, test)
                require(not FINDING.search(output + errors), f"sanitizer finding in {test}")
                if name in WORK_MARKERS:
                    require(WORK_MARKERS[name] in errors, f"missing forward-pass marker: {name}")
                receipts.append({"binary": name, "binary_sha256": digest(binary), "test": test,
                                 "status": "executed_ok", "stdout_sha256": digest(self.evidence / f"{label}.out"),
                                 "stderr_sha256": digest(self.evidence / f"{label}.err")})
                (self.evidence / "executed-tests.json").write_text(json.dumps(receipts, indent=2) + "\n")
                print(f"SANITIZER_EXECUTED {name}::{test}", flush=True)
        require(len(receipts) == sum(map(len, CASES.values())), "incomplete sanitizer coverage")
        (self.evidence / "SUCCESS.txt").write_text(
            f"{len(receipts)} required native CPU tests executed with ASan (Rust/C/C++) and UBSan (C/C++).\n"
            "No R/SEXP, vision, GPU, ThreadSanitizer or universal Rust UB claim.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    # A manual rerun into a retained evidence directory must never leave an old
    # success receipt visible when this invocation fails its isolation checks.
    (args.evidence / "SUCCESS.txt").unlink(missing_ok=True)
    runner = Run(Path(__file__).resolve().parents[2], args.evidence.resolve(), args.target.resolve())
    try:
        runner.preflight()
        artifacts = runner.build()
        runner.execute(artifacts)
    except Exception as error:
        (runner.evidence / "FAILURE.txt").write_text(f"{type(error).__name__}: {error}\n")
        raise


if __name__ == "__main__":
    main()
