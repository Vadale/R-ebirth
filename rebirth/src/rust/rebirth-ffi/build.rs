//! One R-hosted, header-based state accessor. No Rust build dependency.
use std::{env, path::PathBuf, process::Command};
fn r_command() -> Command {
    // R CMD check deliberately shadows bare R on PATH. Use the same R host
    // that started installation; standalone cargo builds may discover R on PATH.
    let r = env::var_os("R_HOME")
        .map(|home| {
            PathBuf::from(home)
                .join("bin")
                .join(format!("R{}", env::consts::EXE_SUFFIX))
        })
        .unwrap_or_else(|| PathBuf::from("R"));
    Command::new(r)
}
fn r_output(args: &[&str]) -> String {
    let output = r_command().args(args).output().expect("R configuration");
    assert!(
        output.status.success(),
        "R {args:?} failed: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("R configuration is UTF-8")
        .trim()
        .to_owned()
}

fn main() {
    println!("cargo:rerun-if-changed=native/projection_state.c");
    for name in [
        "R_HOME",
        "R_INCLUDE_DIR",
        "R_ARCH",
        "CC",
        "CFLAGS",
        "RELM_R_PORTABLE",
        "R_MAKEVARS_USER",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    let object = out.join("projection_state.o");
    let archive = out.join("librelm-r-state.a");
    // R CMD config --cppflags describes embedding R and returns no flags when
    // R was not built as a library. Package headers are still available.
    let include = env::var_os("R_INCLUDE_DIR")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(r_output(&[
                "--vanilla",
                "--slave",
                "-e",
                "cat(R.home('include'))",
            ]))
        });
    assert!(
        include.join("Rinternals.h").is_file(),
        "R headers missing: {include:?}"
    );
    // R's trusted compiler/flag strings are shell syntax. File/include paths
    // remain separate positional arguments, including spaces and shell syntax.
    let portable = env::var("RELM_R_PORTABLE").as_deref() == Ok("1");
    let cc = if portable {
        env::var("CC").expect("R CC")
    } else {
        r_output(&["CMD", "config", "CC"])
    };
    let flags = if portable {
        env::var("CFLAGS").expect("R CFLAGS")
    } else {
        "-fPIC".to_string()
    };
    let mut command = format!(r#"{cc} {flags} -I"$3" -c "$1" -o "$2""#);
    let arch = env::var("R_ARCH").unwrap_or_default();
    let arch_include = include.join(arch.trim_start_matches(['/', '\\']));
    if !arch.is_empty() {
        command.push_str(r#" -I"$4""#);
    }
    assert!(
        Command::new("sh")
            .args(["-c", &command, "relm-r-state-compile"])
            .arg("native/projection_state.c")
            .arg(&object)
            .arg(&include)
            .arg(&arch_include)
            .status()
            .expect("R C compiler")
            .success(),
        "R state accessor compile failed"
    );
    assert!(
        Command::new("ar")
            .arg("crs")
            .arg(&archive)
            .arg(&object)
            .status()
            .expect("archive R state accessor")
            .success(),
        "R state accessor archive failed"
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    // Bundled into librelm.a, so the package/scratch DLL uses unchanged PKG_LIBS.
    println!("cargo:rustc-link-lib=static=relm-r-state");
}
