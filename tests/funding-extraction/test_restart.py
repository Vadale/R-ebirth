#!/usr/bin/env python3
"""D2 process/filesystem acceptance with an injected deterministic engine.

Python standard library only. No model loading, inference, package installation
or network access. Ordinary Mac/Linux application CI and local execution.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).resolve().parent
APP = ROOT / "examples" / "funding-extraction"
S0 = ROOT / "tests" / "structured-output"
SYNTHETIC = ROOT / "rebirth" / "tests" / "testthat" / "fixtures" / "synthetic-llama-2l.gguf"


def canonical(value):
    """Independent S0 encoding: sorted keys, compact UTF-8, no float values."""
    if isinstance(value, float):
        raise AssertionError("Canonical fixture values must not be floats")
    if isinstance(value, list):
        for item in value:
            canonical(item)
    if isinstance(value, dict):
        for item in value.values():
            canonical(item)
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise AssertionError(f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(AssertionError(value)))


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value))


def read_json(path):
    return strict_json(path.read_bytes())


@contextlib.contextmanager
def replace_bytes(path, data):
    previous = path.read_bytes()
    path.write_bytes(data)
    try:
        yield
    finally:
        path.write_bytes(previous)


@contextlib.contextmanager
def append_corruption(path):
    size = path.stat().st_size
    with path.open("ab") as stream:
        stream.write(b"D2 mutation sentinel")
    try:
        yield
    finally:
        with path.open("r+b") as stream:
            stream.truncate(size)


class Harness:
    def __init__(self, directory, library, rscript):
        self.directory = directory
        self.library = library
        self.rscript = rscript
        self.environment = directory / "environment"
        self.input = directory / "input"
        self.input.mkdir(parents=True)
        self.controls = directory / "workers"
        self.controls.mkdir()
        self.counter = 0
        self.checks = 0
        self.children = []
        self.model = directory / "synthetic.gguf"
        shutil.copyfile(SYNTHETIC, self.model)
        self.documents = [
            {"id": "doc-1", "target": "Fixture programme one", "text": "Fixture café 😀: $12 provided for three years.", "seed": 101},
            {"id": "doc-2", "target": "Fixture programme two", "text": "Fixture: $25 provided for two years.", "seed": 102},
            {"id": "doc-3", "target": "Fixture programme three", "text": "Fixture: $7 provided for one year. Literal {{target}} stays text.", "seed": 103},
        ]
        self.output_text = {}
        for document, amount, years, duration in zip(self.documents, [12, 25, 7], [3, 2, 1], ["three years", "two years", "one year"]):
            output = {"amount_usd": amount, "amount_qualifier": "stated",
                      "duration_years": years, "conditional_on_funds": None,
                      "evidence": {"amount_usd": "$" + str(amount), "amount_qualifier": "$" + str(amount),
                                   "duration_years": duration, "conditional_on_funds": None}}
            self.output_text[str(document["seed"])] = canonical(output).decode()
        self.config = {"format_version": 1, "prompt": "prompt.txt", "schema": "schema.json",
                       "documents": "documents.json", "backend": "cpu", "context": 512,
                       "max_tokens": 128, "temperature": "0", "top_p": "0.95", "chat": True}
        self.config_path = self.input / "config.json"
        write_json(self.config_path, self.config)
        write_json(self.input / "documents.json", self.documents)
        (self.input / "prompt.txt").write_text("Extract the requested funding fields. Return JSON.\nTARGET: {{target}}\nTEXT: {{text}}\nSCHEMA: {{schema}}\n", encoding="utf-8")
        shutil.copyfile(S0 / "output.schema.json", self.input / "schema.json")

    def check(self, condition, message):
        self.checks += 1
        if not condition:
            raise AssertionError(message)

    def prepare_worker(self, action, **fields):
        self.counter += 1
        stem = self.controls / f"{self.counter:03d}-{action}"
        control = {"action": action, "result": str(stem.with_suffix(".result.json")),
                   "environment": str(self.environment), "config": str(self.config_path),
                   "output_text": self.output_text, **{key: str(value) if isinstance(value, Path) else value for key, value in fields.items()}}
        path = stem.with_suffix(".control.json")
        write_json(path, control)
        command = [self.rscript, "--vanilla", str(TESTS / "worker.R"), str(ROOT), str(self.library), str(path), control["environment"]]
        if fields.get("preload_outside"):
            command.append("preload-outside")
        return command, control, stem

    def invoke(self, action, error=False, **fields):
        command, control, stem = self.prepare_worker(action, **fields)
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        stem.with_suffix(".log").write_bytes(result.stdout)
        metadata = read_json(Path(control["result"])) if Path(control["result"]).exists() else {}
        wanted = 23 if error else 0
        self.check(result.returncode == wanted,
                   f"{action}: expected exit {wanted}, got {result.returncode}: {metadata}\n{result.stdout.decode(errors='replace')}")
        if error:
            self.check(bool(metadata.get("message")), "A rejected action must report a concrete error")
            self.check(any(name.startswith("funding_error_") for name in metadata.get("error_class", [])),
                       "A rejected action must use an intentional application condition")
        return metadata

    def run(self, output, attempts=None, error=False, **fields):
        if attempts is None:
            attempts = self.directory / f"attempts-{self.counter + 1:03d}.jsonl"
        return self.invoke("run", error=error, output=output, attempts=attempts, **fields)

    def setup(self):
        command = [self.rscript, "--vanilla", str(APP / "setup.R"), "--environment", str(self.environment),
                   "--relm-library", str(self.library), "--model", str(self.model),
                   "--model-sha256", digest(self.model.read_bytes())]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        (self.directory / "setup.log").write_bytes(result.stdout)
        self.check(result.returncode == 0, f"Real setup failed:\n{result.stdout.decode(errors='replace')}")
        self.prepared = self.invoke("environment")
        self.check(Path(self.prepared["model"]) == self.model, "Setup must reference the supplied model path")
        self.check(self.prepared["manifest"]["model"]["sha256"] == digest(self.model.read_bytes()), "Setup model digest differs")
        error = self.invoke("environment", error=True, preload_outside=True)
        self.check("unprepared namespace" in error["message"], "Preloaded outside package was not explicitly refused")

    def canonical_contract(self):
        s0 = read_json(S0 / "batch-contract.json")
        fixtures = [
            ("s0-config", s0["manifest"]["config"], s0["manifest"]["run_identity"]),
            ("s0-output", s0["results"][0]["output"], s0["results"][0]["output_sha256"]),
            ("unicode-nulls", {"null": None, "array": [None, True, False, 0, -2147483648], "empty_object": {}, "empty_array": [], "é": "café 😀 e\u0301\n\t\b\f\r/\\\"", "a": "line\u2028separator", "z": "end"}, None),
        ]
        for name, value, expected_hash in fixtures:
            source = self.directory / f"{name}.input.json"
            target = self.directory / f"{name}.canonical.json"
            source.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
            metadata = self.invoke("canonical", input=source, output=target)
            self.check(target.read_bytes() == canonical(value), f"R canonical bytes differ for {name}")
            self.check(metadata["sha256"] == digest(canonical(value)), f"R SHA256 differs for {name}")
            if expected_hash:
                self.check(metadata["sha256"] == expected_hash, f"S0 artifact digest differs for {name}")
        escaped = self.directory / "escaped-unicode.input.json"
        escaped.write_bytes(b'{"paired":"\\ud83d\\ude00","lowest":"\\ud800\\udc00","highest":"\\udbff\\udfff","literal":"\\\\ud800"}')
        expected = read_json(escaped)
        self.check(expected["paired"] == "😀" and expected["literal"] == "\\ud800", "Independent Unicode fixture is malformed")
        target = self.directory / "escaped-unicode.canonical.json"
        self.invoke("canonical", input=escaped, output=target)
        self.check(target.read_bytes() == canonical(expected), "Surrogate pairs or escaped-backslash literals changed")
        for name, data in [
            ("duplicate", b'{"id":1,"id":2}'),
            ("escaped-duplicate", b'{"id":1,"\\u0069d":2}'),
            ("lone-surrogate", b'{"value":"\\ud800"}'),
            ("lone-low-surrogate", b'{"value":"\\udc00"}'),
            ("bad-surrogate-pair", b'{"value":"\\ud800\\u0041"}'),
            ("reversed-surrogates", b'{"value":"\\udc00\\ud800"}'),
            ("escaped-nul", b'{"value":"\\u0000"}'),
            ("invalid-utf8", b'{"value":"\xff"}'),
            ("decimal-integer", b'{"seed":101.0}'),
            ("lossy-decimal", b'{"seed":101.00000000000000001}'),
            ("exponent-integer", b'{"seed":1e2}'),
        ]:
            path = self.directory / f"{name}.json"
            path.write_bytes(data)
            self.invoke("read", input=path, error=True)

    def attempts(self, path):
        if not path.exists():
            return []
        return [strict_json(line) for line in path.read_bytes().splitlines() if line]

    def seeds(self, path):
        return [entry["seed"] for entry in self.attempts(path) if entry["kind"] == "generate"]

    def verify_records(self, output, statuses=None):
        manifest_path = output / "manifest.json"
        manifest = read_json(manifest_path)
        self.check(manifest_path.read_bytes() == canonical(manifest), "Manifest bytes are not canonical")
        identity = digest(canonical(manifest["config"]))
        self.check(manifest["run_identity"] == identity, "Manifest identity is not content-addressed")
        files = {path.name for path in (output / "records").glob("*.json")}
        self.check(files == {f'{document["id"]}.json' for document in self.documents}, "Missing/duplicate/unknown committed records")
        for document in self.documents:
            path = output / "records" / f'{document["id"]}.json'
            data = path.read_bytes()
            record = strict_json(data)
            self.check(data == canonical(record), "Committed record bytes are not canonical")
            self.check(record["id"] == document["id"] and record["seed"] == document["seed"], "Record ID/seed mismatch")
            self.check(record["run_identity"] == identity, "Record has stale run identity")
            self.check(record["source_sha256"] == digest(canonical({key: document[key] for key in ("target", "text")})), "Source identity is not canonical target/text content")
            self.check(record["state"] == "committed", "Incomplete record published as authoritative")
            body = {key: value for key, value in record.items() if key != "record_sha256"}
            self.check(record["record_sha256"] == digest(canonical(body)), "Record digest mismatch")
            status = (statuses or {}).get(document["id"], "success")
            self.check(record["status"] == status, f"Unexpected status for {document['id']}")
            if status == "success":
                expected = strict_json(self.output_text[str(document["seed"])])
                self.check(record["output"] == expected, "Injected fixture output changed")
                self.check(record["output_sha256"] == digest(canonical(expected)), "Output digest mismatch")
            else:
                self.check(record["output"] is None, "Unsuccessful output must remain null")
                self.check(record["output_sha256"] is None, "Unsuccessful output digest must remain null")
        self.check((output / "results.csv").is_file() and (output / "summary.json").is_file(), "Derived summaries missing")

    def fresh_output(self, name):
        return self.directory / name

    def normal_and_idempotent(self):
        output = self.fresh_output("complete")
        attempts = self.directory / "complete-attempts.jsonl"
        result = self.run(output, attempts)
        self.check(result["rows"] == 3, "app_run must return the three ordinary table rows")
        self.verify_records(output)
        before = {path: path.read_bytes() for path in (output / "records").glob("*.json")}
        self.run(output, attempts)
        self.check(self.seeds(attempts) == [101, 102, 103], "Completed records were regenerated")
        self.check(all(path.read_bytes() == data for path, data in before.items()), "Resume rewrote committed bytes")
        for document, attempt in zip(self.documents, [x for x in self.attempts(attempts) if x["kind"] == "generate"]):
            self.check(document["target"] in attempt["prompt"] and document["text"] in attempt["prompt"], "Prompt lost target/source text")
        self.completed = output

    def rejected_without_generation(self, **fields):
        attempts = self.directory / f"rejected-{self.counter + 1}.jsonl"
        snapshots = {path: path.read_bytes() for path in (self.completed / "records").glob("*.json")}
        self.run(self.completed, attempts, error=True, **fields)
        self.check(not self.seeds(attempts), "Rejected resume invoked generation")
        self.check(all(path.read_bytes() == data for path, data in snapshots.items()), "Rejected resume modified committed bytes")

    def stale_identities(self):
        with append_corruption(self.model):
            self.rejected_without_generation()
        for filename in ["prompt.txt", "schema.json"]:
            path = self.input / filename
            with replace_bytes(path, path.read_bytes() + b"\n"):
                self.rejected_without_generation()
        for field in ["target", "text", "seed"]:
            changed = json.loads(json.dumps(self.documents))
            changed[0][field] = changed[0][field] + (1 if field == "seed" else " changed")
            with replace_bytes(self.input / "documents.json", canonical(changed)):
                self.rejected_without_generation()
        changed = {**self.config, "max_tokens": 129}
        with replace_bytes(self.config_path, canonical(changed)):
            self.rejected_without_generation()
        library = Path(self.prepared["library"])
        native = [path for path in (library / "relm" / "libs").rglob("*") if path.is_file() and path.suffix in (".so", ".dylib", ".dll")]
        self.check(bool(native), "Prepared environment lacks a native relm library to fingerprint")
        with append_corruption(native[0]):
            self.rejected_without_generation()

    def corrupt_and_unknown_records(self):
        path = self.completed / "records" / "doc-1.json"
        record = read_json(path)
        mutations = []
        for key, value in [("run_identity", "0" * 64), ("source_sha256", "0" * 64), ("seed", 999),
                           ("output_sha256", "0" * 64), ("record_sha256", "0" * 64), ("unexpected", True)]:
            changed = {**record, key: value}
            if key != "record_sha256":
                changed["record_sha256"] = digest(canonical({k: v for k, v in changed.items() if k != "record_sha256"}))
            mutations.append(canonical(changed))
        changed = json.loads(json.dumps(record))
        changed["output"]["amount_usd"] = 999
        changed["record_sha256"] = digest(canonical({k: v for k, v in changed.items() if k != "record_sha256"}))
        mutations.append(canonical(changed))
        mutations.extend([b'{"broken":', b'{"\\u0069d":"doc-1",' + path.read_bytes()[1:]])
        for data in mutations:
            with replace_bytes(path, data):
                self.rejected_without_generation()
        unknown = self.completed / "records" / "unknown.json"
        write_json(unknown, {**record, "id": "unknown"})
        try:
            self.rejected_without_generation()
        finally:
            unknown.unlink()

    def invalid_inputs(self):
        def reject_new():
            output = self.directory / f"invalid-{self.counter + 1}"
            attempts = self.directory / f"invalid-{self.counter + 1}.attempts.jsonl"
            self.run(output, attempts, error=True)
            self.check(not self.seeds(attempts), "Invalid fresh input reached generation")
            self.check(not list((output / "records").glob("*.json")), "Invalid fresh input published records")

        for config in [{**self.config, "unexpected": True}, {**self.config, "context": -1},
                       {**self.config, "temperature": 0.0}, {**self.config, "chat": "true"}]:
            data = json.dumps(config, separators=(",", ":")).encode()
            with replace_bytes(self.config_path, data):
                reject_new()
        for documents in [self.documents + [self.documents[0]],
                          [{**self.documents[0], "unexpected": True}, *self.documents[1:]],
                          [{**self.documents[0], "id": "../escape"}, *self.documents[1:]]]:
            with replace_bytes(self.input / "documents.json", canonical(documents)):
                reject_new()
        for spelling in ["101.0", "101.00000000000000001", "1.01e2"]:
            data = canonical(self.documents).replace(b'"seed":101', ('"seed":' + spelling).encode(), 1)
            with replace_bytes(self.input / "documents.json", data):
                reject_new()

    def pause_writer(self, output, attempts, stage):
        marker = self.directory / f"{stage}.barrier.json"
        command, _, stem = self.prepare_worker("run", output=output, attempts=attempts,
                                              pause_stage=stage, pause_id="doc-2", marker=marker)
        log = stem.with_suffix(".log").open("wb")
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        self.children.append((process, log))
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if marker.exists():
                try:
                    barrier = read_json(marker)
                except ValueError:
                    time.sleep(0.05)
                    continue
                self.check(barrier["pid"] == process.pid, "Barrier PID differs from our child")
                return process
            if process.poll() is not None:
                raise AssertionError(f"Writer exited before {stage}: {stem.with_suffix('.log').read_text()}")
            time.sleep(0.05)
        raise AssertionError(f"Writer did not reach {stage} within 45 seconds")

    def recover(self, output, nonce, error=False, confirmed=True):
        return self.invoke("recover", output=output, nonce=nonce,
                           confirm_owner_stopped=confirmed, error=error)

    def kill_and_resume(self, stage):
        output = self.fresh_output(stage)
        attempts = self.directory / f"{stage}.attempts.jsonl"
        process = self.pause_writer(output, attempts, stage)
        owner_path = output / ".lock" / "owner.json"
        owner = read_json(owner_path)
        self.check(owner["pid"] == process.pid and bool(owner["nonce"]), "Lock owner identity differs")
        expected_committed = 1 if stage == "before_record_rename" else 2
        committed = {path: path.read_bytes() for path in (output / "records").glob("*.json")}
        self.check(len(committed) == expected_committed, "Checkpoint is on the wrong side of rename")
        second_attempts = self.directory / f"{stage}.second-attempts.jsonl"
        self.run(output, second_attempts, error=True)
        self.check(not self.seeds(second_attempts), "Second writer reached the engine")
        self.recover(output, owner["nonce"], error=True)
        self.check(process.poll() is None and owner_path.exists(), "Live-owner recovery disturbed the active writer")
        process.kill()
        process.wait(timeout=10)
        self.check(process.returncode == -signal.SIGKILL, "Process was not terminated by SIGKILL")
        self.check(all(path.read_bytes() == data for path, data in committed.items()), "SIGKILL changed committed bytes")
        self.recover(output, "wrong-nonce", error=True)
        self.recover(output, owner["nonce"], error=True, confirmed=False)
        foreign = {**owner, "hostname": "different-host.invalid"}
        with replace_bytes(owner_path, canonical(foreign)):
            self.recover(output, owner["nonce"], error=True)
        self.recover(output, owner["nonce"])
        self.check(not (output / ".lock").exists(), "Recovery did not free the writer lock")
        with (output / "events.jsonl").open("ab") as stream:
            stream.write(b'{"unfinished_diagnostic":')
        (output / "records" / (".tmp-" + "f" * 32)).write_bytes(b"not a committed result")
        self.run(output, attempts)
        self.verify_records(output)
        self.check(all(path.read_bytes() == data for path, data in committed.items()), "Resume rewrote previously committed bytes")
        expected_seeds = [101, 102, 102, 103] if stage == "before_record_rename" else [101, 102, 103]
        self.check(self.seeds(attempts) == expected_seeds, "Unfinished documents did not retry with the same seed")

    def ownerless_recovery(self):
        for partial_owner in [False, True]:
            output = self.fresh_output("partial-owner-lock" if partial_owner else "ownerless-lock")
            (output / ".lock").mkdir(parents=True)
            if partial_owner:
                # Filesystem state after death before the owner-file rename.
                (output / ".lock" / (".tmp-" + "a" * 32)).write_bytes(b'{"unfinished":')
            self.recover(output, "wrong-nonce", error=True)
            self.recover(output, "empty", error=True, confirmed=False)
            self.recover(output, "empty")
            self.run(output)
            self.verify_records(output)

    def terminal_failures(self):
        output = self.fresh_output("terminal-failures")
        attempts = self.directory / "terminal-attempts.jsonl"
        answers = {**self.output_text, "102": "{broken fixture output"}
        self.run(output, attempts, output_text=answers, error_seed=103)
        self.verify_records(output, {"doc-2": "invalid", "doc-3": "error"})
        before = {path: path.read_bytes() for path in (output / "records").glob("*.json")}
        self.run(output, attempts)
        self.check(self.seeds(attempts) == [101, 102, 103], "Terminal invalid/error records were retried")
        self.check(all(path.read_bytes() == data for path, data in before.items()), "Terminal records were rewritten")
        self.check(read_json(output / "records" / "doc-2.json")["raw_output"] == answers["102"], "Invalid raw output was lost")
        self.check("Controlled fixture engine failure" in json.dumps(read_json(output / "records" / "doc-3.json")["error"]), "Engine condition was lost")

    def cleanup_children(self):
        for process, log in self.children:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            log.close()

    def execute(self):
        self.setup()
        self.canonical_contract()
        self.normal_and_idempotent()
        self.stale_identities()
        self.corrupt_and_unknown_records()
        self.invalid_inputs()
        self.kill_and_resume("before_record_rename")
        self.kill_and_resume("after_record_rename")
        self.ownerless_recovery()
        self.terminal_failures()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relm-library", type=Path, required=True, help="Existing installed relm library; setup snapshots it")
    parser.add_argument("--work-dir", type=Path, help="New empty directory to retain all process artifacts")
    parser.add_argument("--rscript", default="Rscript")
    arguments = parser.parse_args()
    if os.name != "posix":
        parser.error("SIGKILL/lock acceptance currently targets local macOS and Linux filesystems")
    directory = arguments.work_dir.resolve() if arguments.work_dir else Path(tempfile.mkdtemp(prefix="relm-d2-process-")).resolve()
    if arguments.work_dir:
        directory.mkdir(parents=True, exist_ok=False)
    harness = Harness(directory, arguments.relm_library.resolve(strict=True), arguments.rscript)
    started = time.monotonic()
    try:
        harness.execute()
        print(f"PASS: {harness.checks} D2 process/canonical/identity assertions in {time.monotonic() - started:.2f}s")
        print("No model loading or inference; no extraction-quality or power-loss durability claim.")
    finally:
        harness.cleanup_children()
        print(f"Artifacts: {directory}")


if __name__ == "__main__":
    main()
