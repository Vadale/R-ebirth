// WP13 hardware-only gate: cargo test --features cuda --lib cuda_projection_.
// Existing frozen golden suites remain unchanged. This gate independently
// checks the same-input operator and actual device storage on both sites.
#[test]
fn cuda_projection_device_identity_controls() {
    assert_eq!(
        unsafe { ffi::relm_projection_cuda_buffer_controls() },
        (1 << 14) - 1
    );
    println!("WP13_CUDA_IDENTITY_PASS cases=14 refusals=12");
}

#[test]
fn cuda_projection_device_rows_match_scalar_equation() {
    reference();
    let _native = crate::NativeGuard::acquire("CUDA projection device fixture");
    let source = crate::load_with_batch(
        crate::LoadRequest {
            path: root().join("tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"),
            context_length: 128,
            gpu_layers: Some(-1),
            backend: crate::BackendKind::Cuda,
            mmap: true,
            projector: None,
            threads: None,
        },
        Some(4),
    )
    .unwrap();
    let ids = [1, 7, 13, 22, 4, 9, 18, 3, 6];
    let baseline = source.logits_for_tokens(&ids).unwrap();
    let mut direction = [0.; 32];
    direction[1] = 0.6;
    direction[5] = 0.8;
    let mut count = 0;
    let mut maximum = 0.0f64;
    for component in [Component::MlpOut, Component::AttnOut] {
        let mut command = crate::ProjectionCommand {
            mode: crate::ProjectionAdmissionMode::NewSite,
            layer: 1,
            component,
            coef: 0.5,
            direction: &direction,
            steer_entries: 0,
            ablate_entries: 0,
            existing_direction_estimate: 0,
            r_projection_fixed_bytes: 4096,
            r_adapter_bytes: 0,
            max_bytes: 1,
        };
        assert!(matches!(
            source.projection_construct(
                &command,
                crate::ProjectionResidualArrays::empty(),
                crate::ProjectionFfiProfile::default()
            ),
            Err(RebirthError::Oom { .. })
        ));
        command.max_bytes = 64 * 1024 * 1024;
        let (model, construction) = source
            .projection_construct(
                &command,
                crate::ProjectionResidualArrays::empty(),
                crate::ProjectionFfiProfile::default(),
            )
            .unwrap();
        assert_eq!(construction.projection_probe_decodes, 2);
        assert_eq!(construction.residual_probe_decodes, 0);
        model.clear_memory();
        model.projection_reset_stats();
        model.projection_audit(&[0, 3, 8, 9]);
        // Beyond n_batch=4: use the ordinary checked ingest chokepoint.
        model.logits_for_tokens(&ids).unwrap();
        model.decode_projection_tokens(&[11], 9, false).unwrap();
        let (rows, witnesses) = model.projection_take_audit();
        // Retain actual before/readback coordinates, not only a pass counter.
        for row in &rows {
            if row.component == component && row.layer == 1 {
                println!(
                    "WP13_CUDA_ROW {}",
                    serde_json::json!({
                    "component": component.as_str(), "position":row.position,
                    "before":row.before,"values":row.values.as_ref()})
                );
            }
        }
        let (values, delta) = same_row_arithmetic(&model, &rows, "CUDA device row");
        assert_eq!(values, 128);
        count += values;
        maximum = maximum.max(delta.0);
        assert_eq!(witnesses.len(), 10);
        assert!(witnesses.iter().all(|w| w.write));
        let stats = model.projection_stats();
        assert_eq!(stats.rows, 10);
        assert_eq!(stats.write_bytes, 10 * 32 * 4);
        assert!(stats.read_bytes >= stats.write_bytes && stats.barriers > 0);
        let runtime = model.projection().lock();
        let proof = runtime.as_ref().unwrap().proofs[0].buffer.unwrap();
        assert_eq!(proof.access, 3);
        assert_eq!(proof.buffer.kind, 3);
        assert_eq!(proof.buffer.is_host, 0);
        assert_eq!(&proof.buffer.type_name[..6], b"CUDA0\0");
        assert_eq!(&proof.buffer.registry_name[..5], b"CUDA\0");
        assert_eq!(
            proof.buffer.flags & (256 | 2 | 4 | 8 | 16 | 32 | 64 | 128),
            256 | 2 | 4 | 8 | 16 | 32 | 64 | 128
        );
        drop(runtime);
        println!(
            "WP13_CUDA_TRANSFER {}",
            serde_json::json!({
            "component":component.as_str(),"rows":stats.rows,"read_bytes":stats.read_bytes,
            "write_bytes":stats.write_bytes,"barriers":stats.barriers,"same_row_values":values,
            "max_abs_error":delta.0,"max_scaled_error":delta.1,"device_kind":proof.access})
        );
    }
    assert_eq!(source.logits_for_tokens(&ids).unwrap(), baseline);
    assert_eq!(count, 256);
    println!(
        "WP13_CUDA_PROJECTION_PASS {}",
        serde_json::json!({
        "sites":2,"values":count,"max_abs_error":maximum,"budget_refusals":2,
        "loads":1,"constructors":2,"probe_decodes":4,"original_survived":true,
        "profile":crate::projection_profile::ProjectionAllocationProfile::compiled(
            crate::ProjectionFfiProfile::default()).fields()})
    );
}
