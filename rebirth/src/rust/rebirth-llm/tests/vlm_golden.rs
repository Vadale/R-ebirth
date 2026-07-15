//! [MODEL] WP-V4: the vision goldens' engine-side gates.
//!
//! 1. The BINDING embd-ATOL leg (D-026 first addendum): the raw image-encoder
//!    output for the committed red-square image matches the UNPATCHED upstream
//!    reference (tests/llm-golden/vision/goldens/encode-red-square-f32.txt,
//!    produced by tools/dump-encode.c against the pristine b9726 build) within
//!    ATOL 1e-3 on CPU.
//! 2. The T1 token-ids pin: greedy generation on the golden image + prompt
//!    reproduces the committed engine token ids byte-for-byte (an
//!    engine-vs-engine regression pin alongside the reference text leg).
//!    Regeneration seam (golden-update discipline): run with
//!    RELM_UPDATE_VISION_IDS=1 to rewrite the ids file, then commit it with
//!    the stated reason.
//!
//! Env-gated on RELM_TEST_MODEL_VLM + RELM_TEST_MMPROJ_VLM; skips otherwise
//! (hard rule 8e: the founder's Mac + the nightly vision workflow, never
//! per-commit CI). CPU backend for comparability with the CPU-only reference.
//!
//! WHICH REFERENCE (D-026 fourth addendum) — the encoder leg is exact on EVERY
//! machine, because the reference it compares against is built on the machine
//! running it. This is not a refinement; it is the whole design, and it is what
//! the measurements forced:
//!   - relm vs upstream on the SAME machine is **bit-exact**: `max |Δ| = 0.0`
//!     on the founder's M4 AND on an x86_64 runner (diag run 29427129990).
//!   - upstream vs ITSELF across machines is not: the same pristine b9726 build
//!     differs from its arm64 self by `max |Δ| = 3.30` on one x86 runner, and
//!     the nightly saw `8.71` on another — the ISA gap is not even a constant
//!     across runners of the same label.
//!
//! So comparing relm-here against a reference recorded elsewhere measures the
//! machine, and no fixed tolerance can separate that from a regression. Compare
//! against a reference from THIS machine and the tolerance question disappears:
//! the gate is exact everywhere, with nothing to tune.
//!
//! `RELM_VISION_ENCODER_REFERENCE` overrides the reference path; the nightly
//! points it at a pristine b9726 build made on the runner. Unset, the leg uses
//! the committed golden — correct on the machine that recorded it (the founder's
//! Mac, where the BINDING leg of the first addendum passes bit-exact) and a
//! loud, honest failure anywhere else.

use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, GenerateParams, LoadRequest};

fn vlm_paths() -> Option<(PathBuf, PathBuf)> {
    let model = std::env::var("RELM_TEST_MODEL_VLM").ok()?;
    let mmproj = std::env::var("RELM_TEST_MMPROJ_VLM").ok()?;
    let (model, mmproj) = (PathBuf::from(model), PathBuf::from(mmproj));
    if model.exists() && mmproj.exists() {
        Some((model, mmproj))
    } else {
        None
    }
}

fn repo_root() -> PathBuf {
    // crate dir = rebirth/src/rust/rebirth-llm.
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../..")
}

fn goldens_dir() -> PathBuf {
    repo_root().join("tests/llm-golden/vision/goldens")
}

fn red_square() -> String {
    repo_root()
        .join("tests/vision/red-square.png")
        .to_str()
        .expect("UTF-8 path")
        .to_string()
}

fn load_vlm_cpu() -> Option<rebirth_llm::LoadedModel> {
    let (model_path, mmproj_path) = vlm_paths()?;
    Some(
        load(LoadRequest {
            path: model_path,
            context_length: 2048,
            gpu_layers: None,
            backend: BackendKind::Cpu,
            mmap: true,
            projector: Some(mmproj_path),
        })
        .expect("VLM + projector load"),
    )
}

#[test]
fn encoder_output_matches_the_unpatched_reference_within_atol() {
    let Some(model) = load_vlm_cpu() else {
        eprintln!("SKIP encoder_output_matches: RELM_TEST_MODEL_VLM/MMPROJ unset");
        return;
    };
    // The nightly points this at a pristine b9726 build made on the runner, so
    // the comparison is same-machine and stays exact there too; unset, the leg
    // uses the committed golden (correct on the machine that recorded it).
    let golden = match std::env::var("RELM_VISION_ENCODER_REFERENCE") {
        Ok(p) => PathBuf::from(p),
        Err(_) => goldens_dir().join("encode-red-square-f32.txt"),
    };
    if !golden.exists() {
        eprintln!(
            "SKIP encoder_output_matches: reference not present at {} (repo layout only)",
            golden.display()
        );
        return;
    }

    let text = std::fs::read_to_string(&golden).expect("read encoder reference");
    let mut lines = text.lines();
    let header = lines.next().expect("golden header");
    let mut dims = header
        .split_whitespace()
        .map(|s| s.parse::<usize>().unwrap());
    let (ref_tokens, ref_embd) = (dims.next().unwrap(), dims.next().unwrap());
    let reference: Vec<f32> = lines
        .map(|l| l.parse::<f32>().expect("float line"))
        .collect();
    assert_eq!(reference.len(), ref_tokens * ref_embd, "golden shape");

    let (values, n_tokens, n_embd) = model
        .image_encoder_output(&red_square(), 64 * 1024 * 1024)
        .expect("engine encoder output");
    assert_eq!(n_tokens, ref_tokens, "token count matches the reference");
    assert_eq!(n_embd, ref_embd, "embedding width matches the reference");

    const ATOL: f32 = 1e-3;
    let (mut max_abs, mut worst) = (0.0f32, 0usize);
    for (i, (&a, &b)) in values.iter().zip(reference.iter()).enumerate() {
        let d = (a - b).abs();
        if d > max_abs {
            max_abs = d;
            worst = i;
        }
    }

    // The BINDING leg (D-026 first addendum). Exact, on every machine — because
    // the reference above comes from this one. Max over ALL values, never the
    // first violation: the original per-element assert reported value 0's small
    // |Δ| and hid a 200x larger one further in, which is how a cross-machine gap
    // got misread as float noise in the first place.
    assert!(
        max_abs <= ATOL,
        "encoder value {worst} diverges: engine {} vs reference {} (|Δ| = {max_abs} > {ATOL}). \
         If this machine did not produce the reference, that is the bug -- floats differ \
         between machines by far more than {ATOL} (measured: up to 8.7 across x86/arm), so \
         point RELM_VISION_ENCODER_REFERENCE at a pristine b9726 build made HERE.",
        values[worst],
        reference[worst]
    );
    eprintln!(
        "embd-ATOL leg: max |Δ| = {max_abs:.3e} over {} values (atol {ATOL:.0e}) vs {}",
        values.len(),
        golden.display()
    );
}

#[test]
fn greedy_generation_reproduces_the_committed_token_ids() {
    let Some(model) = load_vlm_cpu() else {
        eprintln!("SKIP greedy_token_ids: RELM_TEST_MODEL_VLM/MMPROJ unset");
        return;
    };
    let ids_file = goldens_dir().join("greedy-red-square-ids.txt");
    let text_file = goldens_dir().join("greedy-red-square.txt");
    if !text_file.exists() {
        eprintln!("SKIP greedy_token_ids: goldens not present (repo layout only)");
        return;
    }

    let params = GenerateParams {
        max_tokens: 32,
        temperature: 0.0,
        top_p: 0.95,
        seed: 0,
        stop: Vec::new(),
    };
    let generation = model
        .generate_prompt_with_images(
            "What color is the square?",
            true,
            &[red_square()],
            64 * 1024 * 1024,
            &params,
        )
        .expect("greedy multimodal generation");

    // The primary gate stays the upstream-reference TEXT leg.
    let ref_text = std::fs::read_to_string(&text_file).expect("text golden");
    assert_eq!(generation.text, ref_text, "reference text leg");

    // The sanctioned regeneration seam (golden-update skill): explicit intent
    // via the env var, then commit with the stated reason.
    if std::env::var("RELM_UPDATE_VISION_IDS").is_ok() {
        let lines: Vec<String> = generation.tokens.iter().map(|t| t.to_string()).collect();
        std::fs::write(&ids_file, lines.join("\n") + "\n").expect("write ids golden");
        eprintln!(
            "REGENERATED {} ({} ids)",
            ids_file.display(),
            generation.tokens.len()
        );
        return;
    }
    if !ids_file.exists() {
        panic!("token-ids golden missing; run once with RELM_UPDATE_VISION_IDS=1 and commit it");
    }
    let ref_ids: Vec<i32> = std::fs::read_to_string(&ids_file)
        .expect("ids golden")
        .lines()
        .map(|l| l.parse::<i32>().expect("id line"))
        .collect();
    assert_eq!(
        generation.tokens, ref_ids,
        "engine token ids match the committed pin byte-for-byte"
    );
    // Every return above this point is a SKIP, so a nightly that never reaches
    // the assertion is indistinguishable from a passing one by exit code alone.
    // The workflow greps for this line to prove the pin ran (same discipline as
    // the "embd-ATOL leg" print).
    eprintln!("T1 token-ids pin: {} ids match the golden", ref_ids.len());
}
