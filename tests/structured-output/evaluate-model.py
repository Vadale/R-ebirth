#!/usr/bin/env python3
"""D1 development evaluation and explicitly frozen held-out evaluation; offline.

Run development with --model MODEL --model-alias ALIAS --backend metal
--prompt-template TEMPLATE --output NEW_DIRECTORY [--r-library LIBRARY].
Freeze the same settings with --freeze-only --development-report DEV/report.json
--output NEW_FREEZE_DIRECTORY. Then use --split held_out --candidate
NEW_FREEZE_DIRECTORY/candidate.json and another new output directory.
"""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys

import verify

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
spec = importlib.util.spec_from_file_location("s1_profile_checks", ROOT / "run-model.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
ALIASES = ("qwen2.5-0.5b-instruct-q8_0", "qwen2.5-1.5b-instruct-q4_k_m")
MODES = ("unconstrained", "structured")
PLACEHOLDER = re.compile(r"\{\{([^{}]*)\}\}")
TIMEOUT_SECONDS = 600
RUNTIME_KEYS = ("native_library_sha256", "package_version", "r_version", "r_platform")


def preflight_runtime(rscript, library):
    """Read the installed runtime identity without constructing an llm handle."""
    script = '''
args <- commandArgs(trailingOnly = TRUE)
if (nzchar(args[[1L]])) .libPaths(c(args[[1L]], .libPaths()))
suppressPackageStartupMessages(library(relm))
native <- getLoadedDLLs()[["relm"]][["path"]]
identity <- c(native_library_sha256 = unname(tools::sha256sum(native)),
  package_version = as.character(packageVersion("relm")),
  r_version = R.version.string, r_platform = R.version$platform)
write.table(data.frame(key = names(identity), value = unname(identity)),
  stdout(), sep = "\\t", quote = FALSE, row.names = FALSE)
'''
    result = subprocess.run([rscript, "--vanilla", "-e", script, str(library) if library else ""],
                            capture_output=True, text=True, timeout=30, check=True)
    runtime = {row["key"]: row["value"] for row in csv.DictReader(io.StringIO(result.stdout), delimiter="\t")}
    if set(runtime) != set(RUNTIME_KEYS) or not re.fullmatch(r"[0-9a-f]{64}", runtime["native_library_sha256"]):
        raise ValueError("Invalid installed-runtime preflight response")
    return runtime


def verify_runtime(runtime, expected):
    if {key: runtime.get(key) for key in RUNTIME_KEYS} != expected:
        raise ValueError("Worker runtime differs from the preflight/frozen runtime identity")


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=True, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def render_prompt(template, target, text, schema):
    values = {"target": target, "text": text, "schema": schema}
    found = set(PLACEHOLDER.findall(template))
    if found != set(values) or "{{" in PLACEHOLDER.sub("", template):
        raise ValueError("Template must contain target, text and schema placeholders, with no unknown or malformed placeholders")
    # Substitute only on the original template. Braces in source text are data.
    return PLACEHOLDER.sub(lambda match: values[match[1]], template)


def verify_candidate(candidate, identity):
    if candidate.get("version") != 1 or candidate.get("identity") != identity:
        raise ValueError("Frozen candidate identity does not match current inputs, prompt, schema, model, driver or settings")
    if candidate.get("identity_sha256") != digest_bytes(canonical(identity)):
        raise ValueError("Frozen candidate identity digest does not match")
    if not re.fullmatch(r"[0-9a-f]{64}", candidate.get("development_report_sha256", "")):
        raise ValueError("Frozen candidate lacks development-report provenance")


def discrepancy(case, row):
    schema_check = task_check = {"valid": False, "error": "No successful output"}
    value = None
    if row["status"] == "success":
        schema_check = profile.check_schema_output(row["output"])
        task_check = profile.check_task_output(row["output"], case["text"])
        try:
            value = verify.loads(row["output"])
        except (ValueError, TypeError):
            pass
    fields = {}
    for field in verify.FIELDS:
        present = type(value) is dict and field in value
        actual = value.get(field) if present else None
        evidence = value.get("evidence") if type(value) is dict else None
        quote = evidence.get(field) if type(evidence) is dict else None
        expected, anchor = case["expected"][field], case["expected"]["evidence"][field]
        match = present and type(actual) is type(expected) and actual == expected
        support = (anchor is None and quote is None) or (type(quote) is str and type(anchor) is str and anchor in quote)
        fields[field] = {"expected": expected, "observed": diagnostic_value(actual), "observed_present": present,
                         "expected_evidence_anchor": anchor, "observed_evidence": diagnostic_value(quote),
                         "value_match": match, "evidence_anchor_supported": support,
                         "scored_value_correct": task_check["valid"] and match,
                         "scored_grounded_correct": task_check["valid"] and match and support}
    return {"id": case["id"], "schema_check": schema_check, "task_record_check": task_check,
            "fields": fields, "human_review_seconds": None, "human_corrections": None}


def diagnostic_value(value):
    # JSON exponent overflow is invalid for this profile but Python parses it as
    # infinity. Preserve an explicit diagnostic instead of losing the report.
    if type(value) is float and not math.isfinite(value):
        return {"nonfinite_number": str(value)}
    if type(value) is list:
        return [diagnostic_value(item) for item in value]
    if type(value) is dict:
        return {key: diagnostic_value(item) for key, item in value.items()}
    return value


def score(cases, rows):
    metrics = verify.evaluate(cases, rows)
    by_id = {row["id"]: row for row in rows}
    details = [discrepancy(case, by_id[case["id"]]) for case in cases]
    known = sum(case["expected"]["amount_usd"] is not None for case in cases)
    return {"metrics": metrics, "schema_valid_records": sum(row["schema_check"]["valid"] for row in details),
            "denominators": {"records": len(cases), "per_field": {field: len(cases) for field in verify.FIELDS},
                             "known_amount_records": known,
                             "predicted_nonmissing_fields_in_task_valid_records": metrics["predicted_nonmissing"]},
            "numerators": {"exact_grounded_records": round(metrics["record_accuracy"] * len(cases)),
                           "correct_fields": {field: round(value * len(cases)) for field, value in metrics["field_accuracy"].items()},
                           "correct_known_amounts": round(metrics["known_amount_accuracy"] * known) if known else 0,
                           "unsupported_nonmissing_fields": round((metrics["unsupported_nonmissing_rate"] or 0) * metrics["predicted_nonmissing"])},
            "case_details": details}


def quality_gate(summary):
    metrics = summary["metrics"]
    return {"no_failed_or_invalid": metrics["failed_or_invalid"] == 0,
            "record_accuracy_at_least_0_8": metrics["record_accuracy"] >= 0.8,
            "known_amount_accuracy_at_least_0_9": metrics["known_amount_accuracy"] is not None and metrics["known_amount_accuracy"] >= 0.9,
            "unsupported_nonmissing_rate_at_most_0_05": metrics["unsupported_nonmissing_rate"] is not None and metrics["unsupported_nonmissing_rate"] <= 0.05}


def collect_results(directory, selected, process_result, expected_runtime=None):
    records, protocol_errors = {}, []
    path = directory / "records.tsv"
    if path.exists():
        with path.open(encoding="utf-8", newline="") as stream:
            for record in csv.DictReader(stream, delimiter="\t"):
                try:
                    index = int(record["index"])
                    if index in records:
                        raise ValueError("Duplicate worker index")
                    record["seed"] = int(record["seed"])
                    record["elapsed_seconds"] = float(record["elapsed_seconds"])
                    if not math.isfinite(record["elapsed_seconds"]) or record["elapsed_seconds"] < 0:
                        raise ValueError("Invalid elapsed time")
                    records[index] = record
                except (ValueError, TypeError, KeyError) as exc:
                    protocol_errors.append(str(exc))
    predictions, diagnostics = [], []
    expected_indices = {case["index"] for case in selected}
    if set(records) - expected_indices:
        protocol_errors.append("Unexpected worker indices")
    for case in selected:
        index = case["index"]
        record = records.get(index)
        if record is None:
            record = {"id": case["id"], "seed": case["seed"], "status": "failure", "elapsed_seconds": None,
                      "error_class": "worker_incomplete", "error_message": "No completed worker record; process failed, timed out or stopped before this case"}
        elif record["id"] != case["id"] or record["seed"] != case["seed"] or record["status"] not in {"success", "failure"}:
            protocol_errors.append(f"Worker identity/status mismatch at index {index}")
            record = {**record, "status": "failure", "error_class": "worker_protocol", "error_message": "Worker identity or status mismatch"}
        prediction = {"id": case["id"], "status": record["status"]}
        output = directory / f"output-{index}.json"
        partial = directory / f"output-{index}.partial.bin"
        for label, artifact in (("output", output), ("partial", partial)):
            if artifact.exists():
                record[f"{label}_file"] = artifact.name
                record[f"{label}_sha256"] = profile.sha256(artifact)
        if prediction["status"] == "success":
            try:
                prediction["output"] = output.read_bytes().decode("utf-8", errors="strict")
            except (OSError, UnicodeError) as exc:
                prediction["status"] = record["status"] = "failure"
                record["error_class"], record["error_message"] = "worker_output", str(exc)
        predictions.append(prediction)
        diagnostics.append({"index": index, **record})
    result = {**process_result, "diagnostics": diagnostics, "protocol_errors": protocol_errors,
              "execution_complete": process_result["returncode"] == 0 and not process_result["timed_out"] and
                                    set(records) == expected_indices and not protocol_errors}
    metadata = directory / "metadata.tsv"
    try:
        runtime = {}
        with metadata.open(encoding="utf-8", newline="") as stream:
            reader = csv.DictReader(stream, delimiter="\t")
            if reader.fieldnames != ["key", "value"]:
                raise ValueError("Expected key/value metadata columns")
            for row in reader:
                if set(row) != {"key", "value"} or any(value is None or not value.strip() for value in row.values()):
                    raise ValueError("Incomplete or malformed metadata row")
                if row["key"] in runtime:
                    raise ValueError(f"Duplicate metadata key: {row['key']}")
                runtime[row["key"]] = row["value"]
        result["runtime"] = runtime
        required = set(RUNTIME_KEYS) | {"package_path", "native_library", "backend", "context_length"}
        if set(runtime) != required:
            raise ValueError("Incomplete or unexpected worker metadata fields")
        if not re.fullmatch(r"[0-9a-f]{64}", runtime["native_library_sha256"]):
            raise ValueError("Invalid native library digest in metadata")
        if runtime["backend"] not in {"metal", "cpu"} or int(runtime["context_length"]) <= 0:
            raise ValueError("Invalid backend/context in metadata")
        if profile.sha256(runtime["native_library"]) != runtime["native_library_sha256"]:
            raise ValueError("Native library bytes differ from the worker's recorded digest")
    except (OSError, UnicodeError, csv.Error, ValueError) as exc:
        protocol_errors.append(f"Worker metadata: {exc}")
    if expected_runtime is not None:
        try:
            verify_runtime(result.get("runtime", {}), expected_runtime)
        except ValueError as exc:
            protocol_errors.append(str(exc))
    result["execution_complete"] = result["execution_complete"] and not protocol_errors
    with (directory / "predictions.jsonl").open("w", encoding="utf-8") as stream:
        for row in predictions:
            stream.write(json.dumps(row, ensure_ascii=True, allow_nan=False) + "\n")
    return result, predictions


def run_mode(mode, args, output, selected):
    directory = output / mode
    directory.mkdir()
    command = [args.rscript, "--vanilla", str(ROOT / "evaluate-model.R"), mode, str(args.model), args.backend,
               str(output / "inputs.tsv"), str(output / "schema.json"), str(directory),
               str(args.r_library) if args.r_library else "", str(args.max_tokens), str(args.context_length),
               str(args.temperature), str(args.top_p)]
    process_result = {"command": command, "timeout_seconds": TIMEOUT_SECONDS, "timed_out": False}
    with (directory / "stdout.log").open("wb") as stdout, (directory / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            process_result["returncode"] = process.wait(timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            process_result["timed_out"] = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            process_result["returncode"] = process.returncode
    return collect_results(directory, selected, process_result, args.runtime)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--model-alias", choices=ALIASES, required=True)
    parser.add_argument("--backend", choices=("metal", "cpu"), required=True)
    parser.add_argument("--prompt-template", type=Path, required=True)
    parser.add_argument("--schema", type=Path, default=ROOT / "output.schema.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--r-library", type=Path)
    parser.add_argument("--rscript", default="Rscript")
    parser.add_argument("--split", choices=("development", "contract", "held_out"), default="development")
    parser.add_argument("--max-tokens", type=int, default=768)
    parser.add_argument("--context-length", type=int, default=4096)
    parser.add_argument("--temperature", type=float, default=0)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--freeze-only", action="store_true")
    parser.add_argument("--development-report", type=Path)
    parser.add_argument("--candidate", type=Path)
    args = parser.parse_args()
    if not __debug__:
        parser.error("Python -O disables the frozen verifier's assertions")
    if not (1 <= args.max_tokens <= 8192 and args.context_length > 0 and
            math.isfinite(args.temperature) and 0 <= args.temperature <= 3.4028234663852886e38 and 0 < args.top_p <= 1):
        parser.error("Invalid generation settings")
    if args.freeze_only and (args.split != "development" or not args.development_report or args.candidate):
        parser.error("--freeze-only requires --development-report, development split and no --candidate")
    if args.split == "held_out" and not args.candidate:
        parser.error("held_out requires an explicitly frozen --candidate")
    if args.candidate and args.split != "held_out":
        parser.error("--candidate is reserved for the held_out run")
    args.rscript = shutil.which(args.rscript)
    if not args.rscript:
        parser.error("Rscript is required")
    for field in ("model", "prompt_template", "schema", "r_library"):
        if getattr(args, field):
            setattr(args, field, getattr(args, field).expanduser().resolve(strict=True))
    registry = REPO / "rebirth" / "inst" / "models.csv"
    with registry.open(encoding="utf-8", newline="") as stream:
        pin = next(row for row in csv.DictReader(stream) if row["alias"] == args.model_alias)
    model_hash = profile.sha256(args.model)
    if model_hash != pin["sha256"]:
        parser.error("Model SHA256 does not match the pinned alias")
    cases = verify.loads((ROOT / "cases.json").read_text(encoding="utf-8"))
    manifest = verify.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    verify.audit(cases, manifest)
    if profile.sha256(args.schema) != manifest["artifacts"]["output.schema.json"]:
        parser.error("The independent D1 checker requires the exact frozen output.schema.json")
    template, schema = args.prompt_template.read_text(encoding="utf-8"), args.schema.read_text(encoding="utf-8")
    public_inputs = [{"index": i, "id": case["id"], "seed": 101 + i, "split": case["split"],
                      "prompt": render_prompt(template, case["target"], case["text"], schema)} for i, case in enumerate(cases)]
    hashes = {name: profile.sha256(ROOT / name) for name in
              ("cases.json", "manifest.json", "output.schema.json", "verify.py", "run-model.py", "evaluate-model.py", "evaluate-model.R")}
    hashes.update({source["path"]: profile.sha256(ROOT / source["path"]) for source in manifest["sources"]})
    args.runtime = preflight_runtime(args.rscript, args.r_library)
    identity = {"model_alias": args.model_alias, "model_sha256": model_hash, "backend": args.backend,
                "runtime": args.runtime,
                "modes": list(MODES), "sampling": {"max_tokens": args.max_tokens, "context_length": args.context_length,
                "temperature": args.temperature, "top_p": args.top_p, "chat": True, "seed_rule": "101 + zero-based index in frozen cases.json"},
                "file_sha256": hashes, "registry_sha256": profile.sha256(registry),
                "template_sha256": profile.sha256(args.prompt_template), "schema_sha256": profile.sha256(args.schema),
                "label_free_inputs_sha256": digest_bytes(canonical(public_inputs))}
    candidate = None
    if args.candidate:
        candidate = verify.loads(args.candidate.read_text(encoding="utf-8"))
        verify_candidate(candidate, identity)
    if args.freeze_only:
        development = verify.loads(args.development_report.read_text(encoding="utf-8"))
        if development["config"]["split"] != "development" or development["config"]["identity"] != identity or not development["execution_complete"]:
            parser.error("Development report must be complete and match the exact candidate identity")
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "prompt-template.txt").write_bytes(args.prompt_template.read_bytes())
    (output / "schema.json").write_bytes(args.schema.read_bytes())
    config = {"version": 1, "created_utc": datetime.now(timezone.utc).isoformat(), "identity": identity,
              "split": args.split, "system": platform.platform(), "model_path": str(args.model),
              "r_library": str(args.r_library) if args.r_library else None,
              "candidate_sha256": profile.sha256(args.candidate) if args.candidate else None}
    write_json(output / "config.json", config)
    if args.freeze_only:
        candidate = {"version": 1, "frozen_utc": config["created_utc"], "identity": identity,
                     "identity_sha256": digest_bytes(canonical(identity)),
                     "development_report_sha256": profile.sha256(args.development_report)}
        write_json(output / "candidate.json", candidate)
        print(f"Frozen candidate: {output / 'candidate.json'}")
        return 0
    selected = [case for case in public_inputs if case["split"] == args.split]
    selected_cases = [case for case in cases if case["split"] == args.split]
    (output / "prompts").mkdir()
    with (output / "inputs.tsv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(("index", "id", "seed", "prompt_file"))
        for case in selected:
            path = output / "prompts" / f"{case['index']}.txt"
            path.write_text(case["prompt"], encoding="utf-8")
            writer.writerow((case["index"], case["id"], case["seed"], str(path)))
    runs = {}
    for mode in MODES:
        print(f"Running {mode}: {len(selected)} {args.split} cases", flush=True)
        result, predictions = run_mode(mode, args, output, selected)
        runs[mode] = {**result, **score(selected_cases, predictions)}
    gate = quality_gate(runs["structured"]) if args.split == "held_out" else None
    complete = all(run["execution_complete"] for run in runs.values())
    report = {"config": config, "runs": runs, "execution_complete": complete, "held_out_gate": gate,
              "held_out_gate_passed": all(gate.values()) and complete if gate is not None else None,
              "human_review_seconds": None, "human_corrections": None,
              "limitations": ["Pilot cases are not a representative quality benchmark.",
                              "Schema validity is separate from task validity and expected-grounded scoring.",
                              "Failures remain in every all-case denominator; no retry or repair was attempted.",
                              "The frozen unsupported_nonmissing_rate denominator includes emitted nonmissing fields from task-valid records only; the gate separately requires zero failed or invalid records.",
                              "Human review time and correction burden have not been measured.",
                              "The explicit candidate file guards configuration drift; it cannot prevent a user from inspecting held-out labels or deliberately editing provenance."]}
    write_json(output / "report.json", report)
    print(json.dumps({mode: run["metrics"] for mode, run in runs.items()}, indent=2))
    print(f"Report: {output / 'report.json'}")
    return 0 if complete and (gate is None or all(gate.values())) else 1


if __name__ == "__main__":
    sys.exit(main())
