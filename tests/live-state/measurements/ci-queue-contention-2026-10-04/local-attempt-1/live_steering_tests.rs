// Included in async_job::tests to exercise the production worker and its existing
// identity-correlated publication seam. All tests are download-free and enabled
// with the default feature set; spill repeats are additionally feature-gated.
fn f6b_root() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../..")
}
fn f6b_entries(coef: f64) -> Vec<crate::LiveSteer> {
    vec![crate::LiveSteer {
        intervention: 0,
        layer: 1,
        coef,
        direction: (0..32)
            .map(|i| if i % 2 == 0 { 1.5 } else { -1.5 })
            .collect(),
    }]
}
fn f6b_model(entries: &[crate::LiveSteer], ablate: bool) -> LoadedModel {
    let base = crate::load_with_batch(
        crate::LoadRequest {
            path: f6b_root().join("tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"),
            context_length: 128,
            gpu_layers: None,
            backend: crate::BackendKind::Cpu,
            mmap: true,
            projector: None,
        },
        Some(4),
    )
    .unwrap();
    let mut spec = crate::InterventionSpec::new(32, 3);
    for entry in entries {
        let scaled: Vec<f32> = entry
            .direction
            .iter()
            .map(|v| (v * entry.coef) as f32)
            .collect();
        spec.add_steer(entry.layer as usize, &scaled);
    }
    if ablate {
        spec.add_ablation(1, &[2], 0.25);
    }
    base.derive_with_interventions(&spec).unwrap()
}
fn f6b_request(entries: Vec<crate::LiveSteer>, states: usize) -> AsyncRequest {
    let mut req = request();
    req.params.max_tokens = states;
    req.stream = true;
    req.numeric_prompts = Some(vec![vec![1, 7]]);
    let mut live = crate::live_state::tests::request();
    live.layers = vec![0, 1, 2];
    live.top = 48;
    live.steering = entries;
    req.live = Some(live);
    req
}
fn f6b_start(
    model: LoadedModel,
    req: AsyncRequest,
) -> (AsyncJob, std::sync::mpsc::Receiver<(u64, usize)>) {
    let (tx, rx) = std::sync::mpsc::channel();
    TEST_LIVE_PUBLISHED.with(|slot| *slot.borrow_mut() = Some(tx));
    let job = AsyncJob::start(
        model,
        req,
        ExecutionPermit::try_acquire("F6b fixture").unwrap(),
    )
    .unwrap_or_else(|e| panic!("F6b start: {}", e.error));
    (job, rx)
}
fn f6b_state(
    job: &AsyncJob,
    rx: &std::sync::mpsc::Receiver<(u64, usize)>,
    id: usize,
) -> (crate::LiveState, Vec<i32>) {
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap(),
        (job.id(), id)
    );
    drop(job.control.lock());
    let (events, empty) = drain_before_live_state(job);
    assert!(empty);
    let previous = events
        .iter()
        .filter_map(|e| e.token_id)
        .map(|id| id - 1)
        .collect();
    let state = job.drain_state().unwrap().unwrap();
    assert_eq!(state.state_id, id);
    (state, previous)
}
fn f6b_reply(intervention: u32, coef: f64) -> crate::LiveReply {
    vec![crate::LiveCoefficient { intervention, coef }]
}
fn f6b_csv(name: &str) -> Vec<Vec<String>> {
    std::fs::read_to_string(
        f6b_root()
            .join("tests/llm-golden/live-state/f6b/goldens")
            .join(name),
    )
    .unwrap()
    .lines()
    .skip(1)
    .filter(|line| !line.is_empty())
    .map(|line| line.split(',').map(str::to_owned).collect())
    .collect()
}
fn f6b_digest(path: &std::path::Path, expected: &str) {
    let mut cmd = if cfg!(target_os = "macos") {
        let mut c = std::process::Command::new("shasum");
        c.args(["-a", "256"]);
        c
    } else {
        std::process::Command::new("sha256sum")
    };
    let out = cmd.arg(path).output().unwrap();
    assert!(out.status.success());
    assert_eq!(
        String::from_utf8(out.stdout)
            .unwrap()
            .split_whitespace()
            .next()
            .unwrap(),
        expected
    );
}

#[test]
fn f6b_history_preserving_updates_match_independent_goldens() {
    let dir = f6b_root().join("tests/llm-golden/live-state/f6b/goldens");
    let manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
    f6b_digest(
        &f6b_root().join(manifest["model"]["path"].as_str().unwrap()),
        manifest["model"]["sha256"].as_str().unwrap(),
    );
    for (name, artifact) in manifest["artifacts"].as_object().unwrap() {
        f6b_digest(&dir.join(name), artifact["sha256"].as_str().unwrap());
    }
    let states = f6b_csv("states.csv");
    let activations = f6b_csv("activations.csv");
    let logits = f6b_csv("logits.csv");
    let mut checked = 0;
    let mut max_activation = 0.0_f64;
    let mut max_logit = 0.0_f64;
    for (case, ablate) in [("dynamic_steer", false), ("dynamic_both", true)] {
        let entries = f6b_entries(1.0);
        let model = f6b_model(&entries, ablate);
        let req = f6b_request(entries, 5);
        let original = model.generate(&[1, 7], &req.params).unwrap();
        let params = req.params.clone();
        let (mut job, rx) = f6b_start(model, req);
        let mut sampled = Vec::new();
        let mut delivered = Vec::new();
        for id in 1..=5 {
            let (state, previous) = f6b_state(&job, &rx, id);
            delivered.extend(previous);
            assert_eq!(delivered, sampled, "state precedes current token event");
            let reference = states
                .iter()
                .find(|r| r[0] == case && r[1] == id.to_string())
                .unwrap();
            assert_eq!(state.token_id + 1, reference[3].parse::<i32>().unwrap());
            assert_eq!(state.context_pos + 1, reference[4].parse::<u32>().unwrap());
            assert_eq!(state.source_pos + 1, reference[5].parse::<u32>().unwrap());
            assert_eq!(state.prompt_token_count, 2);
            assert_eq!(state.steering_revision, [0, 1, 2, 3, 3][id - 1]);
            assert_eq!(state.applied_after_state, [0, 1, 2, 3, 3][id - 1]);
            assert_eq!(state.effective_source_pos, [0, 2, 3, 4, 4][id - 1]);
            assert_eq!(
                state.steering,
                vec![crate::LiveSteeringRow {
                    intervention: 0,
                    layer: 1,
                    coef: [1.0, 0.0, -1.0, 1.0, 1.0][id - 1]
                }]
            );
            let rows = match &state.trace {
                crate::LiveTrace::Memory(rows) => rows,
                #[cfg(feature = "spill")]
                crate::LiveTrace::Spilled(_) => panic!("memory fixture"),
            };
            assert_eq!(rows.len(), 9);
            for row in rows {
                assert_eq!(row.token_pos, state.source_pos);
                for (neuron, &value) in row.values.iter().enumerate() {
                    let reference = activations
                        .iter()
                        .find(|r| {
                            r[0] == case
                                && r[1] == id.to_string()
                                && r[2] == (row.layer + 1).to_string()
                                && r[3] == row.component.as_str()
                                && r[4] == (neuron + 1).to_string()
                        })
                        .unwrap();
                    let delta = (value as f64 - reference[5].parse::<f64>().unwrap()).abs();
                    max_activation = max_activation.max(delta);
                    assert!(delta <= 1e-2, "{case} state{id} activation {delta}");
                    checked += 1;
                }
            }
            assert_eq!(state.logits.len(), 48);
            assert!((state.logits.iter().map(|r| r.prob).sum::<f64>() - 1.0).abs() <= 1e-12);
            for row in &state.logits {
                let reference = logits
                    .iter()
                    .find(|r| {
                        r[0] == case
                            && r[1] == id.to_string()
                            && r[2] == (row.token_id + 1).to_string()
                    })
                    .unwrap();
                let delta = (row.logit as f64 - reference[3].parse::<f64>().unwrap()).abs();
                max_logit = max_logit.max(delta);
                assert!(delta <= 1e-2, "{case} state{id} logit {delta}");
                assert!((row.prob - reference[4].parse::<f64>().unwrap()).abs() <= 1e-2);
                checked += 1;
            }
            sampled.push(state.token_id);
            let reply = match id {
                1 => f6b_reply(0, 0.0),
                2 => f6b_reply(0, -1.0),
                3 => f6b_reply(0, 1.0),
                _ => vec![],
            };
            job.ack_state_with_reply(state.job_id, id, reply).unwrap();
        }
        let mut completion = job.worker.take().unwrap().join().unwrap();
        delivered.extend(
            job.drain_stream()
                .unwrap()
                .0
                .iter()
                .filter_map(|e| e.token_id)
                .map(|id| id - 1),
        );
        assert_eq!(delivered, sampled);
        assert_eq!(completion.result.as_ref().unwrap()[0].tokens, sampled);
        assert!(!completion.model_invalidated && !completion.panicked);
        let restored = completion.model.take().unwrap();
        drop(completion);
        assert_eq!(
            restored.generate(&[1, 7], &params).unwrap(),
            original,
            "fresh generation restores original adapters including ablation"
        );
    }
    assert_eq!(checked, 3360);
    println!("F6B_GOLDEN compared_values={checked} max_activation_delta={max_activation:.9} max_logit_delta={max_logit:.9}");
}

#[test]
fn f6b_partial_identical_and_terminal_replies_preserve_revision() {
    let mut entries = f6b_entries(1.0);
    entries.push(crate::LiveSteer {
        intervention: 3,
        layer: 1,
        coef: 0.0,
        direction: Arc::from([0.25; 32]),
    });
    let model = f6b_model(&entries, true);
    let req = f6b_request(entries, 4);
    let original = model.generate(&[1, 7], &req.params).unwrap();
    let params = req.params.clone();
    let (mut job, rx) = f6b_start(model, req);
    for id in 1..=4 {
        let (state, _) = f6b_state(&job, &rx, id);
        assert_eq!(state.steering_revision, usize::from(id >= 3));
        assert_eq!(state.applied_after_state, if id >= 3 { 2 } else { 0 });
        assert_eq!(
            state.steering[0].coef, 1.0,
            "omitted original entry retains coefficient"
        );
        assert_eq!(state.steering[1].coef, if id >= 3 { 0.5 } else { 0.0 });
        let reply = match id {
            1 => f6b_reply(0, 1.0),
            2 | 3 => f6b_reply(3, 0.5),
            _ => f6b_reply(0, -1.0),
        };
        job.ack_state_with_reply(state.job_id, id, reply).unwrap();
    }
    let mut completion = job.worker.take().unwrap().join().unwrap();
    assert_eq!(completion.result.as_ref().unwrap()[0].tokens.len(), 4);
    let model = completion.model.take().unwrap();
    drop(completion);
    assert_eq!(model.generate(&[1, 7], &params).unwrap(), original);
}

#[test]
fn f6b_invalid_reply_after_update_restores_original_adapter() {
    let mut entries = f6b_entries(1.0);
    entries.push(crate::LiveSteer {
        intervention: 3,
        layer: 1,
        coef: 0.0,
        direction: Arc::from([1.0; 32]),
    });
    let mut model = f6b_model(&entries, true);
    let params = f6b_request(entries.clone(), 3).params;
    let original = model.generate(&[1, 7], &params).unwrap();
    for reply in [
        vec![
            crate::LiveCoefficient {
                intervention: 0,
                coef: 1.0,
            },
            crate::LiveCoefficient {
                intervention: 0,
                coef: 0.5,
            },
        ],
        f6b_reply(1, 1.0),
        f6b_reply(0, f64::NAN),
        f6b_reply(0, f64::MAX),
        f6b_reply(0, f64::from_bits((f32::MAX as f64).to_bits() + 1)),
        f6b_reply(0, f32::MAX as f64),
        vec![
            crate::LiveCoefficient {
                intervention: 0,
                coef: 0.5 * f32::MAX as f64,
            },
            crate::LiveCoefficient {
                intervention: 3,
                coef: 0.5 * f32::MAX as f64,
            },
        ],
    ] {
        let (mut job, rx) = f6b_start(model, f6b_request(entries.clone(), 3));
        let (state, _) = f6b_state(&job, &rx, 1);
        job.ack_state_with_reply(state.job_id, 1, f6b_reply(0, 0.0))
            .unwrap();
        let (state, previous) = f6b_state(&job, &rx, 2);
        assert_eq!(previous.len(), 1);
        assert_eq!(state.steering_revision, 1);
        job.ack_state_with_reply(state.job_id, 2, reply).unwrap();
        let mut completion = job.worker.take().unwrap().join().unwrap();
        assert!(
            matches!(&completion.result, Err(RebirthError::Argument { argument, .. }) if argument == "on_state_reply")
        );
        assert!(!completion.panicked && !completion.model_invalidated);
        assert!(
            job.drain_stream().unwrap().0.is_empty(),
            "rejected reply publishes no current token"
        );
        model = completion.model.take().unwrap();
        drop(completion);
        assert_eq!(model.generate(&[1, 7], &params).unwrap(), original);
    }
}

#[test]
fn f6b_cancel_and_close_after_update_restore_original_adapter() {
    let entries = f6b_entries(1.0);
    let mut model = f6b_model(&entries, true);
    let params = f6b_request(entries.clone(), 3).params;
    let original = model.generate(&[1, 7], &params).unwrap();
    for close in [false, true] {
        let (mut job, rx) = f6b_start(model, f6b_request(entries.clone(), 3));
        let (state, _) = f6b_state(&job, &rx, 1);
        job.ack_state_with_reply(state.job_id, 1, f6b_reply(0, -1.0))
            .unwrap();
        let (state, previous) = f6b_state(&job, &rx, 2);
        assert_eq!(state.steering_revision, 1);
        assert_eq!(previous.len(), 1);
        let mut completion = if close {
            job.shutdown().unwrap()
        } else {
            assert!(job.cancel());
            // Accepted cancellation wins even an otherwise invalid command.
            job.ack_state_with_reply(state.job_id, 2, f6b_reply(999, f64::NAN))
                .unwrap();
            job.worker.take().unwrap().join().unwrap()
        };
        assert!(matches!(
            completion.result,
            Err(RebirthError::Cancelled { .. })
        ));
        assert!(job.drain_stream().unwrap().0.is_empty());
        assert!(!completion.model_invalidated);
        model = completion.model.take().unwrap();
        drop(completion);
        assert_eq!(model.generate(&[1, 7], &params).unwrap(), original);
    }
    let control = live_control();
    let job = control_job(control.clone());
    CONTROL.with(|slot| *slot.borrow_mut() = Some(control));
    assert!(job.cancel());
    let called = std::cell::Cell::new(false);
    let result = apply_live_command(|| {
        called.set(true);
        Ok(())
    });
    CONTROL.with(|slot| slot.borrow_mut().take());
    assert!(matches!(result, Err(RebirthError::Cancelled { .. })));
    assert!(
        !called.get(),
        "cancel accepted before command prevents the setter"
    );
}

#[test]
fn f6b_setter_reset_and_panic_failures_have_explicit_ownership() {
    for fault in [1, 2, 3] {
        let entries = f6b_entries(1.0);
        let model = f6b_model(&entries, false);
        let req = f6b_request(entries, 2);
        let params = req.params.clone();
        let original = model.generate(&[1, 7], &params).unwrap();
        let (mut job, rx) = f6b_start(model, req);
        let (state, _) = f6b_state(&job, &rx, 1);
        job.control.steering_fault.store(fault, Ordering::Release);
        job.ack_state_with_reply(state.job_id, 1, f6b_reply(0, 0.0))
            .unwrap();
        if fault == 1 {
            let (state, _) = f6b_state(&job, &rx, 2);
            job.ack_state(state.job_id, 2).unwrap();
        }
        let mut completion = job.worker.take().unwrap().join().unwrap();
        assert!(completion.result.is_err());
        assert_eq!(completion.model_invalidated, fault == 1);
        assert_eq!(completion.panicked, fault == 3);
        if fault == 2 {
            let model = completion.model.take().unwrap();
            drop(completion);
            assert_eq!(model.generate(&[1, 7], &params).unwrap(), original);
        } else {
            assert!(
                completion.model.is_none(),
                "unrestorable or panicked context cannot escape"
            );
        }
    }
}

#[test]
fn f6b_zero_initial_coefficient_is_probed_before_activation() {
    let entries = f6b_entries(0.0);
    let model = f6b_model(&entries, false);
    assert!(!model.steering_layer_was_probed(1));
    assert_eq!(model.steering_probe_cache_bytes(), 3);
    let estimate = f6b_request(entries.clone(), 2)
        .live
        .unwrap()
        .preflight(&model.metadata(), 2)
        .unwrap();
    assert_eq!(
        estimate.steering_probe_bytes,
        4 * 32 * 3
            + 4 * 32
            + model.steering_probe_cache_bytes() as u64
            + estimate.steering_probe_fixed_bytes
    );
    let (mut job, rx) = f6b_start(model, f6b_request(entries, 2));
    let (state, _) = f6b_state(&job, &rx, 1);
    assert_eq!(state.steering[0].coef, 0.0);
    job.ack_state_with_reply(state.job_id, 1, f6b_reply(0, 1.0))
        .unwrap();
    let (state, _) = f6b_state(&job, &rx, 2);
    assert_eq!(state.steering_revision, 1);
    assert_eq!(state.steering[0].coef, 1.0);
    job.ack_state(state.job_id, 2).unwrap();
    let completion = job.worker.take().unwrap().join().unwrap();
    assert!(completion.result.is_ok());
    assert!(completion
        .model
        .as_ref()
        .unwrap()
        .steering_layer_was_probed(1));
    assert_eq!(
        completion
            .model
            .as_ref()
            .unwrap()
            .steering_probe_cache_bytes(),
        3,
        "proving a layer cannot grow the fixed cache"
    );
}

#[test]
fn f6b_original_direction_mismatch_fails_before_publication() {
    let entries = f6b_entries(1.0);
    let model = f6b_model(&entries, false);
    let mut bad = entries;
    bad[0].coef = 0.0;
    let (mut job, rx) = f6b_start(model, f6b_request(bad, 2));
    let completion = job.worker.take().unwrap().join().unwrap();
    assert!(
        matches!(&completion.result, Err(RebirthError::Argument { argument, .. }) if argument == "on_state")
    );
    assert!(completion.model.is_some());
    assert!(rx.try_recv().is_err());
    assert!(job.drain_stream().unwrap().0.is_empty());
}
