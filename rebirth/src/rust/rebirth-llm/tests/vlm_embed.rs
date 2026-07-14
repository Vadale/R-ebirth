//! [MODEL] WP-V3 T2 probe + acceptance: multimodal embeddings inside the
//! D-011 embeddings context (docs/wp-v3-embed-spike.md, evidence item 6).
//!
//! Env-gated on RELM_TEST_MODEL_VLM + RELM_TEST_MMPROJ_VLM (the WP-V2 dev
//! artifacts: Qwen2-VL-2B-Instruct Q4_K_M + mmproj-f16); skips silently when
//! unset, so per-commit CI (which has no VLM) is unaffected — hard rule 8e:
//! this runs on the founder's Mac and in the future nightly VLM job. CPU
//! backend throughout for cross-run determinism.

use std::path::PathBuf;

use rebirth_llm::{load, BackendKind, LoadRequest, Pooling};

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

fn fixture(name: &str) -> String {
    // crate dir = rebirth/src/rust/rebirth-llm; fixtures live in the R package.
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/testthat/fixtures/vision")
        .join(name);
    p.to_str().expect("fixture path is UTF-8").to_string()
}

fn cosine(a: &[f32], b: &[f32]) -> f64 {
    let dot: f64 = a.iter().zip(b).map(|(&x, &y)| x as f64 * y as f64).sum();
    let na: f64 = a.iter().map(|&x| (x as f64).powi(2)).sum::<f64>().sqrt();
    let nb: f64 = b.iter().map(|&x| (x as f64).powi(2)).sum::<f64>().sqrt();
    dot / (na * nb)
}

#[test]
fn multimodal_embedding_mechanics_on_the_pinned_vlm() {
    let Some((model_path, mmproj_path)) = vlm_paths() else {
        eprintln!("SKIP multimodal_embedding_mechanics: RELM_TEST_MODEL_VLM/MMPROJ unset");
        return;
    };
    let model = load(LoadRequest {
        path: model_path,
        context_length: 2048,
        gpu_layers: None,
        backend: BackendKind::Cpu,
        mmap: true,
        projector: Some(mmproj_path),
    })
    .expect("VLM + projector load");

    let img = fixture("red-square.png");
    let text = "What color is the square?";
    let max_bytes = 64 * 1024 * 1024;

    // 1. One pooled row per input, width n_embd, every value finite; the
    //    ingest ran INSIDE the embeddings context (would error otherwise).
    let e1 = model
        .embed_texts_with_images(
            &[text],
            &[vec![img.clone()]],
            Pooling::Mean,
            true,
            max_bytes,
        )
        .expect("multimodal embed (mean, normalized)");
    assert_eq!(e1.n_rows, 1);
    assert!(e1.n_embd > 0);
    assert_eq!(e1.values.len(), e1.n_embd);
    assert!(e1.values.iter().all(|v| v.is_finite()), "finite values");
    let norm: f64 = e1
        .values
        .iter()
        .map(|&v| (v as f64).powi(2))
        .sum::<f64>()
        .sqrt();
    assert!((norm - 1.0).abs() < 1e-4, "normalized row, norm = {norm}");

    // 2. Determinism: a second run is bit-identical (CPU backend).
    let e2 = model
        .embed_texts_with_images(
            &[text],
            &[vec![img.clone()]],
            Pooling::Mean,
            true,
            max_bytes,
        )
        .expect("second multimodal embed");
    assert_eq!(e1.values, e2.values, "bit-identical across runs");

    // 3. The image genuinely conditions the text rows: the multimodal row
    //    differs from the text-only embedding of the same text.
    let t = model
        .embed_texts(&[text], Pooling::Mean, true)
        .expect("text-only embed");
    let cos = cosine(&e1.values, &t.values);
    assert!(
        cos < 0.999,
        "image must move the embedding; cosine(text, text+image) = {cos}"
    );

    // 4. x = "" with an image works (the projector's image-delimiter text
    //    tokens provide the pooled rows — spike doc item 4).
    let empty = model
        .embed_texts_with_images(&[""], &[vec![img.clone()]], Pooling::Mean, true, max_bytes)
        .expect("image-only embed (empty text)");
    assert_eq!(empty.n_rows, 1);
    assert!(empty.values.iter().all(|v| v.is_finite()));
    let norm: f64 = empty
        .values
        .iter()
        .map(|&v| (v as f64).powi(2))
        .sum::<f64>()
        .sqrt();
    assert!(norm > 0.5, "image-only row is a real vector, norm = {norm}");

    // 5. An input with an EMPTY image set takes the text path byte-identically.
    let mixed = model
        .embed_texts_with_images(&[text], &[vec![]], Pooling::Mean, true, max_bytes)
        .expect("empty-set input through the multimodal entry");
    assert_eq!(
        mixed.values, t.values,
        "empty image set == the plain text path, byte-identical"
    );

    // 6. Last pooling works too (the final text row: the closing turn of the
    //    delimiter/suffix tokens, image-conditioned via attention).
    let last = model
        .embed_texts_with_images(&[text], &[vec![img]], Pooling::Last, true, max_bytes)
        .expect("multimodal embed (last)");
    assert_eq!(last.n_rows, 1);
    assert!(last.values.iter().all(|v| v.is_finite()));
}
