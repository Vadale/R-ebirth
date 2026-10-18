from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, tarfile, traceback
ROOT = Path("/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth")
BASE = Path("/home/grauk/Work/relm-phase9")
OUT = BASE / "source-install-build"
STATUS = BASE / "source-install-build-status.json"
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
state = {"status": "running", "pid": os.getpid(), "output": str(OUT), "stages": []}
def save():
    state["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp = STATUS.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n")
    tmp.replace(STATUS)
def stage(name, cmd, cwd, env, timeout=1800):
    state["stage"] = name; save()
    log = OUT / (name + ".log")
    with log.open("w") as output:
        output.write(json.dumps(cmd) + "\n"); output.flush()
        result = subprocess.run(cmd, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    state["stages"].append({"name": name, "returncode": result.returncode, "log_sha256": sha(log)})
    save()
    if result.returncode: raise RuntimeError(name + " failed; preserve passed stages")
    return log
try:
    OUT.mkdir(exist_ok=False); save()
    parent = BASE / "source-install"
    previous = json.loads((BASE / "source-install-status.json").read_text())
    assert previous["status"] == "failed" and len(previous["stages"]) == 3
    assert json.loads((parent / "diagnosis.json").read_text())["all_external_manifest_paths_in_shipped_vendor"]
    for item in previous["stages"]:
        assert item["returncode"] == 0 and sha(parent / (item["name"] + ".log")) == item["log_sha256"]
    binding = json.loads((parent / "source-before.json").read_text())
    assert binding == {name: sha(ROOT / name) for name in binding}
    package = parent / "package"
    assert all(sha(package / Path(name).relative_to("rebirth")) == h for name,h in binding.items() if name.startswith("rebirth/"))
    shutil.copy2(parent / "source-before.json", OUT / "source-before.json")
    shutil.copy2(parent / "diagnosis.json", OUT / "carried-metadata.json")
    shutil.copy2(__file__, OUT / "driver.py")
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("RELM_", "F6E_", "CUDA", "CARGO_", "CMAKE_")) or key in ("DEBUG", "MAKEFLAGS", "RUSTFLAGS", "RUSTC_WRAPPER", "CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "LD_LIBRARY_PATH", "RUSTUP_TOOLCHAIN"):
            env.pop(key, None)
    env.update(json.loads((parent / "build-environment.json").read_text()))
    library = OUT / "library"; library.mkdir()
    env.update({"R_LIBS": str(library) + ":/home/grauk/.local/share/relm/phase8/R-library", "R_ENVIRON_USER": "/dev/null", "R_PROFILE_USER": "/dev/null"})
    state["carried_metadata"] = previous["stages"]
    stage("source-build", ["R", "CMD", "build", "--no-build-vignettes", "--no-manual", str(package)], OUT, env)
    tars = list(OUT.glob("relm_*.tar.gz")); assert len(tars) == 1
    archive = tars[0]
    with tarfile.open(archive) as tar:
        files = [m for m in tar if m.isfile()]
        long_paths = [m.name for m in files if len(m.name.encode()) > 100]
        assert not long_paths, long_paths
        assert all("/src/llama.cpp/" not in m.name for m in files)
        assert sum(m.name.endswith("src/llama-sources.tar.xz") for m in files) == 1
        assert sum(m.name.endswith("src/rust/vendor.tar.xz") for m in files) == 1
        inventory = {m.name: hashlib.sha256(tar.extractfile(m).read()).hexdigest() for m in files}
    (OUT / "package-tar.json").write_text(json.dumps({"path": str(archive), "sha256": sha(archive), "bytes": archive.stat().st_size, "files": inventory, "long_paths": long_paths, "vignettes_built": False}, indent=2) + "\n")
    stage("install", ["R", "CMD", "INSTALL", "--library=" + str(library), str(archive)], OUT, env)
    dll = library / "relm/libs/relm.so"; assert dll.is_file()
    stage("dynamic-links", ["readelf", "-d", str(dll)], OUT, env, 30)
    links = (OUT / "dynamic-links.log").read_text()
    assert "TEXTREL" not in links and "libcudart" not in links and "libcublas" not in links
    stage("installed-check", ["Rscript", "--vanilla", str(ROOT / "tests/cran/installed-package.R"), str(library / "relm"), str(package), str(OUT / "installed-result.rds")], ROOT, env, 120)
    after = {name: sha(ROOT / name) for name in binding}
    assert binding == after, "Frozen repository inputs changed"
    (OUT / "source-after.json").write_text(json.dumps(after, indent=2, sort_keys=True) + "\n")
    installed = {str(p.relative_to(library)): sha(p) for p in sorted(library.rglob("*")) if p.is_file()}
    (OUT / "installed-hashes.json").write_text(json.dumps(installed, indent=2) + "\n")
    state.update(status="awaiting_owner_verification", source_files=len(binding), installed_files=len(installed), dll_sha256=sha(dll), scope="Fresh CPU source installation; full as-cran/vignettes/Windows remain pending")
except Exception as error:
    state.update(status="failed", error=str(error), traceback=traceback.format_exc())
    if OUT.is_dir(): (OUT / "failure.txt").write_text(state["traceback"])
finally:
    save()
