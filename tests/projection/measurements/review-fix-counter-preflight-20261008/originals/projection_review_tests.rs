//! Focused closure of the zero-coefficient/shared-live-callback review finding.
use super::*;
use crate::live_capture::LiveSnapshot;
use crate::projection_profile::{
    ProjectionAdmissionMode, ProjectionCommand, ProjectionFfiProfile, ProjectionResidualArrays,
};

fn exact_values(actual: &[f32], expected: &[f32], compared: &mut usize) {
    assert_eq!(actual.len(), expected.len());
    for (&actual, &expected) in actual.iter().zip(expected) {
        assert!(actual.is_finite() && expected.is_finite());
        assert_eq!(actual.to_bits(), expected.to_bits());
        *compared += 1;
    }
}

#[test]
fn projection_zero_live_capture_preserves_identity_without_row_work() {
    let _native = crate::NativeGuard::acquire("projection zero/live review fixture");
    let source = crate::load_with_batch(
        crate::LoadRequest {
            path: std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../../tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"),
            context_length: 128,
            gpu_layers: Some(0),
            backend: crate::BackendKind::Cpu,
            mmap: true,
            projector: None,
        },
        Some(4),
    )
    .unwrap();
    let prompt = [1, 7, 13];
    let params = crate::GenerateParams {
        max_tokens: 2,
        temperature: 0.,
        top_p: 1.,
        seed: 42,
        stop: Vec::new(),
    };
    let mut cases = 0;
    let mut rejected = 0;
    let mut compared = 0;
    let mut baseline: Vec<(LiveSnapshot, Vec<f32>)> = Vec::with_capacity(2);
    let original = source
        .generate_observed(
            &prompt,
            &params,
            &[1],
            &[Component::MlpOut],
            &mut |snapshot, logits| {
                assert!(baseline.len() < 2);
                baseline.push((snapshot, logits.to_vec()));
                Ok(())
            },
        )
        .unwrap();
    assert_eq!(baseline.len(), 2);
    assert_eq!(original.tokens.len(), 2);
    cases += 1;

    let mut direction = [0.; 32];
    direction[1] = 1.;
    let command = ProjectionCommand {
        mode: ProjectionAdmissionMode::NewSite,
        layer: 1,
        component: Component::MlpOut,
        coef: 0.,
        direction: &direction,
        steer_entries: 0,
        ablate_entries: 0,
        existing_direction_estimate: 0,
        r_projection_fixed_bytes: 4096,
        r_adapter_bytes: 0,
        max_bytes: 64 * 1024 * 1024,
    };
    let (zero, construction) = source
        .projection_construct(
            &command,
            ProjectionResidualArrays::empty(),
            ProjectionFfiProfile::default(),
        )
        .unwrap();
    assert_eq!(construction.projection_probe_decodes, 2);
    assert_eq!(construction.residual_probe_decodes, 0);
    zero.projection_reset_stats();
    const SCRATCH_BITS: u32 = 0x7fc0_1234;
    {
        let mut runtime = zero.projection().lock();
        let runtime = runtime.as_mut().unwrap();
        assert!(runtime.proofs[0].proven);
        assert!(runtime.probe.is_none() && runtime.audit.is_none());
        runtime.row.fill(f32::from_bits(SCRATCH_BITS));
    }
    cases += 1;

    let mut delivered = 0;
    let actual = zero
        .generate_observed(
            &prompt,
            &params,
            &[1],
            &[Component::MlpOut],
            &mut |snapshot, logits| {
                assert!(delivered < 2);
                let (expected, expected_logits) = &baseline[delivered];
                assert_eq!(snapshot.state_id, delivered + 1);
                assert_eq!(snapshot.state_id, expected.state_id);
                assert_eq!(snapshot.token_id, expected.token_id);
                assert_eq!(snapshot.context_pos, expected.context_pos);
                assert_eq!(snapshot.source_pos, expected.source_pos);
                assert_eq!(snapshot.source_token, expected.source_token);
                assert_eq!(snapshot.prompt_count, prompt.len());
                assert_eq!(snapshot.rows.len(), 1);
                assert_eq!(expected.rows.len(), 1);
                assert!(snapshot.trace.is_none() && expected.trace.is_none());
                assert_eq!(snapshot.copies, 1);
                assert_eq!(snapshot.copied_bytes, 32 * 4);
                let row = &snapshot.rows[0];
                let expected_row = &expected.rows[0];
                assert_eq!(row.layer, 1);
                assert_eq!(row.component, Component::MlpOut);
                assert_eq!(row.prompt_id, expected_row.prompt_id);
                assert_eq!(row.token_pos, expected_row.token_pos);
                assert_eq!(row.token, expected_row.token);
                assert_eq!(row.values.len(), 32);
                assert_eq!(logits.len(), 48);
                exact_values(&row.values, &expected_row.values, &mut compared);
                exact_values(logits, expected_logits, &mut compared);
                delivered += 1;
                Ok(())
            },
        )
        .unwrap();
    assert_eq!(actual, original);
    assert_eq!(delivered, 2);
    cases += 1;

    let zero_stats = zero.projection_stats();
    assert_eq!(zero_stats.rows, 0);
    assert_eq!(zero_stats.read_bytes, 0);
    assert_eq!(zero_stats.write_bytes, 0);
    assert_eq!(zero_stats.barriers, 0);
    assert!(zero
        .projection()
        .lock()
        .as_ref()
        .unwrap()
        .row
        .iter()
        .all(|v| v.to_bits() == SCRATCH_BITS));
    cases += 1;

    // Private observation must still read the site. The ordinary generation
    // loop decodes the final sampled token too: three prefill rows plus one.
    zero.projection_reset_stats();
    zero.projection_audit(&[2]);
    let one = crate::GenerateParams {
        max_tokens: 1,
        ..params.clone()
    };
    zero.generate(&prompt, &one).unwrap();
    let audit_stats = zero.projection_stats();
    let (audit, witnesses) = zero.projection_take_audit();
    let site_rows: Vec<_> = audit
        .iter()
        .filter(|r| r.layer == 1 && r.component == Component::MlpOut && r.position == 2)
        .collect();
    assert_eq!(site_rows.len(), 2);
    assert!(site_rows[0].before && !site_rows[1].before);
    for row in site_rows {
        exact_values(&row.values, &baseline[0].0.rows[0].values, &mut compared);
    }
    assert_eq!(audit_stats.rows, 4);
    assert!(audit_stats.read_bytes > 0);
    assert_eq!(audit_stats.write_bytes, 0);
    assert_eq!(witnesses.len(), 4);
    assert!(witnesses.iter().all(|w| !w.write));
    cases += 1;

    let mut refused_deliveries = 0;
    let invalid = zero.generate_observed(
        &prompt,
        &params,
        &[1, 1],
        &[Component::MlpOut],
        &mut |_, _| {
            refused_deliveries += 1;
            Ok(())
        },
    );
    assert!(matches!(invalid, Err(RebirthError::Trace { .. })));
    assert_eq!(refused_deliveries, 0);
    assert!(!zero.projection().failed());
    cases += 1;
    rejected += 1;

    // Zero remains subject to the producer/graph-reuse check before any bypass.
    zero.projection().lock().as_mut().unwrap().proofs[0].wrappers = Some(u32::MAX);
    let invalid =
        zero.generate_observed(&prompt, &params, &[1], &[Component::MlpOut], &mut |_, _| {
            refused_deliveries += 1;
            Ok(())
        });
    assert!(matches!(invalid, Err(RebirthError::Intervention { .. })));
    assert_eq!(refused_deliveries, 0);
    assert!(zero.projection().failed());
    cases += 1;
    rejected += 1;

    assert_eq!(source.generate(&prompt, &params).unwrap(), original);
    cases += 1;
    assert_eq!((cases, rejected, compared), (8, 2, 224));
    println!(
        "F6E_PROJECTION_REVIEW_TEST {}",
        serde_json::json!({
            "test":"projection_zero_live_capture_preserves_identity_without_row_work",
            "status":"passed", "expected_cases":8, "executed_cases":cases,
            "expected_rejections":2, "rejected_cases":rejected,
            "expected_values":224, "compared_values":compared, "max_abs_error":0.0,
            "model_loads":1, "constructor_calls":1,
            "probe_decodes":construction.projection_probe_decodes,
            "live_states":delivered, "zero_rows":zero_stats.rows,
            "zero_read_bytes":zero_stats.read_bytes, "zero_write_bytes":zero_stats.write_bytes,
            "zero_barriers":zero_stats.barriers, "audit_rows":audit_stats.rows,
            "refused_deliveries":refused_deliveries,
            "source":std::env::var("F6E_SOURCE").unwrap_or_default()
        })
    );
}
