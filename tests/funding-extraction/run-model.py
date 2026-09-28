#!/usr/bin/env python3
"""Native D2 acceptance: real SIGKILL, offline fresh sessions, timings and RSS.

Requires an already installed relm build and a local pinned GGUF. Downloads and
installs nothing. Mac uses sandbox-exec; Linux uses sudo/unshare and drops back
to the caller's UID. Measurement and recovery use the application itself.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "examples/funding-extraction"


def read(path):
    return json.loads(path.read_text())


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def records(directory):
    return {path.name: path.read_bytes() for path in sorted((directory / "records").glob("*.json"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--model-alias", required=True)
    parser.add_argument("--r-library", type=Path, required=True)
    parser.add_argument("--backend", choices=["metal", "cpu"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    rscript = shutil.which("Rscript")
    if not rscript:
        raise RuntimeError("Rscript is required")
    system = platform.system()
    if system == "Darwin":
        isolation = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)"]
    elif system == "Linux":
        isolation = ["sudo", "-n", "unshare", "--net", "--", "setpriv",
                     f"--reuid={os.getuid()}", f"--regid={os.getgid()}", "--init-groups"]
    else:
        raise RuntimeError("Only Mac/Linux are in scope")
    shutil.copyfile(APP / "documents.json", output / "documents.json")
    shutil.copyfile(APP / "prompt.txt", output / "prompt.txt")
    shutil.copyfile(APP / "output.schema.json", output / "output.schema.json")
    config = read(APP / "config.json")
    config["backend"] = args.backend
    config_path = output / "config.json"
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    measurements = {}

    def launch(label, command, offline=True):
        resource = output / f"{label}.resources.txt"
        if system == "Darwin":
            timed = ["/usr/bin/time", "-l", "-o", str(resource)]
        else:
            timed = ["/usr/bin/time", "-f", "peak_rss_kib=%M\nwall_seconds=%e", "-o", str(resource)]
        log = (output / f"{label}.log").open("wb")
        started = time.monotonic()
        process = subprocess.Popen(timed + (isolation if offline else []) + command,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        return process, log, resource, started

    def finish(label, launched, killed=False):
        process, log, resource, started = launched
        try:
            code = process.wait(timeout=900)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        finally:
            log.close()
        text = resource.read_text()
        if system == "Darwin":
            peak = next(int(line.split()[0]) for line in text.splitlines()
                        if "maximum resident set size" in line)
        else:
            peak = next(int(line.split("=", 1)[1]) * 1024 for line in text.splitlines()
                        if line.startswith("peak_rss_kib="))
        measurements[label] = {"wall_seconds": round(time.monotonic() - started, 6),
                               "peak_rss_bytes": peak, "exit_code": code}
        if (killed and code == 0) or (not killed and code != 0):
            raise RuntimeError(f"{label} exited {code}; see {output / (label + '.log')}")

    with tempfile.TemporaryDirectory(prefix="relm-d2-model-") as work:
        environment = Path(work) / "environment"
        setup = [rscript, "--vanilla", str(APP / "setup.R"), "--environment", str(environment),
                 "--relm-library", str(args.r_library.resolve()), "--model", str(args.model.resolve()),
                 "--model-alias", args.model_alias]
        finish("setup", launch("setup", setup, offline=False))
        shutil.copyfile(environment / "environment.json", output / "environment.json")
        worker = [rscript, "--vanilla", str(Path(__file__).with_name("model-worker.R")),
                  str(ROOT), str(config_path), str(environment)]
        full = output / "uninterrupted"
        finish("uninterrupted", launch("uninterrupted", worker + [str(full), "run"]))
        first = read(full / "summary.json")
        assert first["processed"] == 3 and first["errors"] == 0
        interrupted = output / "resumed"
        marker = output / "kill-checkpoint.json"
        launched = launch("interrupted", worker + [str(interrupted), "run", str(marker)])
        deadline = time.monotonic() + 900
        while not marker.exists():
            if launched[0].poll() is not None or time.monotonic() > deadline:
                if launched[0].poll() is None:
                    os.killpg(launched[0].pid, signal.SIGKILL)
                finish("interrupted", launched)
                raise RuntimeError("Worker did not reach the real commit boundary")
            time.sleep(0.05)
        committed = records(interrupted)
        assert list(committed) == ["ace22-total.json"]
        os.kill(read(marker)["pid"], signal.SIGKILL)
        finish("interrupted", launched, killed=True)
        nonce = read(interrupted / ".lock" / "owner.json")["nonce"]
        recovery = [rscript, "--vanilla", str(APP / "run.R"), "--environment", str(environment),
                    "--output", str(interrupted), "--recover-lock", nonce, "--confirm-owner-stopped"]
        finish("recovery", launch("recovery", recovery))
        finish("resume", launch("resume", worker + [str(interrupted), "run"]))
        resumed = read(interrupted / "summary.json")
        assert resumed["processed"] == 2 and resumed["reused"] == 1 and resumed["errors"] == 0
        current = records(interrupted)
        assert len(current) == 3 and current["ace22-total.json"] == committed["ace22-total.json"]
        # Compare semantic/raw outputs, preserving timing differences across runs.
        for name, data in records(full).items():
            a, b = json.loads(data), json.loads(current[name])
            for value in (a, b):
                del value["elapsed_seconds"], value["record_sha256"]
            assert a == b, f"Fresh/resumed output differs: {name}"
        finish("reuse", launch("reuse", worker + [str(interrupted), "run"]))
        reused = read(interrupted / "summary.json")
        assert reused["processed"] == 0 and reused["reused"] == 3
        assert records(interrupted) == current
        result = {"platform": platform.platform(), "backend": args.backend,
                  "offline_isolation": "sandbox-exec deny network*" if system == "Darwin" else "unshare --net with caller UID",
                  "application_sha256": digest(APP / "app.R"), "model_alias": args.model_alias,
                  "measurements": measurements, "first_run": first, "resumed_run": resumed,
                  "final_reuse": reused,
                  "acceptance": "Offline run, real SIGKILL, explicit recovery, immutable commits and duplicate-free resume passed",
                  "quality_scope": "Operational acceptance only; invalid extraction records remain visible and terminal"}
        (output / "acceptance.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
