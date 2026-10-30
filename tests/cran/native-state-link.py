#!/usr/bin/env python3
"""Exercise the actual FFI build script/R link template with GCC slim LTO.

No engine, model, R package dependency or network is used. The native source and
build script are copied unchanged into a dependency-free Cargo fixture. The
compiled C helper is linked by R's configured route through a tiny driver.
The fixture does not validate the full package or the CRAN Fedora environment.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.update(TMPDIR=str(out), CARGO_HOME=str(out / "cargo-home"),
               CARGO_TARGET_DIR=str(out / "target"), CARGO_NET_OFFLINE="true",
               CARGO_INCREMENTAL="0", RELM_R_PORTABLE="1", CC="gcc",
               CFLAGS="-O2 -fPIC -flto=10 -fno-fat-lto-objects "
                      "-fsanitize=address,undefined,bounds-strict -fno-omit-frame-pointer")
    commands = []

    def run(label, command, cwd=out, expected=0):
        p = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, timeout=120)
        (out / (label + ".stdout")).write_text(p.stdout)
        (out / (label + ".stderr")).write_text(p.stderr)
        commands.append(dict(label=label, command=command, returncode=p.returncode))
        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if p.returncode != expected:
            raise RuntimeError(f"{label}: exit {p.returncode}; see retained stderr")
        return p.stdout

    fixture = out / "fixture"
    (fixture / "native").mkdir(parents=True)
    for relative in ["build.rs", "native/projection_state.c"]:
        shutil.copyfile(ROOT / "rebirth/src/rust/rebirth-ffi" / relative, fixture / relative)
    (fixture / "Cargo.toml").write_text('''[package]
name = "state-link-regression"
version = "0.0.0"
edition = "2021"
[lib]
name = "relm"
path = "lib.rs"
crate-type = ["staticlib"]
[profile.release]
panic = "abort"
''')
    (fixture / "lib.rs").write_text('''#![no_std]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }
extern "C" { fn relm_r_state_frame_size() -> usize; }
#[no_mangle]
pub extern "C" fn relm_state_link_probe() -> usize {
    unsafe { relm_r_state_frame_size() }
}
''')
    # Execute only the existing configure fixture function, with real source
    # templates. Its mocks are tool discovery/platform selection, not linking.
    configure = out / "configure.R"
    configure.write_text('''repo <- normalizePath(commandArgs(TRUE)[1L])
root <- normalizePath(commandArgs(TRUE)[2L])
expressions <- as.list(parse(file.path(repo, "tests/cran/configuration.R")))
f <- Filter(function(x) is.call(x) && identical(x[[1L]], as.name("<-")) &&
            identical(x[[2L]], as.name("configure_case")), expressions)
stopifnot(length(f) == 1L); eval(f[[1L]])
for (windows in c(FALSE, TRUE)) {
    cfg <- configure_case(TRUE, "false", windows)
    stopifnot(is.environment(cfg), cfg$.r_state_lib == "-lrelm-r-state -lrelm",
              any(grepl("-lrelm -lrelm-r-state ", cfg$new_txt, fixed=TRUE)))
    if (!windows) writeLines(grep("^PKG_LIBS =", cfg$new_txt, value=TRUE),
                            file.path(root, "pkg-libs.txt"))
}
cfg <- configure_case(TRUE, "false", wasm=TRUE)
stopifnot(is.environment(cfg), cfg$.r_state_lib == "",
          !any(grepl("-lrelm-r-state", cfg$new_txt, fixed=TRUE)))
''')
    run("configure", ["Rscript", "--vanilla", str(configure), str(ROOT), str(out)])
    run("build", ["cargo", "build", "--release", "--offline", "--manifest-path", str(fixture / "Cargo.toml")])
    profile = out / "target/release"
    archive = profile / "librelm-r-state.a"
    if not archive.is_file():
        raise RuntimeError("native state archive was not copied beside librelm.a")
    # Put the unexercised finalizer callback in its own archive member, so its
    # C -> Rust back-reference cannot succeed accidentally through a shared CGU.
    (out / "drop-stub.c").write_text("void relm_projection_drop_any(void *p) { (void)p; }\n")
    run("drop-stub", ["gcc", "-fPIC", "-c", "drop-stub.c", "-o", "drop-stub.o"])
    run("append-drop-stub", ["ar", "rs", str(profile / "librelm.a"), "drop-stub.o"])
    # Preserve the generated ordering up to the independent engine archive list.
    flags = (out / "pkg-libs.txt").read_text().split("=", 1)[1].strip()
    flags = flags.split("-Wl,--start-group", 1)[0].replace("$(LIBDIR)", str(profile))
    rflags = shlex.split(run("r-ldflags", ["R", "CMD", "config", "--ldflags"]))
    (out / "entry.c").write_text('''#include <stddef.h>
extern size_t relm_state_link_probe(void);
size_t entry(void) { return relm_state_link_probe(); }
''')
    cflags = shlex.split(env["CFLAGS"])
    command = ["gcc", *cflags, "-shared", "-Wl,-z,defs", "entry.c",
               *shlex.split(flags), *rflags, "-o", "state.so"]
    run("link", command)
    symbols = run("symbols", ["nm", "-D", "--defined-only", "state.so"])
    if " relm_r_projection_shell_install\n" not in symbols:
        raise RuntimeError("CRAN's missing symbol is not defined in the linked DLL")
    # Omitting the separate archive must fail: a bundled/fat-LTO copy must not
    # silently make this guard pass without exercising the intended fix.
    negative = ["omitted-archive.so" if x == "state.so" else x for x in command if x != "-lrelm-r-state"]
    p = subprocess.run(negative, cwd=out, env=env, text=True, capture_output=True, timeout=120)
    (out / "omitted-archive.stderr").write_text(p.stderr)
    if p.returncode == 0 or "relm_r_state_frame_size" not in p.stderr:
        raise RuntimeError("omitted archive did not fail at the state helper")
    (out / "receipt.json").write_text(json.dumps({
        "status": "PASS", "scope": "actual build.rs, C helper, configure and R link template; no full package",
        "cflags": env["CFLAGS"], "negative_omitted_archive": p.returncode,
        "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in [ROOT / "rebirth/src/rust/rebirth-ffi/build.rs",
                      ROOT / "rebirth/src/rust/rebirth-ffi/native/projection_state.c",
                      ROOT / "rebirth/tools/config.R", ROOT / "rebirth/src/Makevars.in",
                      ROOT / "rebirth/src/Makevars.win.in"]}}, indent=2) + "\n")
    print("NATIVE_STATE_LTO_PASS actual_build_script=true sanitizer_flags_retained=true omitted_archive_refused=true models=0")


if __name__ == "__main__":
    main()
