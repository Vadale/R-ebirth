#!/usr/bin/env python3
"""S1 operational comparison, offline, with pinned Qwen and stdlib only.

Example (a NEW output directory is required):
  python3 tests/structured-output/run-model.py --model /path/model.gguf \
    --backend metal --output /tmp/relm-s1-metal --r-library /tmp/relm-library
  python3 tests/structured-output/run-model.py --self-test

Linux uses --backend cpu. No downloads, held-out scoring, or prompt tuning.
"""
import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
from datetime import datetime, timezone

import verify

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
ALIAS = "qwen2.5-0.5b-instruct-q8_0"
CASE_ID = "ace22-purpose"  # Frozen development excerpt; missing funding values.
TIMEOUT_SECONDS = 180


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
                    encoding="utf-8")


def peak_rss(text, system):
    if system == "Darwin":
        match = re.search(r"^\s*(\d+)\s+maximum resident set size\s*$", text, re.MULTILINE)
        unit = 1  # BSD time -l reports bytes on macOS.
    else:
        match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
        unit = 1024  # GNU time -v reports KiB on Linux.
    if match is None or int(match[1]) <= 0:
        raise ValueError("Missing or invalid maximum resident set size from /usr/bin/time")
    return int(match[1]) * unit


def check_profile_record(value):
    """Independent assertions for the frozen output.schema.json, not task truth."""
    if type(value) is not dict or set(value) != set(verify.FIELDS) | {"evidence"}:
        raise ValueError("Root must contain exactly the required schema properties")
    evidence = value["evidence"]
    if type(evidence) is not dict or set(evidence) != set(verify.FIELDS):
        raise ValueError("Evidence must contain exactly the required schema properties")
    for field, low, high in (("amount_usd", 0, 2147483647), ("duration_years", 1, 30)):
        number = value[field]
        if number is not None and (type(number) is not int or not low <= number <= high):
            raise ValueError(f"{field}: expected null or a bounded integer")
    qualifier = value["amount_qualifier"]
    if type(qualifier) is not str or qualifier not in verify.QUALIFIERS:
        raise ValueError("amount_qualifier: expected a supported string enum member")
    if value["conditional_on_funds"] is not None and type(value["conditional_on_funds"]) is not bool:
        raise ValueError("conditional_on_funds: expected null or boolean")
    for field, quote in evidence.items():
        if quote is not None:
            if type(quote) is not str or len(quote) > 512:
                raise ValueError(f"evidence/{field}: expected null or a string of at most 512 scalars")
            quote.encode("utf-8", errors="strict")  # Reject unpaired surrogate escapes.


def check_schema_output(text):
    try:
        text.encode("utf-8", errors="strict")
        check_profile_record(verify.loads(text))  # Reject duplicate keys and non-JSON constants.
        return {"valid": True, "error": None}
    except (ValueError, TypeError, KeyError, UnicodeError) as exc:
        return {"valid": False, "error": str(exc) or type(exc).__name__}


def check_task_output(text, source):
    """Report-only task checks; these are outside the S1 schema/runtime gate."""
    try:
        verify.check_record(verify.loads(text), source)
        return {"valid": True, "error": None}
    except (AssertionError, ValueError, TypeError, KeyError, UnicodeError) as exc:
        return {"valid": False, "error": str(exc) or type(exc).__name__}


def median_seconds_per_generated_token(samples):
    measured = [row for row in samples if row["phase"] == "measured"]
    if len(measured) != 3 or any(row["status"] != "success" or
                               row["output_tokens"] <= 0 or row["elapsed_seconds"] <= 0 or
                               not math.isfinite(row["elapsed_seconds"]) for row in measured):
        return None
    return statistics.median(row["elapsed_seconds"] / row["output_tokens"] for row in measured)


def run_child(mode, args, output, source, system):
    directory = output / mode
    directory.mkdir()
    command = ["/usr/bin/time", "-l" if system == "Darwin" else "-v", args.rscript,
               "--vanilla", str(ROOT / "run-model.R"), mode, str(args.model), args.backend,
               str(output / "prompt.txt"), str(output / "schema.json"), str(directory),
               str(args.r_library) if args.r_library else ""]
    result = {"command": command, "timeout_seconds": TIMEOUT_SECONDS, "timed_out": False,
              "peak_rss_bytes": None, "samples": [], "errors": []}
    with (directory / "stdout.log").open("wb") as stdout, (directory / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True,
                                   env={**os.environ, "LC_ALL": "C", "LANG": "C"})
        try:
            result["returncode"] = process.wait(timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            result["timed_out"] = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            result["returncode"] = process.returncode
    try:
        result["peak_rss_bytes"] = peak_rss((directory / "stderr.log").read_text(errors="replace"), system)
    except ValueError as exc:
        result["errors"].append(str(exc))
    records = directory / "records.tsv"
    if records.exists():
        with records.open(encoding="utf-8", newline="") as stream:
            for record in csv.DictReader(stream, delimiter="\t"):
                record["index"] = int(record["index"])
                record["seed"] = int(record["seed"])
                record["elapsed_seconds"] = float(record["elapsed_seconds"])
                record["output_tokens"] = int(record["output_tokens"] or 0)
                record["retokenized_count"] = int(record["retokenized_count"] or 0)
                if record["status"] == "success":
                    path = directory / f"output-{record['index']}.json"
                    record["output_sha256"] = sha256(path)
                    record["output_file"] = str(path.relative_to(output))
                    try:
                        text = path.read_text(encoding="utf-8", errors="strict")
                        record["schema_check"] = check_schema_output(text)
                        record["task_record_check"] = check_task_output(text, source)
                    except UnicodeError as exc:
                        record["schema_check"] = {"valid": False, "error": str(exc)}
                        record["task_record_check"] = {"valid": False, "error": str(exc)}
                result["samples"].append(record)
    metadata = directory / "metadata.tsv"
    if metadata.exists():
        with metadata.open(encoding="utf-8", newline="") as stream:
            result["runtime"] = {row["key"]: row["value"] for row in csv.DictReader(stream, delimiter="\t")}
        native = Path(result["runtime"]["native_library"])
        result["runtime"]["native_library_sha256"] = sha256(native)
    result["median_seconds_per_generated_token"] = median_seconds_per_generated_token(result["samples"])
    return result


def gates(runs):
    plain, structured = runs["unconstrained"], runs["structured"]
    complete = all(run["returncode"] == 0 and not run["timed_out"] and
                   len(run["samples"]) == 4 and not run["errors"] for run in runs.values())
    valid = len(structured["samples"]) == 4 and all(
        row["status"] == "success" and row["schema_check"]["valid"] for row in structured["samples"])
    baseline = plain["median_seconds_per_generated_token"]
    constrained = structured["median_seconds_per_generated_token"]
    ratio = constrained / baseline if baseline and constrained else None
    extra = (max(0, structured["peak_rss_bytes"] - plain["peak_rss_bytes"])
             if all(run["peak_rss_bytes"] is not None for run in runs.values()) else None)
    result = {"runs_complete": complete, "structured_schema_pass": valid,
              "median_seconds_per_generated_token_ratio": ratio, "latency_ratio_limit": 2.0,
              "latency_pass": ratio is not None and ratio <= 2,
              "additional_peak_rss_bytes": extra, "additional_peak_rss_limit_bytes": 128 * 1024**2,
              "memory_pass": extra is not None and extra <= 128 * 1024**2}
    result["passed"] = all(result[key] for key in
                           ("runs_complete", "structured_schema_pass", "latency_pass", "memory_pass"))
    return result


def self_test():
    assert peak_rss("  12345  maximum resident set size\n", "Darwin") == 12345
    assert peak_rss("Maximum resident set size (kbytes): 12345\n", "Linux") == 12345 * 1024
    try:
        peak_rss("missing counter", "Darwin")
    except ValueError:
        pass
    else:
        raise AssertionError("Missing RSS was accepted")
    cases = verify.loads((ROOT / "cases.json").read_text())
    manifest = verify.loads((ROOT / "manifest.json").read_text())
    verify.audit(cases, manifest)
    case = next(case for case in cases if case["id"] == CASE_ID)
    assert case["split"] == "development"
    text = json.dumps(case["expected"])
    assert check_schema_output(text)["valid"]
    assert check_task_output(text, case["text"])["valid"]
    assert not check_schema_output(text[:-1])["valid"]
    assert not check_schema_output('{"amount_usd":null,"amount_usd":0}')["valid"]
    # S1 must accept schema-valid output while retaining task-level failures.
    bad_quote = json.loads(text)
    bad_quote["amount_usd"] = 100
    bad_quote["amount_qualifier"] = "stated"
    bad_quote["evidence"]["amount_usd"] = "Invented amount $100"
    bad_quote["evidence"]["amount_qualifier"] = "Invented amount $100"
    mismatch = json.loads(text)
    mismatch["amount_qualifier"] = "stated"  # Schema permits this alongside a null amount.
    for record in (bad_quote, mismatch):
        encoded = json.dumps(record)
        assert check_schema_output(encoded)["valid"]
        assert not check_task_output(encoded, case["text"])["valid"]
    for field, invalid in (("amount_usd", True), ("amount_usd", 1.0),
                           ("amount_usd", -1), ("amount_usd", 2147483648),
                           ("duration_years", 0), ("duration_years", 31),
                           ("conditional_on_funds", 0), ("amount_qualifier", "unknown")):
        record = json.loads(text)
        record[field] = invalid
        assert not check_schema_output(json.dumps(record))["valid"]
    for invalid in ("x" * 513, "\ud800"):
        record = json.loads(text)
        record["evidence"]["amount_usd"] = invalid
        assert not check_schema_output(json.dumps(record))["valid"]
    record = json.loads(text)
    record["evidence"]["amount_usd"] = "\U0001f600" * 512
    assert check_schema_output(json.dumps(record))["valid"]
    record["extra"] = None
    assert not check_schema_output(json.dumps(record))["valid"]
    del record["extra"], record["duration_years"]
    assert not check_schema_output(json.dumps(record))["valid"]
    sample = {"phase": "measured", "status": "success", "elapsed_seconds": 1.0,
              "output_tokens": 10, "schema_check": {"valid": True},
              "task_record_check": {"valid": False, "error": "report-only task failure"}}
    assert median_seconds_per_generated_token([sample] * 3) == 0.1
    assert median_seconds_per_generated_token([sample] * 2) is None
    run = {"returncode": 0, "timed_out": False, "samples": [sample] * 4,
           "errors": [], "peak_rss_bytes": 1000, "median_seconds_per_generated_token": 0.1}
    assert gates({"unconstrained": run, "structured": run})["passed"]
    slower = {**run, "median_seconds_per_generated_token": 0.21}
    assert not gates({"unconstrained": run, "structured": slower})["latency_pass"]
    larger = {**run, "peak_rss_bytes": 1001 + 128 * 1024**2}
    assert not gates({"unconstrained": run, "structured": larger})["memory_pass"]
    print("S1 driver self-test passed: corpus, parser, RSS units and gate arithmetic; no model run.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", type=Path, help="Existing pinned Qwen2.5-0.5B-Instruct Q8_0 GGUF")
    parser.add_argument("--backend", choices=("metal", "cpu"))
    parser.add_argument("--output", type=Path, help="New output directory (never overwritten)")
    parser.add_argument("--r-library", type=Path, help="Optional installed relm library")
    parser.add_argument("--rscript", default="Rscript")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if not __debug__:
        parser.error("Do not use Python -O: the independent corpus checker uses assertions.")
    if args.self_test:
        self_test()
        return 0
    if not all((args.model, args.backend, args.output)):
        parser.error("--model, --backend and --output are required")
    system = platform.system()
    if (system, args.backend) not in {("Darwin", "metal"), ("Linux", "cpu")}:
        parser.error("Acceptance targets are macOS Metal and Linux CPU")
    args.rscript = shutil.which(args.rscript)
    if not args.rscript or not Path("/usr/bin/time").is_file():
        parser.error("Rscript and /usr/bin/time are required")
    args.model = args.model.expanduser().resolve(strict=True)
    if args.r_library:
        args.r_library = args.r_library.expanduser().resolve(strict=True)
    registry = REPO / "rebirth" / "inst" / "models.csv"
    with registry.open(newline="", encoding="utf-8") as stream:
        pin = next(row for row in csv.DictReader(stream) if row["alias"] == ALIAS)
    actual_hash = sha256(args.model)
    if actual_hash != pin["sha256"]:
        parser.error(f"Model SHA256 mismatch for {ALIAS}: {actual_hash}")
    cases = verify.loads((ROOT / "cases.json").read_text(encoding="utf-8"))
    manifest = verify.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    verify.audit(cases, manifest)
    case = next(case for case in cases if case["id"] == CASE_ID)
    if case["split"] != "development":
        raise ValueError("Operational fixture must belong to development")
    schema = (ROOT / "output.schema.json").read_text(encoding="utf-8")
    prompt = ("Extract only funding facts explicitly stated in the excerpt for the target. "
              "Return exactly one JSON object matching the schema, without markdown or commentary. "
              "If a value is not stated, use null and a null evidence value; use not_stated for a "
              "missing amount_qualifier. Evidence must be an exact substring of the excerpt. "
              "Do not infer amounts, duration or funding conditions from other facts.\n\n"
              f"Target: {case['target']}\nExcerpt: {case['text']}\n\nSchema:\n{schema}")
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "prompt.txt").write_text(prompt, encoding="utf-8")
    (output / "schema.json").write_text(schema, encoding="utf-8")
    config = {"version": 2, "started_utc": datetime.now(timezone.utc).isoformat(),
              "system": platform.platform(), "machine": platform.machine(), "backend": args.backend,
              "model": {"path": str(args.model), "alias": ALIAS, "sha256": actual_hash, "url": pin["url"]},
              "case_id": CASE_ID, "split": "development", "mode_order": ["unconstrained", "structured"],
              "parameters": {"context_length": 4096, "max_tokens": 512, "temperature": 0,
                             "top_p": 0.95, "chat": True, "seeds": [1, 11, 29, 47]},
              "warmups_per_mode": 1, "measured_repetitions_per_mode": 3,
              "output_tokens_semantics": "Native generated_tokens payload, observed by a base-R exit trace on the internal wrapper; public llm_generate path is timed",
              "retokenized_count_semantics": "Diagnostic only: llm_tokens(output) with add_special=FALSE; excluded from the latency denominator",
              "input_sha256": {name: sha256(ROOT / name) for name in
                               ("cases.json", "manifest.json", "output.schema.json", "verify.py", "run-model.py", "run-model.R")},
              "prompt_sha256": sha256(output / "prompt.txt"), "registry_sha256": sha256(registry)}
    write_json(output / "config.json", config)
    runs = {mode: run_child(mode, args, output, case["text"], system) for mode in config["mode_order"]}
    report = {"config": config, "runs": runs, "gates": gates(runs), "limitations": [
        "One fixed development excerpt repeated; no held-out evaluation or extraction quality estimate.",
        "The S1 gate independently checks the frozen schema: required keys, types, bounds, enums and Unicode. It is not a D1 quality gate.",
        "task_record_check is report-only: missingness/evidence consistency and exact quote substrings may fail even when the schema passes; passing does not establish factual correctness.",
        "Seconds per generated token includes the public R path, prompt processing, schema work and a small exit-trace callback; it excludes model load and output retokenization.",
        "output_tokens records the native generated_tokens payload. retokenized_count is retained separately as a diagnostic; the public API is unchanged.",
        "Output lengths may differ between modes; raw lengths and durations are retained. Mode order is fixed.",
        "RSS is each complete child process peak, including loading and warmup; it does not isolate grammar allocations or all GPU memory.",
    ]}
    write_json(output / "report.json", report)
    print(json.dumps(report["gates"], indent=2))
    print(f"Report: {output / 'report.json'}")
    return 0 if report["gates"]["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
