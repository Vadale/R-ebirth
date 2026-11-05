#!/usr/bin/env python3
"""Check actual engine declarations and graph debug-environment behavior.

Linux and native macOS Rust CI run this without an engine or model load.
The explicit include check prevents a permissive standard library from hiding
this dependency again; compilation alone with libstdc++ can miss the defect.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROBE = r'''#include "llama-graph.h"
#include <cstdio>

class debug_probe final : public llm_graph_input_i {
public:
    void set_input(const llama_ubatch *) override {}
    int value() const { return debug; }
};

int main() {
    const debug_probe probe;
    std::printf("%d\n", probe.value());
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--cxx", default="clang++")
    parser.add_argument("--cxxflags", default="")
    parser.add_argument("--ldflags", default="")
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=False)
    vendor = args.source_root.resolve() / "rebirth/src/llama.cpp"
    state = {"status": "running", "sources": {},
             "commands": [], "cases": [], "scope": "Actual graph header, mmap/vocabulary translation units and constructor; no model or GPU."}
    try:
        # This is a portability contract, not a proxy for compiler execution.
        # The native compiler checks the same header below with no preceding include.
        for name in ["llama-graph.h", "llama-mmap.cpp", "llama-vocab.cpp"]:
            dependency = vendor / "src" / name
            state["sources"][name] = hashlib.sha256(dependency.read_bytes()).hexdigest()
            if not re.search(r"^#include <cstdlib>$", dependency.read_text(), re.M):
                raise AssertionError(f"{name} must directly include <cstdlib>")
        source = out / "probe.cpp"
        source.write_text(PROBE)
        executable = out / "probe"
        flags = ["-std=c++17", "-O2", "-Wall", "-Wextra", "-pedantic",
                 *shlex.split(args.cxxflags), "-I" + str(vendor / "src"),
                 "-I" + str(vendor / "include"), "-I" + str(vendor / "ggml/include")]
        commands = [("graph", [args.cxx, *flags, str(source), "-o", str(executable),
                               *shlex.split(args.ldflags)])]
        for name in ["llama-mmap.cpp", "llama-vocab.cpp"]:
            commands.append((name, [args.cxx, *flags, "-fsyntax-only", str(vendor / "src" / name)]))
        for name, command in commands:
            result = subprocess.run(command, capture_output=True, timeout=60,
                                    env=dict(os.environ, TMPDIR=str(out)))
            (out / (name + ".stdout")).write_bytes(result.stdout)
            (out / (name + ".stderr")).write_bytes(result.stderr)
            state["commands"].append({"name": name, "command": command, "exit": result.returncode})
            if result.returncode:
                raise RuntimeError(f"Actual engine-source compilation failed; see {name}.stderr")
        for value, expected in [(None, "0"), ("0", "0"), ("3", "3"), ("-7", "-7"),
                                ("invalid", "0"), ("  +12", "12"), ("6suffix", "6")]:
            env = dict(os.environ)
            env.pop("LLAMA_GRAPH_INPUT_DEBUG", None)
            if value is not None:
                env["LLAMA_GRAPH_INPUT_DEBUG"] = value
            result = subprocess.run([str(executable)], env=env, capture_output=True,
                                    text=True, timeout=10)
            state["cases"].append({"environment": value, "expected": expected,
                                   "stdout": result.stdout, "stderr": result.stderr,
                                   "exit": result.returncode})
            if result.returncode or result.stdout != expected + "\n" or result.stderr:
                raise AssertionError("Graph debug-environment behavior differs from its oracle")
        state["status"] = "passed"
    except Exception as error:
        state["status"] = "failed"
        state["error"] = str(error)
        raise
    finally:
        (out / "result.json").write_text(json.dumps(state, indent=2) + "\n")
    print("PASS engine headers: 3 direct dependencies, actual compilation and 7 environment cases")


if __name__ == "__main__":
    main()
