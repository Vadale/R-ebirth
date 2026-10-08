//! Default-build boundary gate: the linked library is compiled without cfg(test).
//! These checks exercise activation/ownership, not a new numerical oracle.
#![cfg(not(feature = "projection-private"))]
use rebirth_llm::*;
use std::path::PathBuf;

fn request(params: GenerateParams) -> AsyncRequest {
    AsyncRequest {
        prompts: vec!["unused no_vocab text".into()],
        chat: false,
        params,
        schema: None,
        images: None,
        image_max_bytes: 1,
        stream: false,
        live: None,
    }
}
fn same(actual: Vec<f32>, expected: &[f32], compared: &mut usize) {
    assert_eq!(actual, expected);
    *compared += actual.len();
}

#[test]
fn default_constructor_routes_and_owned_lifecycle() {
    let source = load_with_batch(
        LoadRequest {
            path: PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../../tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"),
            context_length: 128,
            gpu_layers: Some(0),
            backend: BackendKind::Cpu,
            mmap: true,
            projector: None,
        },
        Some(4),
    )
    .unwrap();
    let original = source.prompt_last_logits(&[1, 7, 13], 48).unwrap();
    let mut axis = [0.; 32];
    axis[1] = 1.;
    let mut command = ProjectionCommand {
        mode: ProjectionAdmissionMode::NewSite,
        layer: 1,
        component: Component::MlpOut,
        coef: 1.,
        direction: &axis,
        steer_entries: 0,
        ablate_entries: 0,
        existing_direction_estimate: 0,
        r_projection_fixed_bytes: 4096,
        r_adapter_bytes: 0,
        max_bytes: 64 * 1024 * 1024,
    };
    let ffi = ProjectionFfiProfile::default();
    assert_eq!(
        source
            .projection_preflight(&command, ffi)
            .unwrap()
            .1
            .fields()[14],
        ("production_armed", 1)
    );
    let mut cases = 1;
    let mut compared = 0;
    let (mut projected, _) = source
        .projection_construct(&command, ProjectionResidualArrays::empty(), ffi)
        .unwrap();
    let changed = projected.prompt_last_logits(&[1, 7, 13], 48).unwrap();
    assert!(changed
        .iter()
        .zip(&original)
        .any(|(a, b)| a.to_bits() != b.to_bits()));
    same(
        projected.prompt_last_logits(&[1, 7, 13], 48).unwrap(),
        &changed,
        &mut compared,
    );
    let params = GenerateParams {
        max_tokens: 3,
        temperature: 0.,
        top_p: 1.,
        seed: 42,
        stop: vec![],
    };
    let generated = projected.generate(&[1, 7], &params).unwrap();
    assert_eq!(generated.tokens.len(), 3);
    assert_eq!(projected.generate(&[1, 7], &params).unwrap(), generated);
    cases += 1;

    let mut refusals = 0;
    let spec = InterventionSpec::new(32, 3);
    assert!(matches!(
        projected.derive_with_interventions(&spec),
        Err(RebirthError::Intervention { .. })
    ));
    cases += 1;
    refusals += 1;
    let images = vec!["/missing-must-not-be-opened.png".into()];
    let image_error = projected
        .generate_prompt_with_images("a", false, &images, 1, &params)
        .unwrap_err();
    assert_eq!(image_error.class(), "relm_error_intervention");
    assert!(image_error.to_string().contains("images"));
    cases += 1;
    refusals += 1;
    assert!(matches!(
        projected.image_encoder_output(&images[0], 1),
        Err(RebirthError::Intervention { .. })
    ));
    cases += 1;
    refusals += 1;
    assert!(matches!(
        projected.embed_texts(&["a"], Pooling::Mean, false),
        Err(RebirthError::Intervention { .. })
    ));
    cases += 1;
    refusals += 1;
    assert!(matches!(
        projected.token_embeddings(&[1, 7]),
        Err(RebirthError::Intervention { .. })
    ));
    cases += 1;
    refusals += 1;
    assert!(matches!(
        projected.embed_texts_with_images(
            &["a"],
            std::slice::from_ref(&images),
            Pooling::Mean,
            false,
            1
        ),
        Err(RebirthError::Intervention { .. })
    ));
    cases += 1;
    refusals += 1;
    let capture = CaptureSpec {
        layers: Some(vec![1]),
        components: vec![Component::Residual],
        positions: Positions::Last,
    };
    assert!(matches!(
        projected.activations(&[1, 7], &capture),
        Err(RebirthError::Intervention { .. })
    ));
    cases += 1;
    refusals += 1;

    for image in [true, false] {
        let mut req = request(params.clone());
        if image {
            req.images = Some(vec![images.clone()]);
        } else {
            req.prompts.clear();
        }
        let permit = ExecutionPermit::try_acquire("projection production startup refusal").unwrap();
        let mut failure = match AsyncJob::start(projected, req, permit) {
            Ok(_) => panic!("request must fail before worker startup"),
            Err(error) => error,
        };
        assert_eq!(
            failure.error.class(),
            if image {
                "relm_error_intervention"
            } else {
                "relm_error_argument"
            }
        );
        projected = failure.model.take().unwrap();
        drop(failure);
        same(
            projected.prompt_last_logits(&[1, 7, 13], 48).unwrap(),
            &changed,
            &mut compared,
        );
        cases += 1;
        refusals += 1;
    }
    command.mode = ProjectionAdmissionMode::Inherit;
    command.direction = &[];
    command.coef = 0.;
    let (child, _) = projected
        .projection_construct(&command, ProjectionResidualArrays::empty(), ffi)
        .unwrap();
    same(
        child.prompt_last_logits(&[1, 7, 13], 48).unwrap(),
        &changed,
        &mut compared,
    );
    cases += 1;
    same(
        source.prompt_last_logits(&[1, 7, 13], 48).unwrap(),
        &original,
        &mut compared,
    );
    drop(projected);
    drop(source);
    same(
        child.prompt_last_logits(&[1, 7, 13], 48).unwrap(),
        &changed,
        &mut compared,
    );
    cases += 1;
    assert_eq!((cases, refusals, compared), (13, 9, 288));
    println!("F6E_PROJECTION_PRODUCTION_TEST {{\"test\":\"default_constructor_routes_and_owned_lifecycle\",\"status\":\"passed\",\"expected_cases\":13,\"executed_cases\":{cases},\"expected_rejections\":9,\"rejected_cases\":{refusals},\"expected_values\":288,\"compared_values\":{compared},\"model_loads\":1,\"constructor_calls\":2,\"library_cfg_test\":false,\"private_feature\":false}}");
}
