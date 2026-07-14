//! Twin pin (Hard rule 8f; WP-V1 reviewer finding): the engine archive-stem
//! list is duplicated between `build.rs` (the cargo-side link for tests and the
//! `document` bin) and `rebirth/tools/config.R` (the R SHLIB link). A one-sided
//! edit desynchronizes the two links with an asymmetric failure mode: the cargo
//! side fails loud at archive relocation, but an R-side omission only surfaces
//! when a symbol from the missing archive is first *referenced* — potentially a
//! whole WP later. This test pins the canonical list once and asserts both
//! files spell it out, so any stem change must touch all three places in one
//! commit. Runs per-commit in CI (rust.yaml `cargo` job).

use std::fs;
use std::path::Path;

#[test]
fn build_rs_and_config_r_pin_the_same_archive_stems() {
    let build_rs = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/build.rs"))
        .expect("build.rs must be readable next to the crate manifest");

    // build.rs side: the ordered stem vec + the conditional/final pushes.
    for needle in [
        r#"vec!["mtmd", "llama", "ggml", "ggml-cpu"]"#,
        r#"lib_stems.push("ggml-metal")"#,
        r#"lib_stems.push("ggml-base")"#,
    ] {
        assert!(
            build_rs.contains(needle),
            "build.rs no longer contains `{needle}` — the archive-stem list moved \
             or changed; update build.rs, rebirth/tools/config.R, and this twin pin \
             together (Hard rule 8f)"
        );
    }

    // config.R side. Path: <crate>/../../.. = the rebirth/ package root (holds in
    // both the repo layout and the R source tarball).
    let config_r_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tools/config.R");
    let config_r = fs::read_to_string(&config_r_path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", config_r_path.display()));

    // GNU-ld group form: the Windows and Linux branches each carry the full
    // ordered token list (order matters: left-to-right resolution).
    let group = "-lmtmd -lllama -lggml -lggml-cpu -lggml-base";
    assert_eq!(
        config_r.matches(group).count(),
        2,
        "expected exactly the Windows + Linux branches of config.R to carry \
         `{group}`; the R-side stem list diverged from build.rs (Hard rule 8f)"
    );

    // Darwin branch: the ordered common stems, the arm64-only Metal archive, and
    // the trailing base archive.
    for needle in [
        r#"c("-lmtmd", "-lllama", "-lggml", "-lggml-cpu")"#,
        r#""-lggml-metal""#,
        r#""-lggml-base""#,
    ] {
        assert!(
            config_r.contains(needle),
            "config.R's Darwin branch no longer contains `{needle}`; the R-side \
             stem list diverged from build.rs (Hard rule 8f)"
        );
    }
}
