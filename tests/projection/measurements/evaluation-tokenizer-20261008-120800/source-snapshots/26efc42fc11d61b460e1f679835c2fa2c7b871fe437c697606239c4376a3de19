//! New constructor gates only. Owner-run local tiny fixture; no Qwen or old suite.
use super::*;
use crate::projection_profile::*;
fn marker(name: &str, cases: usize, refusals: usize, values: usize, max: f64, loads: usize) {
    println!(
        "F6E_PROJECTION_CONSTRUCTOR_TEST {}",
        serde_json::json!({"test": name, "status":"passed", "expected_cases":cases,"executed_cases":cases,"expected_rejections":refusals,"rejected_cases":refusals,"expected_values":values,"compared_values":values,"max_abs_error":max,"model_loads":loads,"source":std::env::var("F6E_SOURCE").unwrap_or_default()})
    );
}
fn command(direction: &[f64]) -> ProjectionCommand<'_> {
    ProjectionCommand {
        mode: ProjectionAdmissionMode::NewSite,
        layer: 1,
        component: Component::MlpOut,
        coef: 1.,
        direction,
        steer_entries: 0,
        ablate_entries: 0,
        existing_direction_estimate: 0,
        r_projection_fixed_bytes: 4096,
        r_adapter_bytes: 0,
        max_bytes: 64 * 1024 * 1024,
    }
}
fn tiny() -> LoadedModel {
    crate::engine::load_for_live_feasibility(
        crate::LoadRequest {
            path: std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../../tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"),
            context_length: 768,
            gpu_layers: Some(0),
            backend: crate::BackendKind::Cpu,
            mmap: true,
            projector: None,
        },
        Some(512),
        Some(128),
        true,
    )
    .unwrap()
}
fn csv(name: &str) -> Vec<Vec<String>> {
    std::fs::read_to_string(
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../tests/llm-golden/projection/goldens")
            .join(name),
    )
    .unwrap()
    .lines()
    .skip(1)
    .map(|r| r.split(',').map(str::to_owned).collect())
    .collect()
}
#[test]
fn constructor_residual_probe_and_frame_equations() {
    let p = ProjectionAllocationProfile::compiled(ProjectionFfiProfile::default());
    let mut cases = 0;
    for (h, d) in [(1, 1), (32, 3), (65536, 3)] {
        for (s, a) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let i = ProjectionAdmission {
                mode: ProjectionAdmissionMode::NewSite,
                hidden_size: h,
                layers: d,
                previous_sites: 0,
                steer_entries: s,
                ablate_entries: a,
                source_baseline_values: 0,
                metadata_bytes: 0,
                metadata_scratch_bytes: 0,
                backend: 0,
                existing_direction_estimate: 0,
                r_projection_fixed_bytes: 0,
                r_adapter_bytes: 0,
                max_bytes: 512 * 1024 * 1024,
            };
            let e = p.estimate(&i).unwrap();
            assert_eq!(
                e.residual_probe_bytes,
                if s + a == 0 {
                    0
                } else {
                    8 * h * d + 4 * h + p.residual_probe_fixed_bytes
                }
            );
            let mut exact = i;
            exact.max_bytes = e.total_bytes;
            assert!(p.estimate(&exact).is_ok());
            exact.max_bytes -= 1;
            assert!(p.estimate(&exact).is_err());
            cases += 1;
        }
    }
    assert_eq!(
        p.residual_probe_fixed_bytes,
        crate::probe::projection_residual_probe_fixed_bytes() as u64
    );
    marker(
        "constructor_residual_probe_and_frame_equations",
        cases,
        12,
        0,
        0.,
        0,
    );
}
#[test]
fn constructor_source_budget_inheritance_and_failure_ownership() {
    let _guard = crate::NativeGuard::acquire("constructor fixture");
    let source = tiny();
    let mut axis = [0.; 32];
    axis[1] = 1.;
    let mut c = command(&axis);
    let arrays = ProjectionResidualArrays::empty();
    let ffi = ProjectionFfiProfile::default();
    source
        .decode_projection_tokens(&[1, 7, 13], 0, true)
        .unwrap();
    let original = source.logits_ith(-1, 48).unwrap();
    c.component = Component::Residual;
    assert!(source.projection_construct(&c, arrays, ffi).is_err());
    c.component = Component::MlpOut;
    source.steering_restore_failed.set(true);
    assert!(source.projection_construct(&c, arrays, ffi).is_err());
    source.steering_restore_failed.set(false);
    let total = source.projection_preflight(&c, ffi).unwrap().2.total_bytes;
    c.max_bytes = total - 1;
    assert!(source.projection_construct(&c, arrays, ffi).is_err());
    c.max_bytes = total;
    let (candidate, receipt) = source.projection_construct(&c, arrays, ffi).unwrap();
    assert_eq!(receipt.projection_probe_decodes, 2);
    assert_eq!(receipt.residual_probe_decodes, 0);
    assert_eq!(receipt.adapter_capacities, [0; 10]);
    assert_eq!(candidate.n_batch(), source.n_batch());
    assert_eq!(
        unsafe { ffi::llama_n_ubatch(candidate.ctx_ptr()) },
        unsafe { ffi::llama_n_ubatch(source.ctx_ptr()) }
    );
    assert_eq!(source.logits_ith(-1, 48).unwrap(), original);
    let mut inherited = command(&[]);
    inherited.mode = ProjectionAdmissionMode::Inherit;
    let (copy, receipt) = candidate
        .projection_construct(&inherited, arrays, ffi)
        .unwrap();
    assert_eq!(receipt.projection_probe_decodes, 2);
    assert!(Arc::ptr_eq(
        &candidate.projection().lock().as_ref().unwrap().plan,
        &copy.projection().lock().as_ref().unwrap().plan
    ));
    assert_ne!(candidate.ctx_ptr(), copy.ctx_ptr());
    assert!(candidate.token_embeddings(&[1]).is_err());
    assert!(candidate
        .activations(
            &[1],
            &crate::CaptureSpec {
                layers: None,
                positions: crate::Positions::All,
                components: vec![Component::Residual]
            }
        )
        .is_err());
    assert!(candidate.projection_construct(&c, arrays, ffi).is_err());
    c.max_bytes = 64 * 1024 * 1024;
    let owners = source.projection_shared_model_owners();
    assert_eq!(owners, 3);
    for fault in [
        ConstructionFault::BeforeContext,
        ConstructionFault::AfterProbe,
        ConstructionFault::AfterAdapter,
        ConstructionFault::NoWrite,
        ConstructionFault::Cancel,
    ] {
        assert!(source
            .projection_construct_inner(&c, arrays, ffi, fault)
            .is_err());
        assert_eq!(source.logits_ith(-1, 48).unwrap(), original);
        assert_eq!(source.projection_shared_model_owners(), owners);
    }
    c.steer_entries = 2;
    let overflowing = [f32::MAX as f64; 64];
    assert!(source
        .projection_construct(
            &c,
            ProjectionResidualArrays {
                steer_layers: &[2, 2],
                steer_vectors: &overflowing,
                ..arrays
            },
            ffi
        )
        .is_err());
    assert_eq!(source.logits_ith(-1, 48).unwrap(), original);
    drop(copy);
    drop(candidate);
    assert_eq!(source.projection_shared_model_owners(), 1);
    source.decode_projection_tokens(&[22], 3, true).unwrap();
    assert!(source
        .logits_ith(-1, 48)
        .unwrap()
        .iter()
        .all(|x| x.is_finite()));
    marker(
        "constructor_source_budget_inheritance_and_failure_ownership",
        15,
        12,
        0,
        0.,
        1,
    );
}
#[test]
fn constructor_composition_matches_frozen_reference() {
    let _guard = crate::NativeGuard::acquire("constructor composition");
    let source = tiny();
    let mut direction = [0.; 32];
    for row in csv("forward-projections.csv")
        .iter()
        .filter(|r| r[0] == "projection_steer_ablate" && r[2] == "mlp_out")
    {
        direction[row[4].parse::<usize>().unwrap() - 1] = row[5].parse().unwrap();
    }
    let mut c = command(&direction);
    c.component = Component::AttnOut;
    let (first, _) = source
        .projection_construct(
            &c,
            ProjectionResidualArrays::empty(),
            ProjectionFfiProfile::default(),
        )
        .unwrap();
    c.component = Component::MlpOut;
    c.steer_entries = 1;
    c.ablate_entries = 1;
    let steer: Vec<f64> = (0..32)
        .map(|j| if j % 2 == 0 { 1.5 } else { -1.5 })
        .collect();
    let arrays = ProjectionResidualArrays {
        steer_layers: &[2],
        steer_vectors: &steer,
        ablate_layers: &[2],
        ablate_neurons: &[3],
        ablate_values: &[0.25],
    };
    let (model, receipt) = first
        .projection_construct(&c, arrays, ProjectionFfiProfile::default())
        .unwrap();
    assert_eq!(receipt.projection_probe_decodes, 4);
    assert_eq!(receipt.residual_probe_decodes, 3);
    assert_eq!(
        receipt.adapter_capacities,
        [1, 32, 1, 1, 1, 96, 96, 96, 32, 96]
    );
    assert!(!source.projection_residual_layer_is_cached(1, false));
    assert!(Arc::ptr_eq(
        &first.projection().lock().as_ref().unwrap().plan.sites[0].direction,
        &model.projection().lock().as_ref().unwrap().plan.sites[0].direction
    ));
    source.verify_steering_layers(&[1]).unwrap();
    assert!(source.projection_residual_layer_is_cached(1, true));
    model
        .decode_projection_tokens(&[1, 7, 13], 0, false)
        .unwrap();
    let mut count = 0;
    let mut max = 0f64;
    let rows = csv("forward-logits.csv");
    for pos in 1..=5 {
        if pos > 3 {
            model
                .decode_projection_tokens(&[if pos == 4 { 22 } else { 5 }], pos - 1, true)
                .unwrap();
        }
        let logits = model
            .logits_ith(if pos <= 3 { pos - 1 } else { -1 }, 48)
            .unwrap();
        for row in rows
            .iter()
            .filter(|r| r[0] == "projection_steer_ablate" && r[1].parse::<i32>().unwrap() == pos)
        {
            let delta = (f64::from(logits[row[2].parse::<usize>().unwrap()])
                - row[3].parse::<f64>().unwrap())
            .abs();
            assert!(delta <= 0.01, "constructor reference {pos}: {delta}");
            max = max.max(delta);
            count += 1;
        }
    }
    assert_eq!(count, 240);
    // Inheritance can add a newly requested residual layer; no permanent cache refusal.
    let mut inherit = command(&[]);
    inherit.mode = ProjectionAdmissionMode::Inherit;
    inherit.ablate_entries = 1;
    let additions = ProjectionResidualArrays {
        ablate_layers: &[1],
        ablate_neurons: &[1],
        ablate_values: &[0.],
        ..ProjectionResidualArrays::empty()
    };
    // Source has steering, so an accumulated spec must retain that kind.
    assert!(model
        .projection_construct(&inherit, additions, ProjectionFfiProfile::default())
        .is_err());
    inherit.steer_entries = 1;
    let additions = ProjectionResidualArrays {
        steer_layers: &[2],
        steer_vectors: &steer,
        ..additions
    };
    let (_, receipt) = model
        .projection_construct(&inherit, additions, ProjectionFfiProfile::default())
        .unwrap();
    assert_eq!(receipt.residual_probe_decodes, 1);
    marker(
        "constructor_composition_matches_frozen_reference",
        4,
        1,
        count,
        max,
        1,
    );
}
