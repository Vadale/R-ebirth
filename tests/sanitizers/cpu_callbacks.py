#!/usr/bin/env python3
"""D-040: actual-source callback contracts and mandatory Linux UBSan controls.

Typed stubs verify forwarding, not numerical kernels. The full native gate
remains separate. macOS can run type/forwarding checks without claiming a
runtime function-type check that its compiler does not instrument.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
GGML = ROOT / "rebirth/src/llama.cpp/ggml"
TARGETS = [
    ("ggml_vec_dot_t", "ggml_vec_dot_f32"),
    ("ggml_vec_dot_t", "ggml_vec_dot_f16"),
    ("ggml_vec_dot_t", "ggml_vec_dot_bf16"),
    ("ggml_from_float_t", "ggml_cpu_fp32_to_fp32"),
    ("ggml_from_float_t", "ggml_cpu_fp32_to_fp16"),
    ("ggml_from_float_t", "ggml_cpu_fp32_to_bf16"),
    ("ggml_from_float_t", "ggml_cpu_fp32_to_i32"),
]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_adapters(source):
    """Extract live definitions and require their live trait assignments."""
    table = source.split("static const struct ggml_type_traits_cpu type_traits_cpu[GGML_TYPE_COUNT] = {")
    require(len(table) == 2, "missing/ambiguous CPU trait table")
    table = table[1].split("\n};", 1)[0]
    adapters = []
    for typedef, target in TARGETS:
        adapter = target + "_adapter"
        matches = re.findall(r"static void " + adapter + r"\([^{}]*\) \{[^{}]*\n\}", source)
        require(len(matches) == 1, "missing/ambiguous adapter: " + adapter)
        field = "vec_dot" if typedef == "ggml_vec_dot_t" else "from_float"
        require(len(re.findall(r"\." + field + r"\s*=\s*" + adapter + r"\s*,", table)) == 1,
                "adapter not directly assigned: " + adapter)
        require(not re.search(r"\(" + typedef + r"\)\s*" + target + r"\b", table),
                "original function cast still present: " + target)
        adapters.append(matches[0])
    return "\n\n".join(adapters) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang")
    parser.add_argument("--cxx", default="clang++")
    parser.add_argument("--require-runtime", action="store_true")
    parser.add_argument("--symbolizer", help="Require this executable for readable runtime diagnostics")
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=False)
    state = {"status": "running", "commands": [], "runtime_required": args.require_runtime,
             "scope": "Actual-source assignments/adapters with typed stub targets; no numerical kernels."}
    env = dict(os.environ, UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1",
               ASAN_OPTIONS="halt_on_error=1:abort_on_error=0")

    def save():
        (out / "result.json").write_text(json.dumps(state, indent=2) + "\n")

    def run(name, command):
        result = subprocess.run([str(s) for s in command], env=env, capture_output=True, timeout=60)
        for suffix, data in (("out", result.stdout), ("err", result.stderr)):
            (out / (name + "." + suffix)).write_bytes(data)
        state["commands"].append({"name": name, "command": [str(s) for s in command],
                                  "exit_code": result.returncode})
        save()
        return result

    def success(name, command):
        result = run(name, command)
        require(result.returncode == 0, name + " failed")
        return result

    try:
        if args.symbolizer:
            symbolizer = shutil.which(args.symbolizer)
            require(symbolizer is not None, "requested symbolizer unavailable")
            env["ASAN_SYMBOLIZER_PATH"] = symbolizer
            env["UBSAN_OPTIONS"] += ":external_symbolizer_path=" + symbolizer
        cpu = GGML / "src/ggml-cpu/ggml-cpu.c"
        vec = GGML / "src/ggml-cpu/vec.h"
        paths = [cpu, vec, Path(__file__).resolve(), HERE / "cpu_callbacks_main.c",
                 HERE / "cpu_callbacks_stubs.cpp", GGML / "include/ggml-cpu.h",
                 GGML / "include/ggml.h", GGML / "include/ggml-backend.h",
                 GGML / "include/ggml-alloc.h"]
        state["source_sha256"] = {str(p.relative_to(ROOT)): sha(p) for p in paths}
        (out / "adapters.h").write_text(extract_adapters(cpu.read_text()))
        declarations = re.findall(r"^void ggml_vec_dot_(?:f32|f16|bf16)\([^\n]+;", vec.read_text(), re.M)
        require(len(declarations) == 3, "missing live typed dot declarations")
        (out / "shared.h").write_text(
            '#include "ggml-cpu.h"\n#include <assert.h>\n#include <string.h>\n'
            '#ifdef __cplusplus\nextern "C" {\n#endif\n' + "\n".join(declarations) +
            '\nstruct expected_call { const void *x; void *y; float *s; int id; int calls; };\n'
            'extern struct expected_call expected;\n#ifdef __cplusplus\n}\n#endif\n')
        for source, dest in (("cpu_callbacks_main.c", "main.c"), ("cpu_callbacks_stubs.cpp", "stubs.cpp")):
            (out / dest).write_bytes((HERE / source).read_bytes())
        for label, compiler in (("cc", args.cc), ("cxx", args.cxx)):
            result = success(label + "-version", [compiler, "--version"])
            require(b"clang" in result.stdout.lower(), "Clang required")
        includes = ["-I" + str(out), "-I" + str(GGML / "include")]
        flags = ["-O1", "-g", "-Wall", "-Wextra", "-Werror", "-fno-omit-frame-pointer", *includes]
        corrected = '#include "shared.h"\n#include "adapters.h"\n'
        for i, (typedef, target) in enumerate(TARGETS):
            corrected += f"{typedef} callback_{i} = {target}_adapter;\n"
            old = out / f"original-{i}.c"
            old.write_text(f'#include "shared.h"\n{typedef} original = ({typedef}) {target};\n')
            result = run(f"original-type-{i}", [args.cc, "-std=c11", *flags,
                         "-Wcast-function-type-strict", "-fsyntax-only", old])
            require(result.returncode != 0 and b"cast-function-type-strict" in result.stderr,
                    "original cast not rejected: " + target)
        (out / "corrected.c").write_text(corrected)
        success("corrected-types", [args.cc, "-std=c11", *flags, "-Wcast-function-type-strict",
                                    "-fsyntax-only", out / "corrected.c"])
        # Separate C caller/C++ targets preserve the cross-language boundary.
        for mode, sanitizer in (("plain", []), ("sanitized", ["-fsanitize=address,undefined,function",
                                                               "-fno-sanitize-recover=all"])):
            success(mode + "-caller", [args.cc, "-std=c11", *flags, *sanitizer,
                    "-c", out / "main.c", "-o", out / (mode + "-main.o")])
            success(mode + "-targets", [args.cxx, "-std=c++17", *flags, *sanitizer,
                    "-c", out / "stubs.cpp", "-o", out / (mode + "-stubs.o")])
            binary = out / (mode + "-check")
            success(mode + "-link", [args.cxx, *flags, *sanitizer,
                    out / (mode + "-main.o"), out / (mode + "-stubs.o"), "-o", binary])
            positive = success(mode + "-forwarding", [binary])
            require(not positive.stderr and positive.stdout.decode().splitlines() ==
                    [f"CALLBACK_PASS {i}" for i in range(7)] + ["SEVEN_ADAPTERS_PASSED"],
                    "missing/duplicate forwarding contracts or diagnostics")
            if mode == "plain":
                for i in range(7):
                    result = success(f"uninstrumented-control-{i}", [binary, str(i)])
                    require(result.stdout == f"ORIGINAL_TYPE_MISMATCH_SURVIVED {i}\n".encode()
                            and not result.stderr, "uninstrumented control did not execute")
        symbols = success("caller-symbols", ["nm", "-u", out / "sanitized-main.o"])
        hooked = b"ubsan_handle_function_type_mismatch" in symbols.stdout
        state["runtime_function_hook"] = hooked
        rejected = []
        for i, (_, target) in enumerate(TARGETS):
            result = run(f"original-runtime-{i}", [out / "sanitized-check", str(i)])
            detected = (result.returncode != 0 and b"incorrect function type" in result.stderr
                        and target.encode() in result.stderr and
                        b"ORIGINAL_TYPE_MISMATCH_SURVIVED" not in result.stdout)
            rejected.append(detected)
            require(detected or (not args.require_runtime and not hooked and result.returncode == 0
                    and result.stdout == f"ORIGINAL_TYPE_MISMATCH_SURVIVED {i}\n".encode()
                    and not result.stderr), "unexpected original-call outcome: " + target)
        state["runtime_rejections"] = rejected
        require(not args.require_runtime or (hooked and all(rejected)),
                "required Linux runtime function-type controls did not reject all seven calls")
        for path in paths:
            require(sha(path) == state["source_sha256"][str(path.relative_to(ROOT))], "source drift")
        state.update(status="passed", contracts=7,
                     runtime_status="passed" if hooked and all(rejected) else "unavailable_not_accepted")
    except Exception as exc:
        state.update(status="failed", error=str(exc))
        raise
    finally:
        state["evidence_sha256"] = {p.name: sha(p) for p in out.iterdir()
                                    if p.is_file() and p.name != "result.json"}
        save()
    print("CPU_CALLBACK_CONTRACTS_PASSED contracts=7 runtime=" + state["runtime_status"])


if __name__ == "__main__":
    main()
