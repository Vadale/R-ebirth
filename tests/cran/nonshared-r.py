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


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download_input(name, base, digest, out, attempts):
    """Fetch identical pinned bytes from at most two CRAN HTTPS endpoints.

    Each request has a 10s connection / 45s total limit and no curl retries.
    Only nanoarrow's existing 404 archive fallback adds a request on a host.
    Hash or certificate failures stop immediately; mirrors never bypass them.
    """
    destination = out / name
    partial = out / (name + ".part")
    if destination.exists() or partial.exists():
        raise FileExistsError("Refusing to overwrite an existing input: " + name)
    relative = base.removeprefix("https://cran.r-project.org")
    if relative == base or relative not in ("/src/base/R-4/", "/src/contrib/"):
        raise ValueError("Expected the pinned CRAN source path")
    for host in ("https://cloud.r-project.org", "https://cran.r-project.org"):
        urls = [host + relative + name]
        if name.startswith("nanoarrow_"):
            urls.append(host + relative + "Archive/nanoarrow/" + name)
        for url in urls:
            print("Fetching pinned input " + name + " from " + url, flush=True)
            command = ["curl", "--disable", "--fail", "--show-error", "--silent",
                       "--location", "--max-redirs", "3", "--proto", "=https",
                       "--proto-redir", "=https", "--connect-timeout", "10",
                       "--max-time", "45", "--retry", "0", "--output", str(partial),
                       "--write-out", "%{http_code}", url]
            started = time.monotonic()
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=50)
                code, http, error = result.returncode, result.stdout.strip(), result.stderr
            except subprocess.TimeoutExpired:
                code, http, error = 28, "000", "curl exceeded its 50-second process deadline"
            record = dict(input=name, url=url, returncode=code, http_status=http,
                          seconds=time.monotonic() - started, diagnostic=error)
            attempts.append(record)
            try:
                if code == 0:
                    record["sha256"] = sha(partial)
                    if record["sha256"] != digest:
                        record["outcome"] = "hash_mismatch"
                        raise ValueError("Pinned SHA-256 mismatch: " + name)
                    partial.replace(destination)
                    record["outcome"] = "verified"
                    return
                record["outcome"] = "request_failed"
                if code == 22 and http == "404":
                    continue  # Archive on this host, or the next fixed mirror.
                transient = code in (5, 6, 7, 18, 28, 52, 55, 56)
                transient |= code == 22 and (http in ("408", "429") or http.startswith("5"))
                if transient:
                    break  # One request per host for transport/service failures.
                raise RuntimeError("Non-recoverable input download failure: " + url + "\n" + error)
            finally:
                partial.unlink(missing_ok=True)
                (out / "download-attempts.json").write_text(json.dumps(attempts, indent=2) + "\n")
    raise RuntimeError("Both CRAN endpoints failed for pinned input: " + name)


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
    download_attempts = []
    for name, base, digest in inputs:
        download_input(name, base, digest, out, download_attempts)
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
