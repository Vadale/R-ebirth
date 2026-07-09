//! Native build of the vendored llama.cpp (DECISIONS.md D-006).
//!
//! Configures and builds `rebirth/src/llama.cpp` as a set of static archives via
//! the `cmake` build-dependency, then:
//!   1. emits `cargo:rustc-link-*` so cargo-driven links (the `rebirth-llm` tests
//!      and the `rebirth-ffi` `document` bin) resolve the engine symbols, and
//!   2. relocates the produced `.a` archives next to `librelm.a` in the shared
//!      `rust/target/<profile>/` dir so the R shared-object link (Makevars
//!      `PKG_LIBS`) can find them.
//!
//! Backends (D-006): Metal + embedded shaders on macOS arm64, CPU only elsewhere,
//! CUDA behind the default-off `cuda` feature (defined, not built, until Phase 8).
//! The vendored tree is committed WITH the rebirth patch set already applied
//! (D-015): this script compiles it as-is — no build-time patching. The patch
//! provenance diffs live in `src/llama.cpp/patches/`, and the tree's post-patch
//! SHA256 (asserted by CI gate G4) is recorded in `src/llama.cpp/VENDORING.md`.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    // rebirth-llm is at rebirth/src/rust/rebirth-llm; the vendored engine is at
    // rebirth/src/llama.cpp — two levels up from this crate.
    let llama_src = manifest_dir.join("..").join("..").join("llama.cpp");
    let llama_src = llama_src.canonicalize().unwrap_or_else(|e| {
        panic!(
            "vendored llama.cpp not found at {}: {e}",
            llama_src.display()
        )
    });

    // Rerun only when the pin or this script changes (the vendored tree is pinned).
    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rerun-if-changed={}",
        llama_src.join("CMakeLists.txt").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        llama_src.join("VENDORING.md").display()
    );

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let metal = target_os == "macos" && target_arch == "aarch64";
    let cuda = env::var_os("CARGO_FEATURE_CUDA").is_some();

    // Cap cmake parallelism (the crate derives --parallel from NUM_JOBS): keeps
    // memory in check on the 16 GB primary machine and stays CRAN-friendly
    // (CRAN passes -j2 to cargo, so NUM_JOBS is already 2 there). D-006 "Timing".
    if let Ok(n) = env::var("NUM_JOBS") {
        if let Ok(j) = n.parse::<usize>() {
            env::set_var("NUM_JOBS", j.min(4).to_string());
        }
    }

    let mut cfg = cmake::Config::new(&llama_src);
    cfg.define("CMAKE_BUILD_TYPE", "Release")
        .define("BUILD_SHARED_LIBS", "OFF")
        // Only libllama + ggml are needed; skip every extra artifact.
        .define("LLAMA_BUILD_TESTS", "OFF")
        .define("LLAMA_BUILD_EXAMPLES", "OFF")
        .define("LLAMA_BUILD_TOOLS", "OFF")
        .define("LLAMA_BUILD_SERVER", "OFF")
        .define("LLAMA_BUILD_COMMON", "OFF")
        .define("LLAMA_BUILD_APP", "OFF")
        // Keep the produced archive set canonical and deterministic: the ggml
        // Accelerate path (GGML_ACCELERATE) stays on for the CPU backend, but the
        // separate BLAS backend is not built (avoids an extra libggml-blas.a).
        .define("GGML_BLAS", "OFF")
        // Avoid an OpenMP (libgomp) transitive dependency in the static link;
        // ggml falls back to its own pthread threadpool.
        .define("GGML_OPENMP", "OFF");

    if metal {
        cfg.define("GGML_METAL", "ON")
            .define("GGML_METAL_EMBED_LIBRARY", "ON");
    } else {
        cfg.define("GGML_METAL", "OFF");
    }

    // CUDA is defined here but only built when the `cuda` feature is enabled
    // (Phase 8). WP1 never exercises this path.
    cfg.define("GGML_CUDA", if cuda { "ON" } else { "OFF" });

    // Match the macOS deployment target the final link uses, so the vendored
    // objects are not compiled for a newer macOS than they are linked against —
    // R CMD check (error-on = warning) rejects "object file was built for newer
    // 'macOS' version than being linked". R exports MACOSX_DEPLOYMENT_TARGET
    // during the package build; fall back to the architecture's floor otherwise.
    if target_os == "macos" {
        let deployment_target = env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| {
            if target_arch == "aarch64" {
                "11.0".to_string()
            } else {
                "10.15".to_string()
            }
        });
        cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", &deployment_target);

        // Pin the vendored llama.cpp CMake build to the target arch when cross
        // compiling. r-universe builds the macOS x86_64 (Intel) binary on an arm64
        // runner; without this CMake defaults to the host arch (arm64), so the
        // objects are arm64 and the x86_64 link fails with "Undefined symbols for
        // architecture x86_64". Set it only for x86_64 so the native arm64 build
        // (the primary target) stays byte-for-byte unchanged.
        if target_arch == "x86_64" {
            cfg.define("CMAKE_OSX_ARCHITECTURES", "x86_64");
        }
    }

    let dst = cfg.build();

    // The cmake crate builds under `<dst>/build`; llama.cpp's install target does
    // not copy static archives, so locate them directly in the build tree.
    let build_dir = dst.join("build");

    // Dependency order (GNU ld resolves left-to-right): the Rust code references
    // llama; llama references ggml (registry) + the backends; everything
    // references ggml-base, which is the leaf and comes last.
    let mut lib_stems: Vec<&str> = vec!["llama", "ggml", "ggml-cpu"];
    if metal {
        lib_stems.push("ggml-metal");
    }
    lib_stems.push("ggml-base");

    // Relocate the archives to a stable per-build dir (for cargo's own link) and
    // to the shared profile dir alongside librelm.a (for the R SHLIB link).
    let native_dir = dst.join("relm-native");
    fs::create_dir_all(&native_dir).expect("create native lib dir");
    let profile_dir = profile_target_dir();

    for stem in &lib_stems {
        let file_name = format!("lib{stem}.a");
        let found = find_file(&build_dir, &file_name).unwrap_or_else(|| {
            panic!(
                "expected static archive {file_name} not produced by the llama.cpp build under {}",
                build_dir.display()
            )
        });
        fs::copy(&found, native_dir.join(&file_name))
            .unwrap_or_else(|e| panic!("copy {file_name} into native dir: {e}"));
        if let Some(ref pdir) = profile_dir {
            let _ = fs::copy(&found, pdir.join(&file_name));
        }
    }

    println!("cargo:rustc-link-search=native={}", native_dir.display());

    emit_link_flags(&lib_stems, &target_os, metal);
}

/// Emit the `cargo:rustc-link-lib` flags for the cargo-driven link (tests + the
/// `document` bin). The R SHLIB link mirrors these in `src/Makevars(.in)`.
fn emit_link_flags(lib_stems: &[&str], target_os: &str, metal: bool) {
    if target_os == "linux" {
        // The engine symbols must reach the `rebirth-ffi` `document` bin, a
        // dependent crate. `cargo:rustc-link-arg` (which a --start-group needs)
        // does NOT propagate across crates — only `rustc-link-lib`/`-search` do.
        // On GNU ld a static archive yields only the members referenced before it
        // is scanned, so plain, unordered `-l` flags leave the ggml/llama
        // back-references undefined. `+whole-archive` forces every object in (no
        // group, order-independent) and propagates via `rustc-link-lib`; `-bundle`
        // keeps the archives OUT of `librelm.a` so the R SHLIB link (Makevars
        // PKG_LIBS, with its own --start-group) remains the single provider and no
        // symbol is defined twice.
        for stem in lib_stems {
            println!("cargo:rustc-link-lib=static:+whole-archive,-bundle={stem}");
        }
        println!("cargo:rustc-link-lib=dylib=stdc++");
        println!("cargo:rustc-link-lib=dylib=m");
        println!("cargo:rustc-link-lib=dylib=dl");
    } else {
        // macOS ld64 resolves archive back-references without groups.
        for stem in lib_stems {
            println!("cargo:rustc-link-lib=static={stem}");
        }
        println!("cargo:rustc-link-lib=dylib=c++");

        // ggml's CPU backend links Accelerate (vDSP / BLAS) on every macOS arch, so
        // it is needed for both arm64 and x86_64 — the cross-compiled x86_64
        // `document` bin otherwise fails to link with undefined `_vDSP_*` symbols.
        // Metal and its Obj-C dependencies are only pulled in by the Metal backend
        // (macOS arm64).
        println!("cargo:rustc-link-lib=framework=Accelerate");
        if metal {
            for framework in ["Metal", "MetalKit", "Foundation"] {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        }
    }
}

/// The shared `rust/target/<profile>/` directory (alongside `librelm.a`),
/// derived from `OUT_DIR = <target>/<profile>/build/<crate>-<hash>/out`.
fn profile_target_dir() -> Option<PathBuf> {
    let out_dir = PathBuf::from(env::var("OUT_DIR").ok()?);
    // out -> <crate>-<hash> -> build -> <profile>
    let dir = out_dir.ancestors().nth(3)?.to_path_buf();
    if dir.is_dir() {
        Some(dir)
    } else {
        None
    }
}

/// Recursively search `dir` for a file named `name`, returning the first match.
fn find_file(dir: &Path, name: &str) -> Option<PathBuf> {
    let entries = fs::read_dir(dir).ok()?;
    let mut subdirs = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            subdirs.push(path);
        } else if path.file_name().map(|f| f == name).unwrap_or(false) {
            return Some(path);
        }
    }
    for sub in subdirs {
        if let Some(found) = find_file(&sub, name) {
            return Some(found);
        }
    }
    None
}
