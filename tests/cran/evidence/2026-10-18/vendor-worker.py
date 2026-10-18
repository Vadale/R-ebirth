import hashlib, json, os, pathlib, subprocess, time, traceback
root = pathlib.Path("/home/grauk/Work/relm-phase9")
repo = pathlib.Path("/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth")
status = root / "vendor-status.json"
lock = repo / "rebirth/src/rust/Cargo.lock"
before = hashlib.sha256(lock.read_bytes()).hexdigest()
def save(state, **details):
    temporary = status.with_suffix(".new")
    temporary.write_text(json.dumps(dict(status=state, pid=os.getpid(), lock_sha256=before, **details), indent=2)+"\n")
    temporary.replace(status)
try:
    save("running")
    command = ["cargo", "vendor", "--locked", "--versioned-dirs", "--manifest-path", str(lock.with_name("Cargo.toml")), str(root / "vendor")]
    with (root / "vendor-config-original.toml").open("w") as out, (root / "vendor.log").open("w") as err:
        result = subprocess.run(command, cwd=repo, stdout=out, stderr=err, env=dict(os.environ, TMPDIR=str(root / "tmp")))
    assert result.returncode == 0, f"cargo vendor exited {result.returncode}; see vendor.log"
    assert hashlib.sha256(lock.read_bytes()).hexdigest() == before, "Cargo.lock changed"
    save("awaiting_owner_verification", crates=len(list((root / "vendor").iterdir())))
except Exception:
    save("failed", error=traceback.format_exc())
    raise
