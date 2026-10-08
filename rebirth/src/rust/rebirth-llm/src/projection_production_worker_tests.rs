// Included in async_job::tests. Exercises accepted constructor through the real
// worker with existing numeric input/publication seams; no tokenizer claim.
#[test]
fn projection_static_live_restore_cancel_and_poison() {
    let source = crate::load_with_batch(
        crate::LoadRequest {
            path: f6b_root().join("tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"),
            context_length: 128,
            gpu_layers: Some(0),
            backend: crate::BackendKind::Cpu,
            mmap: true,
            projector: None,
        },
        Some(4),
    )
    .unwrap();
    let entries = f6b_entries(1.0);
    let req = f6b_request(entries.clone(), 3);
    let params = req.params.clone();
    let base = source.generate(&[1, 7], &params).unwrap();
    let mut direction = [0.; 32];
    direction[1] = 1.;
    let command = crate::ProjectionCommand {
        mode: crate::ProjectionAdmissionMode::NewSite,
        layer: 1,
        component: crate::Component::MlpOut,
        coef: 1.,
        direction: &direction,
        steer_entries: 1,
        ablate_entries: 0,
        existing_direction_estimate: 0,
        r_projection_fixed_bytes: 4096,
        r_adapter_bytes: 0,
        max_bytes: 64 * 1024 * 1024,
    };
    let arrays = crate::ProjectionResidualArrays {
        steer_layers: &[2],
        steer_vectors: &entries[0].direction,
        ablate_layers: &[],
        ablate_neurons: &[],
        ablate_values: &[],
    };
    let (model, _) = source
        .projection_construct(&command, arrays, crate::ProjectionFfiProfile::default())
        .unwrap();
    let plan = model
        .projection()
        .runtime
        .lock()
        .unwrap()
        .as_ref()
        .unwrap()
        .plan
        .clone();
    let original = model.generate(&[1, 7], &params).unwrap();
    let mut cases = 1;
    let (mut job, rx) = f6b_start(model, req);
    let mut sampled = Vec::new();
    let mut delivered = Vec::new();
    for id in 1..=3 {
        let (state, previous) = f6b_state(&job, &rx, id);
        delivered.extend(previous);
        assert_eq!(delivered, sampled);
        assert_eq!(state.steering_revision, id - 1);
        assert_eq!(state.steering[0].coef, [1., 0., 1.][id - 1]);
        let rows = match &state.trace {
            crate::LiveTrace::Memory(rows) => rows,
            #[cfg(feature = "spill")]
            crate::LiveTrace::Spilled(_) => panic!("bounded memory fixture"),
        };
        let row = rows
            .iter()
            .find(|r| r.layer == 1 && r.component == crate::Component::MlpOut)
            .unwrap();
        assert_eq!(
            row.values[1], 0.,
            "live capture observes the static post-edit producer"
        );
        sampled.push(state.token_id);
        let reply = match id {
            1 => f6b_reply(0, 0.),
            2 => f6b_reply(0, 1.),
            _ => vec![],
        };
        job.ack_state_with_reply(state.job_id, id, reply).unwrap();
        cases += 1;
    }
    let mut completion = job.worker.take().unwrap().join().unwrap();
    delivered.extend(
        job.drain_stream()
            .unwrap()
            .0
            .iter()
            .filter_map(|e| e.token_id)
            .map(|x| x - 1),
    );
    assert_eq!(delivered, sampled);
    assert_eq!(completion.result.as_ref().unwrap()[0].tokens, sampled);
    assert!(!completion.model_invalidated && !completion.panicked);
    cases += 1;
    let model = completion.model.take().unwrap();
    drop(completion);
    assert!(Arc::ptr_eq(
        &plan,
        &model
            .projection()
            .runtime
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .plan
    ));
    assert_eq!(model.generate(&[1, 7], &params).unwrap(), original);
    cases += 1;

    let (mut job, rx) = f6b_start(model, f6b_request(entries, 3));
    let (first, _) = f6b_state(&job, &rx, 1);
    job.ack_state_with_reply(first.job_id, 1, f6b_reply(0, -1.))
        .unwrap();
    let (second, previous) = f6b_state(&job, &rx, 2);
    assert_eq!(second.steering_revision, 1);
    assert_eq!(second.steering[0].coef, -1.);
    assert_eq!(previous, vec![first.token_id]);
    cases += 1;
    assert!(job.cancel());
    job.ack_state(second.job_id, 2).unwrap();
    let mut completion = job.worker.take().unwrap().join().unwrap();
    assert!(matches!(
        completion.result,
        Err(RebirthError::Cancelled { .. })
    ));
    assert!(!completion.model_invalidated);
    assert!(job
        .drain_stream()
        .unwrap()
        .0
        .iter()
        .all(|e| e.token_id.is_none()));
    let model = completion.model.take().unwrap();
    drop(completion);
    assert_eq!(model.generate(&[1, 7], &params).unwrap(), original);
    assert!(Arc::ptr_eq(
        &plan,
        &model
            .projection()
            .runtime
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .plan
    ));
    cases += 1;

    model.projection_fault(crate::projection_layout::Fault::AfterRow);
    let mut req = request();
    req.params = params.clone();
    req.stream = true;
    req.numeric_prompts = Some(vec![vec![1, 7]]);
    let mut job = AsyncJob::start(
        model,
        req,
        ExecutionPermit::try_acquire("projected poison fixture").unwrap(),
    )
    .unwrap_or_else(|e| panic!("{}", e.error));
    let completion = job.worker.take().unwrap().join().unwrap();
    assert!(completion.model_invalidated && completion.model.is_none());
    assert!(matches!(
        completion.result,
        Err(RebirthError::Intervention { .. })
    ));
    assert!(job
        .drain_stream()
        .unwrap()
        .0
        .iter()
        .all(|e| e.token_id.is_none()));
    drop(completion);
    cases += 1;
    assert_eq!(source.generate(&[1, 7], &params).unwrap(), base);
    cases += 1;
    assert_eq!(cases, 10);
    println!("F6E_PROJECTION_PRODUCTION_TEST {{\"test\":\"projection_static_live_restore_cancel_and_poison\",\"status\":\"passed\",\"expected_cases\":10,\"executed_cases\":{cases},\"expected_rejections\":2,\"rejected_cases\":2,\"expected_values\":3,\"compared_values\":3,\"model_loads\":1,\"constructor_calls\":1,\"library_cfg_test\":true,\"private_feature\":false}}");
}
