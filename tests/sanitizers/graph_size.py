#!/usr/bin/env python3
"""D-039 source-derived graph layout regression; no full engine/model build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SIZES = (0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65,
         127, 128, 129, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025,
         4095, 4096, 4097, 65535, 65536)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def extract(source, start, end):
    require(source.count(start) == 1, "ambiguous/missing source start: " + start)
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang")
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=False)
    state = {"status": "running", "commands": [], "source_sha256": {}}
    env = dict(os.environ, UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1",
               ASAN_OPTIONS="halt_on_error=1:abort_on_error=0")

    def save():
        (out / "result.json").write_text(json.dumps(state, indent=2) + "\n")

    def run(name, command):
        result = subprocess.run(command, env=env, capture_output=True, timeout=60)
        for suffix, data in (("out", result.stdout), ("err", result.stderr)):
            (out / (name + "." + suffix)).write_bytes(data)
        state["commands"].append({"name": name, "command": command,
                                  "exit_code": result.returncode})
        save()
        return result

    try:
        source_path = ROOT / "rebirth/src/llama.cpp/ggml/src/ggml.c"
        paths = [source_path, Path(__file__).resolve(), Path(__file__).with_suffix(".c")]
        for relative in ("src/ggml-impl.h", "include/ggml.h", "include/gguf.h"):
            path = ROOT / "rebirth/src/llama.cpp/ggml" / relative
            paths.append(path)
            (out / path.name).write_bytes(path.read_bytes())
        state["source_sha256"] = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
        source = source_path.read_text()
        parts = [extract(source, "size_t ggml_hash_size(", "\nstruct hash_map {"),
                 extract(source, "static void * incr_ptr_aligned(", "\nstatic size_t ggml_graph_nbytes("),
                 extract(source, "static size_t ggml_graph_nbytes(", "\nsize_t ggml_graph_overhead_custom")]
        (out / "source-extract.h").write_text("\n".join(parts))
        (out / "graph_size.c").write_bytes(Path(__file__).with_suffix(".c").read_bytes())
        version = run("compiler", [args.cc, "--version"])
        require(version.returncode == 0 and b"clang" in version.stdout.lower(), "Clang required")
        flags = ["-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                 "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-fno-omit-frame-pointer"]
        binary = str(out / "graph-size")
        built = run("compile", [args.cc, *flags, "-I" + str(out), str(out / "graph_size.c"), "-o", binary])
        require(built.returncode == 0, "graph regression compilation failed")
        negative = run("original-arithmetic", [binary, "--negative"])
        require(negative.returncode != 0 and
                b"applying non-zero offset 96 to null pointer" in negative.stderr and
                b"UNEXPECTED_NULL_ARITHMETIC_SURVIVED" not in negative.stdout,
                "UBSan did not reject the original null arithmetic")
        positive = run("layout", [binary])
        require(positive.returncode == 0 and not positive.stderr, "layout check failed or emitted diagnostics")
        cases = re.findall(rb"^LAYOUT_CASE size=(\d+) grads=([01])$", positive.stdout, re.M)
        expected = {(size, grads) for size in SIZES for grads in (0, 1)}
        actual = [(int(size), int(grads)) for size, grads in cases]
        require(len(actual) == 68 and set(actual) == expected, "missing/duplicate layout cases")
        require(b"PASS: 68 layout cases;" in positive.stdout, "missing completion marker")
        for p in paths:
            require(sha(p.read_bytes()) == state["source_sha256"][str(p.relative_to(ROOT))], "source drift during check")
        state.update(status="passed", cases=len(actual), negative_control="expected UBSan failure")
    except Exception as exc:
        state.update(status="failed", error=str(exc))
        raise
    finally:
        state["evidence_sha256"] = {p.name: sha(p.read_bytes()) for p in out.iterdir()
                                    if p.is_file() and p.name != "result.json"}
        save()
    print("GRAPH_SIZE_LAYOUT_PASSED cases=68 source=" + state["source_sha256"][str(source_path.relative_to(ROOT))])


if __name__ == "__main__":
    main()
