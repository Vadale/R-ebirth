"""One isolated Linux installation with a real non-shared R; no model calls.

CI-only checking tools, not package dependencies or an installation bootstrap.
Run from the repository root with a new, disk-backed output directory.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import urllib.error


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    root = Path.cwd()
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    for key in ("R_HOME", "R_ARCH", "R_LIBS", "R_LIBS_USER", "R_LIBS_SITE",
                "R_INCLUDE_DIR", "RUSTFLAGS", "LD_LIBRARY_PATH", "DEBUG"):
        env.pop(key, None)
    temp = out / "tmp"
    temp.mkdir()
    env.update(TMPDIR=str(temp), R_ENVIRON_USER="/dev/null", R_PROFILE_USER="/dev/null",
               RELM_ENABLE_CUDA="0", RELM_ENABLE_SELFTESTS="0", NOT_CRAN="false",
               CARGO_NET_OFFLINE="true", CARGO_BUILD_JOBS="2",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", _R_CHECK_LIMIT_CORES_="true")
    records = []

    def run(name, command, cwd=out):
        started = time.monotonic()
        with (out / (name + ".log")).open("w") as log:
            log.write(json.dumps([str(x) for x in command]) + "\n")
            log.flush()
            result = subprocess.run(command, cwd=cwd, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=2400)
        records.append(dict(stage=name, seconds=time.monotonic() - started,
                            returncode=result.returncode, log_sha256=sha(out / (name + ".log"))))
        (out / "stages.json").write_text(json.dumps(records, indent=2) + "\n")
        result.check_returncode()

    inputs = [
        ("R-4.6.1.tar.gz", "https://cran.r-project.org/src/base/R-4/",
         "4da6e61d2c0aac5f14a2e7e432cb5fcc269efe83da4293050ba7f03dff4e2cf4"),
        ("nanoarrow_0.9.0.tar.gz", "https://cran.r-project.org/src/contrib/",
         "c3b6bff407f0bd57f74991ca88460723e1aacc06747ff6f1eff2fc07a6771a55"),
    ]
    for name, base, digest in inputs:
        try:
            response = urllib.request.urlopen(base + name, timeout=90)
        except urllib.error.HTTPError as error:
            if error.code != 404 or not name.startswith("nanoarrow_"):
                raise
            response = urllib.request.urlopen(base + "Archive/nanoarrow/" + name, timeout=90)
        with response, (out / name).open("wb") as stream:
            shutil.copyfileobj(response, stream)
        assert sha(out / name) == digest, name
    (out / "downloads.json").write_text(json.dumps(inputs, indent=2) + "\n")
    with tarfile.open(out / "R-4.6.1.tar.gz") as archive:
        archive.extractall(out, filter="data")
    source = out / "R-4.6.1"
    build = out / "r-build"
    build.mkdir()
    run("r-configure", [source / "configure", "--prefix=" + str(out / "R"),
        "--disable-R-shlib", "--without-recommended-packages", "--with-x=no",
        "--with-tcltk=no", "--with-readline=no", "--disable-nls"], build)
    run("r-build", ["make", "-j2"], build)
    run("r-install", ["make", "install"], build)
    r = out / "R/bin/R"
    rscript = out / "R/bin/Rscript"
    env["PATH"] = str(r.parent) + os.pathsep + env["PATH"]
    rhome = Path(subprocess.check_output([r, "RHOME"], env=env, text=True).strip())
    assert not list(rhome.rglob("libR.so*")), "Unexpected shared R library"
    run("r-linkage", ["ldd", rhome / "bin/exec/R"])
    assert "libR.so" not in (out / "r-linkage.log").read_text()
    library = out / "library"
    library.mkdir()
    env["R_LIBS_USER"] = str(library)
    run("nanoarrow-install", [r, "CMD", "INSTALL", "--library=" + str(library), out / inputs[1][0]])
    codetools = list((source / "src/library/Recommended").glob("codetools_*.tar.gz"))
    assert len(codetools) == 1
    run("codetools-install", [r, "CMD", "INSTALL", "--library=" + str(library), codetools[0]])
    package = out / "package"
    files = subprocess.check_output(["git", "ls-files", "-z", "rebirth"], cwd=root).split(b"\0")
    sources = {}
    for raw in filter(None, files):
        path = Path(os.fsdecode(raw))
        sources[str(path)] = sha(root / path)
        if path.is_relative_to("rebirth/src/llama.cpp"):
            continue  # The exact engine is already in the source bundle.
        dest = package / path.relative_to("rebirth")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / path, dest)
    # Configure unfolds the source bundle; never stage an unrelated target/cache.
    (out / "source.json").write_text(json.dumps(dict(
        commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        sources=sources), indent=2) + "\n")
    run("relm-install", [r, "CMD", "INSTALL", "--library=" + str(library), package])
    run("relm-inspection", [rscript, "--vanilla", root / "tests/cran/installed-readiness.R",
        library / "relm", package, out / "installed.rds"])
    run("r-process", [rscript, "--vanilla", "-e",
        "library(relm); stopifnot(!any(grepl('libR[.]so', readLines('/proc/self/maps')))); "
        "cat('NONSHARED_R_PROCESS_OK\\n')"])
    dll = library / "relm/libs/relm.so"
    run("relm-elf", ["readelf", "-d", dll])
    dynamic = (out / "relm-elf.log").read_text()
    assert all(x not in dynamic for x in ("libR.so", "TEXTREL", "libcudart", "libcublas"))
    log = (out / "relm-install.log").read_text()
    assert "RELM_R_HOSTED_WRAPPERS_OK" in log and "cargo run" not in log
    assert sources == {name: sha(root / name) for name in sources}
    (out / "installed-hashes.json").write_text(json.dumps({str(p.relative_to(library)): sha(p)
        for p in sorted(library.rglob("*")) if p.is_file()}, indent=2) + "\n")
    (out / "result.json").write_text(json.dumps(dict(status="awaiting_owner_verification",
        r_home=str(rhome), dll_sha256=sha(dll), model_calls=0,
        scope="Actual non-shared R4.6.1 CPU installation and inspection; not CRAN farm or model acceptance"), indent=2) + "\n")
    print("CRAN_NONSHARED_R_OK model_calls=0")


if __name__ == "__main__":
    main()
