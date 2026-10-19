from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, tarfile, traceback
ROOT = Path("/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth")
BASE = Path("/home/grauk/Work/relm-phase9")
OUT = BASE / "source-install"
STATUS = BASE / "source-install-status.json"
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
    OUT.mkdir(exist_ok=False)
    save()
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "rebirth"], cwd=ROOT).decode().split("\0")
    sources = {name: sha(ROOT / name) for name in sorted(set(names)) if name and (ROOT / name).is_file()}
    extra = ["tests/cran/installed-package.R", "tools/prepare-cran-sources.py", "tests/cran/configuration.R", "tests/cran/test_source_bundles.py", ".gitattributes"]
    binding = {**sources, **{name: sha(ROOT / name) for name in extra}}
    (OUT / "source-before.json").write_text(json.dumps(binding, indent=2, sort_keys=True) + "\n")
    shutil.copy2(__file__, OUT / "driver.py")
    package = OUT / "package"
    for name in sources:
        destination = package / Path(name).relative_to("rebirth")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, destination)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("RELM_", "F6E_", "CUDA", "CARGO_", "CMAKE_")) or key in ("DEBUG", "MAKEFLAGS", "RUSTFLAGS", "RUSTC_WRAPPER", "CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "LD_LIBRARY_PATH", "RUSTUP_TOOLCHAIN"):
            env.pop(key, None)
    library = OUT / "library"; library.mkdir()
    env.update({"TMPDIR": str(BASE / "tmp"), "R_LIBS": str(library) + ":/home/grauk/.local/share/relm/phase8/R-library", "R_LIBS_USER": "/home/grauk/.local/share/relm/phase8/R-library", "R_ENVIRON_USER": "/dev/null", "R_PROFILE_USER": "/dev/null", "RELM_ENABLE_CUDA": "0", "RELM_ENABLE_SELFTESTS": "0", "NOT_CRAN": "false", "CARGO_NET_OFFLINE": "true", "CARGO_BUILD_JOBS": "2"})
    (OUT / "build-environment.json").write_text(json.dumps({k: env[k] for k in ("TMPDIR", "R_LIBS", "R_LIBS_USER", "RELM_ENABLE_CUDA", "RELM_ENABLE_SELFTESTS", "NOT_CRAN", "CARGO_NET_OFFLINE", "CARGO_BUILD_JOBS", "PATH")}, indent=2) + "\n")
    offline = OUT / "offline-resolution"; offline.mkdir()
    home = offline / ".cargo"; home.mkdir()
    shutil.copy2(package / "src/rust/vendor-config.toml", home / "config.toml")
    with tarfile.open(package / "src/rust/vendor.tar.xz") as tar: tar.extractall(offline, filter="data")
    offline_env = {**env, "CARGO_HOME": str(home)}
    for target in ("x86_64-unknown-linux-gnu", "x86_64-pc-windows-gnu", "aarch64-apple-darwin"):
        stage("metadata-" + target, ["cargo", "metadata", "--locked", "--offline", "--format-version=1", "--filter-platform", target, "--manifest-path", str(package / "src/rust/Cargo.toml")], offline, offline_env, 120)
    assert not (home / "registry").exists(), "Unexpected registry cache in offline validation"
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
