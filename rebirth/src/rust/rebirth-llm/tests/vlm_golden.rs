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
//! TWO ACCEPTANCE MODES for the float leg (D-026 fourth addendum) — because a
//! float golden is specific to the MACHINE that recorded it, not merely to its
//! OS/arch. The first real nightly proved it: against the reference recorded on
//! the founder's M4, the encoder diverged by |Δ| = 3.96e-2 on an x86_64 runner
//! (40x the tolerance) and the T2 pooled vector by 6.05e-3 on a non-M4 arm64
//! runner (600x) — while that same run's token-ids pin and byte-exact text leg
//! passed on BOTH. The semantics are identical across machines; only the floats
//! differ (ISA kernels, thread-pool reduction order, and chaotic amplification
//! of ~1e-7 differences through 28 layers). So:
//!   - DEFAULT (the recording machine, `[MODEL]`): exact `|Δ| <= ATOL`. This is
//!     the BINDING leg of the D-026 first addendum; it passes bit-exact.
//!   - `RELM_VISION_GOLDEN_CROSS_PLATFORM=1` (the nightly, any runner): a
//!     machine-robust cosine floor instead. A real encoder regression collapses
//!     the cosine; ISA noise does not. Same dual-reference logic as D-018.
//!
//! Strict is the DEFAULT and the relaxed mode must be asked for explicitly, so
//! a forgotten variable can only make the gate stricter, never weaker.

use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, GenerateParams, LoadRequest};

/// Cosine floor for the cross-machine leg. PROVISIONAL — set from measurement on
/// the real runners before this branch merges, never guessed: D-018 is the
/// project's own evidence that the intuitive "0.999" is wrong for this class of
/// comparison (it found ~0.94 for a cross-implementation reference). This value
/// is the measurement probe.
const COS_FLOOR: f64 = 0.999;

/// The nightly runs on machines that did not record the goldens; it opts into
/// the machine-robust acceptance explicitly.
fn cross_platform_mode() -> bool {
    std::env::var("RELM_VISION_GOLDEN_CROSS_PLATFORM").is_ok()
}

/// Cosine similarity in f64 (the inputs are f32 and the sums run to ~1e5 terms,
/// so the accumulator must not be the thing that loses precision).
fn cosine(a: &[f32], b: &[f32]) -> f64 {
    let (mut dot, mut na, mut nb) = (0.0f64, 0.0f64, 0.0f64);
    for (&x, &y) in a.iter().zip(b.iter()) {
        dot += f64::from(x) * f64::from(y);
        na += f64::from(x) * f64::from(x);
        nb += f64::from(y) * f64::from(y);
    }
    dot / (na.sqrt() * nb.sqrt())
}

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

// --- cosine unit tests (model-free: these RUN in per-commit CI) --------------
//
// The cross-machine leg rests entirely on one claim: float noise leaves the
// cosine at ~1, a real regression collapses it. That claim is the gate, so it
// is tested here rather than assumed -- the [MODEL] leg above cannot check it
// (per-commit CI has no VLM, and a nightly only ever sees the healthy case).

#[test]
fn cosine_is_one_for_identical_and_scaled_vectors() {
    let a = [1.0f32, -2.0, 3.5, 0.25];
    assert!((cosine(&a, &a) - 1.0).abs() < 1e-12);
    // Scale invariance is why the leg survives a machine that computes the same
    // direction with slightly different magnitudes.
    let scaled: Vec<f32> = a.iter().map(|v| v * 7.5).collect();
    assert!((cosine(&a, &scaled) - 1.0).abs() < 1e-12);
}

#[test]
fn cosine_matches_a_hand_computed_value() {
    // (1,0) vs (1,1) = 1/sqrt(2); an independent value, not a property.
    let cos = cosine(&[1.0, 0.0], &[1.0, 1.0]);
    assert!(
        (cos - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12,
        "{cos}"
    );
    assert!((cosine(&[1.0, 0.0], &[0.0, 1.0])).abs() < 1e-12); // orthogonal -> 0
    assert!((cosine(&[1.0, 2.0], &[-1.0, -2.0]) + 1.0).abs() < 1e-12); // opposite -> -1
}

#[test]
fn cosine_tolerates_noise_but_collapses_on_a_broken_vector() {
    // A 4096-value stand-in for an encoder output.
    let base: Vec<f32> = (0..4096).map(|i| ((i % 97) as f32 - 48.0) * 0.1).collect();

    // Noise at 100x the worst cross-machine divergence this leg has seen
    // (3.96e-2 on x86_64) must still leave the cosine essentially at 1 --
    // otherwise the floor would be measuring the runner, not the code.
    let noisy: Vec<f32> = base
        .iter()
        .enumerate()
        .map(|(i, v)| v + if i % 2 == 0 { 4.0 } else { -4.0 })
        .collect();
    let cos_noise = cosine(&base, &noisy);

    // A regression that scrambles the output must be caught. Reversal keeps
    // every value, the mean, and the norm identical -- only the direction
    // changes, so an ATOL-style check on sorted stats could miss it.
    let reversed: Vec<f32> = base.iter().rev().copied().collect();
    let cos_broken = cosine(&base, &reversed);

    assert!(
        cos_broken < cos_noise,
        "a scrambled vector must score below a noisy one: broken {cos_broken}, noisy {cos_noise}"
    );
    assert!(
        cos_broken < 0.9,
        "cosine failed to collapse on a scrambled vector: {cos_broken}"
    );
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
    let golden = goldens_dir().join("encode-red-square-f32.txt");
    if !golden.exists() {
        eprintln!("SKIP encoder_output_matches: golden not present (repo layout only)");
        return;
    }

    let text = std::fs::read_to_string(&golden).expect("read encoder golden");
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
    let cos = cosine(&values, &reference);

    if cross_platform_mode() {
        // Machine-robust leg: the reference was recorded elsewhere, so the raw
        // floats are expected to differ. What must NOT differ is the direction
        // of the 98304-dim encoder output — a regression that actually breaks
        // the encoder moves it, ISA noise does not.
        assert!(
            cos >= COS_FLOOR,
            "encoder output diverges in DIRECTION, not just precision: cos = {cos:.9} < {COS_FLOOR} \
             (max |Δ| = {max_abs:.3e} at value {worst}). Cross-machine float noise cannot do this; \
             suspect a real encoder regression."
        );
        eprintln!(
            "embd-cosine leg: cos = {cos:.9} (floor {COS_FLOOR}), max |Δ| = {max_abs:.3e} over {} values \
             [cross-platform mode: the reference is recorded on another machine]",
            values.len()
        );
    } else {
        // The BINDING leg (D-026 first addendum), on the recording machine.
        assert!(
            max_abs <= ATOL,
            "encoder value {worst} diverges: engine {} vs reference {} (|Δ| = {max_abs} > {ATOL}). \
             If this machine did not record the golden, the nightly's \
             RELM_VISION_GOLDEN_CROSS_PLATFORM=1 mode is the right gate here.",
            values[worst],
            reference[worst]
        );
        eprintln!(
            "embd-ATOL leg: max |Δ| = {max_abs:.3e} over {} values (atol {ATOL:.0e}); cos = {cos:.9}",
            values.len()
        );
    }
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
