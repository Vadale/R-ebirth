#!/usr/bin/env python3
"""Explicit local subscription-client evaluation; never an ordinary CI test.

Run this script detached. It writes durable status and never retries a case.
Only synthetic fixtures are staged. Each case retains its prompt and events.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def save(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--case", action="append", dest="cases")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--model", help="Explicit model from this client's live catalog")
    parser.add_argument("--reasoning", choices=["low", "medium", "high", "xhigh", "max", "ultra"])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = Path(__file__).with_name("cases.json")
    cases = json.loads(spec.read_text())
    if args.cases:
        if set(args.cases) - {c["id"] for c in cases}:
            parser.error("Unknown case")
        cases = [c for c in cases if c["id"] in args.cases]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    status = dict(state="running", pid=os.getpid(), started=time.time(),
                  cases_sha256=digest(spec), results=[])
    save(out / "status.json", status)
    codex = shutil.which("codex")
    if not codex:
        status.update(state="failed", error="Codex runtime missing")
        save(out / "status.json", status)
        return 1
    version = subprocess.run([codex, "--version"], capture_output=True, text=True,
                             timeout=15, check=True).stdout.strip()
    save(out / "client.json", dict(version=version, executable=codex,
         model=args.model or "inherited", reasoning=args.reasoning or "inherited",
         settings="Per-invocation overrides only; user configuration unchanged",
         isolation="workspace-write, approvals never, ephemeral; ambient skills retained"))
    try:
        for case in cases:
            work = out / case["id"]
            work.mkdir()
            (work / "prompt.txt").write_text(case["prompt"] + "\n")
            if case["id"] == "longitudinal":
                shutil.copy2(root / "tests/skills/r-statistical-analysis/evidence/observations.csv",
                             work / "observations.csv")
            elif case["id"] == "fit_warning":
                with (work / "observations.csv").open("w", newline="") as f:
                    writer = csv.writer(f)
                    writer.writerow(["x", "outcome"])
                    for i in range(-12, 13):
                        writer.writerow([i / 4, int(i >= 0)])
            elif case["id"] != "missing_package":
                with (work / "observations.csv").open("w", newline="") as f:
                    writer = csv.writer(f)
                    writer.writerow(["id", "group", "outcome"])
                    values = [[10, 11, 9, 12, 8, 10, 13, 9, 11, 7, 10, 12],
                              [13, 15, 12, 16, 11, 14, 15, 13, 17, 12, 14, 16]]
                    for g, group in enumerate(["A", "B"]):
                        for i, value in enumerate(values[g][:1] if case["id"] == "insufficient" else values[g]):
                            writer.writerow([f"{group}{i+1:02}", group, value])
            data = work / "observations.csv"
            inputs = {"observations.csv": digest(data)} if data.exists() else {}
            start = time.time()
            status.update(active_case=case["id"])
            save(out / "status.json", status)
            command = [codex, "-a", "never", "exec", "--sandbox", "workspace-write",
                       "--ephemeral", "--skip-git-repo-check", "--json", "--color", "never",
                       "-C", str(work), "-o", str(work / "answer.md"), "-"]
            if args.model:
                command[1:1] = ["--model", args.model]
            if args.reasoning:
                command[1:1] = ["-c", 'model_reasoning_effort="' + args.reasoning + '"']
            # stdin avoids shell substitution; host sandbox/approval enforcement stays on.
            with (work / "events.jsonl").open("wb") as events, (work / "client.stderr").open("wb") as errors:
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=events,
                                           stderr=errors, start_new_session=True)
                timed_out = False
                try:
                    process.communicate(case["prompt"].encode(), timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
            result = dict(id=case["id"], mode=case["mode"], exit_code=process.returncode,
                          timeout=timed_out, seconds=time.time()-start,
                          prompt_sha256=digest(work / "prompt.txt"), input_sha256=inputs,
                          events_sha256=digest(work / "events.jsonl"),
                          outcome="requires semantic/artifact review")
            save(work / "receipt.json", result)
            status["results"].append(result)
            save(out / "status.json", status)
            if process.returncode != 0 or timed_out:
                raise RuntimeError(f"Client infrastructure failure in {case['id']}; inspect before continuing")
        status.update(state="complete", finished=time.time(), active_case=None)
    except Exception as error:
        status.update(state="failed", error=str(error), finished=time.time())
    save(out / "status.json", status)
    return 0 if status["state"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
