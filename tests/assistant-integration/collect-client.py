#!/usr/bin/env python3
"""Collect completed synthetic case artifacts; this is not a statistical grader.

Full events remain local: executed third-party skill text and unrelated client
context must not be redistributed. Exact event hashes and observed commands are
recorded, while code, data and analysis outputs are kept for review and replay.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(source, destination):
    receipt = json.loads((source / "receipt.json").read_text())
    events = source / "events.jsonl"
    if sha(events) != receipt["events_sha256"]:
        raise ValueError("Client event stream no longer matches its receipt")
    commands, messages, usage = [], [], None
    for line in events.read_text().splitlines():
        event = json.loads(line)
        if event.get("type") == "turn.completed":
            usage = event.get("usage")
        item = event.get("item", {})
        if event.get("type") != "item.completed":
            continue
        if item.get("type") == "command_execution":
            output = item.get("aggregated_output", "")
            commands.append({"id": item.get("id"), "command": item.get("command"),
                             "exit_code": item.get("exit_code"),
                             "output_sha256": hashlib.sha256(output.encode()).hexdigest()})
        elif item.get("type") == "agent_message":
            messages.append(item.get("text", ""))
    if destination.exists() or destination.is_symlink():
        raise ValueError("Evidence destination already exists")
    destination.mkdir(parents=True)
    excluded = {"events.jsonl", "client.stderr", "receipt.json", ".agents", ".git"}
    files = {}
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(part in excluded for part in relative.parts):
            continue
        if path.is_symlink():
            raise ValueError(f"Unexpected evidence symlink: {relative}")
        if path.is_file():
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            files[relative.as_posix()] = sha(path)
    result = dict(receipt=receipt, commands=commands, messages=messages, usage=usage,
                  artifacts_sha256=files, source_event_sha256=sha(events),
                  note="Recorded observations only. Selection, correctness and interpretation require review.")
    (destination / "client-receipt.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    collect(args.source.resolve(), args.destination.absolute())
