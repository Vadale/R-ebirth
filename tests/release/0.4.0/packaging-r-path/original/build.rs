//! One R-hosted, header-based state accessor. No Rust build dependency.
use std::{env, path::PathBuf, process::Command};
fn r_config(name: &str) -> String {
    let output = Command::new("R")
        .args(["CMD", "config", name])
        .output()
        .expect("R CMD config");
    assert!(output.status.success(), "R CMD config {name} failed");
    String::from_utf8(output.stdout)
        .expect("R compiler flags are UTF-8")
        .trim()
        .to_owned()
}
fn main() {
    println!("cargo:rerun-if-changed=native/projection_state.c");
    for name in ["R_HOME", "R_INCLUDE_DIR", "CC", "R_MAKEVARS_USER"] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    let object = out.join("projection_state.o");
    let archive = out.join("librelm-r-state.a");
    // R's trusted compiler/CPP flag string is shell syntax; source/output paths
    // are separate positional arguments and never interpolated into that code.
    let command = format!(
        r#"{} {} -fPIC -c "$1" -o "$2""#,
        r_config("CC"),
        r_config("--cppflags")
    );
    assert!(
        Command::new("sh")
            .args(["-c", &command, "relm-r-state-compile"])
            .arg("native/projection_state.c")
            .arg(&object)
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
