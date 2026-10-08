use std::path::{Path, PathBuf};
use std::time::Instant;
const REFERENCE: &str = "78729e5fe710e30dffa83e76a9d084ee15091a0ef7074230172c3293f2463959";
const TINY_SHA: &str = "e255ed5db07f318cbc3bd1d4d5a5a261bdef0867b3bbd1e26228f015b872bd05";
fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../..")
}
fn fixture(name: &str) -> PathBuf {
    root()
        .join("tests/llm-golden/projection/goldens")
        .join(name)
}
fn csv(name: &str) -> Vec<Vec<String>> {
    std::fs::read_to_string(fixture(name))
        .unwrap()
        .lines()
        .skip(1)
        .filter(|s| !s.is_empty())
        .map(|s| s.split(',').map(str::to_owned).collect())
        .collect()
}
fn digest(path: &Path) -> String {
    let mut command = if cfg!(target_os = "macos") {
        let mut c = std::process::Command::new("shasum");
        c.args(["-a", "256"]);
        c
    } else {
        std::process::Command::new("sha256sum")
    };
    let result = command.arg(path).output().unwrap();
    assert!(result.status.success());
    String::from_utf8(result.stdout)
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .to_owned()
}
fn reference() {
    assert_eq!(digest(&fixture("manifest.csv")), REFERENCE);
    if let Ok(want) = std::env::var("F6E_REFERENCE_MANIFEST_SHA256") {
        assert_eq!(want, REFERENCE);
    }
}
fn emit(id: &str, cases: usize, values: usize, negative: usize, max: f64) {
    emit_relative(id, cases, values, negative, max, 0.0);
}
fn emit_relative(id: &str, cases: usize, values: usize, negative: usize, max: f64, relative: f64) {
    reference();
    assert!(cases > 0 && max.is_finite() && max >= 0.0 && relative.is_finite() && relative >= 0.0);
    println!(
        "F6E_PROJECTION_TEST {}",
        serde_json::json!({"schema":1,"test_id":format!("projection::tests::{id}"),"source_manifest_sha256":std::env::var("F6E_SOURCE").unwrap_or_else(|_|"local-unreceipted".into()),"reference_manifest_sha256":REFERENCE,"model_sha256":TINY_SHA,"expected_cases":cases,"executed_cases":cases,"expected_values":values,"compared_values":values,"max_abs_error":max,"max_rel_error":relative,"relative_error_scale":"1+abs(reference)","negative_controls_expected":negative,"negative_controls_rejected":negative,"status":"passed"})
    );
}
fn number(s: &str) -> f64 {
    s.parse().unwrap()
}
fn index(s: &str) -> usize {
    s.parse().unwrap()
}
fn component(s: &str) -> Component {
    Component::parse(s).unwrap()
}
fn axis(h: usize, layer: u32, component: Component, coef: f64) -> Site {
    let mut v = vec![0.0; h];
    v[usize::from(h > 1)] = 1.0;
    Site {
        layer,
        component,
        coef,
        direction: v.into(),
    }
}
fn empty() -> InterventionSpec {
    InterventionSpec::new(32, 3)
}
fn request(path: PathBuf, backend: crate::BackendKind) -> crate::LoadRequest {
    crate::LoadRequest {
        path,
        context_length: 768,
        gpu_layers: Some(if backend == crate::BackendKind::Cpu {
            0
        } else {
            999
        }),
        backend,
        mmap: true,
        projector: None,
    }
}
fn tiny() -> LoadedModel {
    tiny_backend(crate::BackendKind::Cpu)
}
fn tiny_backend(backend: crate::BackendKind) -> LoadedModel {
    assert_eq!(
        digest(&root().join("tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf")),
        TINY_SHA
    );
    crate::engine::load_for_live_feasibility(
        request(
            root().join("tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf"),
            backend,
        ),
        Some(512),
        Some(128),
        true,
    )
    .unwrap()
}
fn arithmetic_reference() {
    reference();
    let cases = csv("arithmetic-cases.csv");
    let inputs = csv("arithmetic-inputs.csv");
    let outputs = csv("arithmetic-expected.csv");
    let mut count = 0;
    let mut max = 0.0f64;
    for case in &cases {
        let name = &case[0];
        let h = index(&case[1]);
        let coef = number(&case[2]);
        let rows: Vec<_> = inputs.iter().filter(|r| &r[0] == name).collect();
        assert_eq!(rows.len(), h);
        let mut row: Vec<f32> = rows.iter().map(|r| number(&r[2]) as f32).collect();
        let direction: Arc<[f64]> = rows.iter().map(|r| number(&r[3])).collect();
        validate_site(
            &Site {
                layer: 0,
                component: Component::MlpOut,
                coef,
                direction: direction.clone(),
            },
            h,
            1,
            "llama",
        )
        .unwrap();
        let dot = project(&mut row, &direction, coef).unwrap();
        assert!((dot - number(&case[3])).abs() <= 1e-12 * (1.0 + number(&case[3]).abs()));
        for r in outputs.iter().filter(|r| &r[0] == name) {
            let actual = row[index(&r[1]) - 1];
            let want = number(&r[3]);
            let delta = (f64::from(actual) - want).abs();
            max = max.max(delta);
            assert!(delta <= 2e-6 * (1.0 + want.abs()));
            let bytes: Vec<u8> = (0..r[4].len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&r[4][i..i + 2], 16).unwrap())
                .collect();
            assert_eq!(actual.to_le_bytes().as_slice(), bytes.as_slice());
            count += 1;
        }
    }
    assert_eq!(cases.len(), 13);
    assert_eq!(count, 52);
    emit(
        "projection_row_matches_independent_reference",
        13,
        count,
        0,
        max,
    );
}
fn boundary_reference() {
    let rows = csv("arithmetic-refusals.csv");
    let mut rejected = 0;
    for r in &rows {
        let coef = number(&r[2]);
        let mut row: Vec<f32> = r[3].split(';').map(|x| number(x) as f32).collect();
        let d: Arc<[f64]> = r[4].split(';').map(number).collect();
        let site = Site {
            layer: 0,
            component: Component::MlpOut,
            coef,
            direction: d,
        };
        let bad = validate_site(&site, row.len(), 1, "llama").is_err()
            || project(&mut row, &site.direction, coef).is_err();
        assert!(bad, "{}", r[0]);
        rejected += 1;
    }
    let above = f64::from_bits((f32::MAX as f64).to_bits() + 1);
    assert!(validate_site(&axis(4, 0, Component::MlpOut, above), 4, 1, "llama").is_err());
    rejected += 1;
    assert!(validate_site(&axis(4, 0, Component::Residual, 1.0), 4, 1, "llama").is_err());
    rejected += 1;
    assert!(validate_site(&axis(4, 0, Component::AttnOut, 1.0), 4, 1, "qwen2").is_err());
    rejected += 1;
    assert!(estimate(0, 0).is_err());
    assert!(estimate(MAX_WIDTH + 1, 0).is_err());
    assert!(estimate(32, 32).is_err());
    rejected += 3;
    assert_eq!(rows.len(), 11);
    emit(
        "projection_boundary_rejects_invalid_inputs",
        rejected,
        0,
        rejected,
        0.0,
    );
}
fn capacity_reference() {
    let _guard = crate::NativeGuard::try_acquire("projection capacity").unwrap();
    let e = estimate(MAX_WIDTH, 31).unwrap();
    let arc = 2 * size_of::<usize>();
    assert_eq!(e.direction_bytes, 32 * (8 * MAX_WIDTH + arc));
    assert_eq!(
        e.plan_bytes,
        2 * (arc + size_of::<Plan>()) + 63 * size_of::<Site>()
    );
    assert_eq!(
        e.total,
        e.direction_bytes + e.plan_bytes + e.runtime_bytes + e.probe_bytes + e.frame_bytes
    );
    assert!(e.total < 64 * 1024 * 1024);
    let row = exact_f32(MAX_WIDTH).unwrap();
    assert_eq!(row.len() * size_of::<f32>(), 262144);
    let site = axis(MAX_WIDTH, 0, Component::MlpOut, 1.0);
    let clone = site.clone();
    assert!(Arc::ptr_eq(&site.direction, &clone.direction));
    assert_eq!(Arc::strong_count(&site.direction), 2);
    assert_eq!(
        unsafe { ffi::relm_projection_info_size() },
        size_of::<ffi::ProjectionInfo>()
    );
    let access_frame = unsafe { ffi::relm_projection_access_frame_size() };
    assert!(access_frame > 0);
    assert!(e.frame_bytes >= 2 * size_of::<ffi::ProjectionInfo>() + access_frame);
    let base = tiny();
    let projected = base
        .derive_projection(
            vec![axis(32, 0, Component::MlpOut, 1.0)],
            &empty(),
            Fault::None,
        )
        .unwrap();
    assert_eq!(projected.n_batch(), 512);
    assert_eq!(unsafe { ffi::llama_n_ubatch(projected.ctx_ptr()) }, 128);
    let duplicate = projected.derive_projection(
        vec![axis(32, 0, Component::MlpOut, 1.0)],
        &empty(),
        Fault::None,
    );
    assert!(duplicate.is_err());
    let baseline = base.prompt_last_logits(&[1, 7], 48).unwrap();
    assert_eq!(baseline, base.prompt_last_logits(&[1, 7], 48).unwrap());
    println!(
        "F6E_PROJECTION_LEDGER {}",
        serde_json::json!({"width":MAX_WIDTH,"sites":32,"direction_bytes":e.direction_bytes,"plan_bytes":e.plan_bytes,"runtime_bytes":e.runtime_bytes,"probe_bytes":e.probe_bytes,"frame_bytes":e.frame_bytes,"total":e.total,"runtime_size":size_of::<Runtime>(),"site_size":size_of::<Site>(),"probe_size":size_of::<Probe>(),"projection_info_size":size_of::<ffi::ProjectionInfo>(),"buffer_info_size":size_of::<ffi::ProjectionBufferInfo>(),"proof_size":size_of::<Proof>(),"proof_slots":MAX_SITES,"access_frame_bytes":access_frame})
    );
    emit(
        "projection_capacity_ledger_matches_owned_buffers",
        8,
        0,
        1,
        0.0,
    );
}
fn classifier_reference() {
    let bits = unsafe { ffi::relm_projection_classifier_controls() };
    assert_eq!(bits, 4095, "classifier control mask");
    emit(
        "projection_classifier_accepts_only_declared_dense_sites",
        12,
        0,
        8,
        0.0,
    );
}
fn probe_controls() {
    let base = tiny();
    let original = base.prompt_last_logits(&[1, 7], 48).unwrap();
    let mut count = 0;
    for component in [Component::MlpOut, Component::AttnOut] {
        for fault in [Fault::Missing, Fault::NoWrite, Fault::WrongSite] {
            assert!(base
                .derive_projection(vec![axis(32, 0, component, 1.0)], &empty(), fault)
                .is_err());
            count += 1;
        }
    }
    assert_eq!(original, base.prompt_last_logits(&[1, 7], 48).unwrap());
    emit(
        "projection_probe_rejects_missing_noop_and_wrong_site",
        count,
        0,
        count,
        0.0,
    );
}
fn sites_for(name: &str) -> Vec<Site> {
    let rows = csv("forward-projections.csv");
    let selected: Vec<_> = rows.iter().filter(|r| r[0] == name).collect();
    let count = selected.len() / 32;
    let mut out = Vec::with_capacity(count);
    for chunk in selected.chunks(32) {
        assert_eq!(chunk.len(), 32);
        out.push(Site {
            layer: (index(&chunk[0][1]) - 1) as u32,
            component: component(&chunk[0][2]),
            coef: number(&chunk[0][3]),
            direction: chunk.iter().map(|r| number(&r[5])).collect(),
        });
    }
    out
}
fn residual(composition: bool) -> InterventionSpec {
    let mut s = empty();
    if composition {
        s.add_steer(
            1,
            &(0..32)
                .map(|j| if j % 2 == 0 { 1.5 } else { -1.5 })
                .collect::<Vec<_>>(),
        );
        s.add_ablation(1, &[2], 0.25);
    }
    s
}
fn close(actual: f64, want: f64, max: &mut (f64, f64)) {
    let d = (actual - want).abs();
    assert!(
        d.is_finite() && d <= 0.01,
        "native {actual}, reference {want}, delta {d}"
    );
    max.0 = max.0.max(d);
    max.1 = max.1.max(d / (1.0 + want.abs()));
}
fn forward_reference(micro_only: bool) {
    let _ = forward_reference_backend(micro_only, crate::BackendKind::Cpu, true);
}

fn phase_pruned_logits(model: &LoadedModel, ids: &[i32], prefill: usize) -> Vec<f32> {
    assert!(prefill > 0 && prefill < ids.len());
    drop(model.prompt_last_logits(&ids[..prefill], 48).unwrap());
    for (position, &token) in ids.iter().enumerate().skip(prefill) {
        model
            .decode_projection_tokens(&[token], position as i32, true)
            .unwrap();
    }
    model.logits_ith(0, 48).unwrap()
}

fn fixed_history_logits(model: &LoadedModel, position: usize) -> Vec<f32> {
    // Same fixed token follows each compared schedule, without clearing its KV.
    model
        .decode_projection_tokens(&[1], position as i32, true)
        .unwrap();
    model.logits_ith(0, 48).unwrap()
}

fn same_logit_bits(a: &[f32], b: &[f32]) -> bool {
    a.len() == 48
        && b.len() == 48
        && a.iter()
            .zip(b)
            .all(|(a, b)| a.is_finite() && b.is_finite() && a.to_bits() == b.to_bits())
}

fn pruning_reference(
    model: &LoadedModel,
    name: &str,
    ids: &[i32],
    prefill: usize,
    reference_logits: &[f64],
) -> (serde_json::Value, (f64, f64)) {
    assert_eq!(reference_logits.len(), 48);
    let n_batch = model.n_batch() as usize;
    assert!(n_batch > 0 && ids.len() <= 514);
    let mut phase_schedule: Vec<_> = ids[..prefill].chunks(n_batch).map(<[i32]>::len).collect();
    phase_schedule.extend(std::iter::repeat_n(1, ids.len() - prefill));
    let grouped_schedule: Vec<_> = ids.chunks(n_batch).map(<[i32]>::len).collect();

    // Independent-reference comparisons honor the fixture's prefill/decode
    // boundary, including 513+1 for the long case and 3+2 for the short cases.
    let aligned_logits = phase_pruned_logits(model, ids, prefill);
    let aligned_history_logits = fixed_history_logits(model, ids.len());
    let aligned_replay_logits = phase_pruned_logits(model, ids, prefill);
    let aligned_replay_history_logits = fixed_history_logits(model, ids.len());

    // Retain the real all-prompt path, comparing output policy while fixing its
    // native batch schedule. Copy only the final48 logits, not every output.
    model.clear_memory();
    for (chunk, tokens) in ids.chunks(n_batch).enumerate() {
        model
            .decode_projection_tokens(tokens, (chunk * n_batch) as i32, false)
            .unwrap();
    }
    let grouped_all_logits = model
        .logits_ith((*grouped_schedule.last().unwrap() - 1) as i32, 48)
        .unwrap();
    let grouped_all_history_logits = fixed_history_logits(model, ids.len());
    let grouped_last_logits = model.prompt_last_logits(ids, 48).unwrap();
    let grouped_last_history_logits = fixed_history_logits(model, ids.len());
    let grouped_repeat_logits = model.prompt_last_logits(ids, 48).unwrap();
    let grouped_repeat_history_logits = fixed_history_logits(model, ids.len());

    let independent_abs_errors: Vec<_> = aligned_logits
        .iter()
        .zip(reference_logits)
        .map(|(&a, &b)| (f64::from(a) - b).abs())
        .collect();
    let fixed_schedule_final_abs_errors: Vec<_> = grouped_all_logits
        .iter()
        .zip(&grouped_last_logits)
        .map(|(&a, &b)| (f64::from(a) - f64::from(b)).abs())
        .collect();
    let fixed_schedule_history_abs_errors: Vec<_> = grouped_all_history_logits
        .iter()
        .zip(&grouped_last_history_logits)
        .map(|(&a, &b)| (f64::from(a) - f64::from(b)).abs())
        .collect();
    let cross_errors: Vec<_> = grouped_last_logits
        .iter()
        .zip(reference_logits)
        .map(|(&a, &b)| (f64::from(a) - b).abs())
        .collect();
    let cross_outliers: Vec<_> = cross_errors
        .iter()
        .enumerate()
        .filter_map(|(token, &error)| (error > 0.01).then_some(token))
        .collect();
    let pruning_bitwise_equal = same_logit_bits(&grouped_all_logits, &grouped_last_logits);
    let history_bitwise_equal =
        same_logit_bits(&grouped_all_history_logits, &grouped_last_history_logits);
    let aligned_replay_bitwise_equal = same_logit_bits(&aligned_logits, &aligned_replay_logits);
    let aligned_history_replay_bitwise_equal =
        same_logit_bits(&aligned_history_logits, &aligned_replay_history_logits);
    let grouped_replay_bitwise_equal =
        same_logit_bits(&grouped_last_logits, &grouped_repeat_logits);
    let grouped_history_replay_bitwise_equal =
        same_logit_bits(&grouped_last_history_logits, &grouped_repeat_history_logits);
    let receipt = serde_json::json!({"case":name,"prefill_tokens":prefill,"decode_tokens":ids.len()-prefill,"total_tokens":ids.len(),"n_batch":n_batch,"n_ubatch":unsafe{ffi::llama_n_ubatch(model.ctx_ptr())},"phase_schedule":phase_schedule,"grouped_schedule":grouped_schedule,"reference_logits":reference_logits,"aligned_logits":aligned_logits,"aligned_replay_logits":aligned_replay_logits,"aligned_history_logits":aligned_history_logits,"aligned_replay_history_logits":aligned_replay_history_logits,"grouped_all_logits":grouped_all_logits,"grouped_last_logits":grouped_last_logits,"grouped_repeat_logits":grouped_repeat_logits,"grouped_all_history_logits":grouped_all_history_logits,"grouped_last_history_logits":grouped_last_history_logits,"grouped_repeat_history_logits":grouped_repeat_history_logits,"independent_abs_errors":independent_abs_errors,"fixed_schedule_final_abs_errors":fixed_schedule_final_abs_errors,"fixed_schedule_history_abs_errors":fixed_schedule_history_abs_errors,"pruning_bitwise_equal":pruning_bitwise_equal,"history_bitwise_equal":history_bitwise_equal,"aligned_replay_bitwise_equal":aligned_replay_bitwise_equal,"aligned_history_replay_bitwise_equal":aligned_history_replay_bitwise_equal,"grouped_replay_bitwise_equal":grouped_replay_bitwise_equal,"grouped_history_replay_bitwise_equal":grouped_history_replay_bitwise_equal,"continuation_token_native":1,"continuation_position_native":ids.len(),"cross_schedule_reference":{"status":"unaccepted_cross_schedule_observation","abs_errors":cross_errors,"outlier_native_tokens":cross_outliers,"max_abs_error":cross_errors.iter().copied().fold(0.0f64,f64::max)}});
    // Keep raw failed observations available even if a controlled assertion
    // below fails. Cross-schedule reference errors are observations, not a gate.
    println!("F6E_PROJECTION_PRUNING_CASE {receipt}");
    let mut independent_max = (0.0, 0.0);
    for (&actual, &expected) in aligned_logits.iter().zip(reference_logits) {
        close(f64::from(actual), expected, &mut independent_max);
    }
    let mut policy_max = (0.0, 0.0);
    for (&actual, &expected) in grouped_last_logits.iter().zip(&grouped_all_logits) {
        close(f64::from(actual), f64::from(expected), &mut policy_max);
    }
    for (&actual, &expected) in grouped_last_history_logits
        .iter()
        .zip(&grouped_all_history_logits)
    {
        close(f64::from(actual), f64::from(expected), &mut policy_max);
    }
    assert!(pruning_bitwise_equal && history_bitwise_equal);
    assert!(aligned_replay_bitwise_equal && aligned_history_replay_bitwise_equal);
    assert!(grouped_replay_bitwise_equal && grouped_history_replay_bitwise_equal);
    (receipt, independent_max)
}

fn forward_reference_backend(
    micro_only: bool,
    backend: crate::BackendKind,
    marker: bool,
) -> serde_json::Value {
    reference();
    let _guard = crate::NativeGuard::try_acquire("projection golden").unwrap();
    // The first backend acquisition installs the process-wide quiet logger.
    // Complete it before installing this test's actual backend receipt logger.
    let _ = crate::available_backends();
    let receipt_log = crate::live_capture::tests::start_load_log();
    let base = tiny_backend(backend);
    let backend_receipt = crate::live_capture::tests::backend_receipt(&base, backend);
    drop(receipt_log);
    let cases = csv("forward-cases.csv");
    let tokens = csv("forward-tokens.csv");
    let activations = csv("forward-activations.csv");
    let sites = csv("forward-sites.csv");
    let logits = csv("forward-logits.csv");
    let witnesses = csv("forward-row-witnesses.csv");
    let mut values = 0;
    let mut executed = 0;
    let mut maximum = (0.0f64, 0.0f64);
    let mut same_row_values = 0;
    let mut same_row_maximum = (0.0f64, 0.0f64);
    let mut pruning_cases = Vec::new();
    for case in &cases {
        let name = &case[0];
        if micro_only
            && !["long_prefill", "mlp_out_last_c1", "attn_out_last_c1"].contains(&name.as_str())
        {
            continue;
        }
        let mut configured = sites_for(name);
        let dummy = configured.is_empty();
        if dummy {
            configured = vec![axis(32, 0, Component::MlpOut, 0.0)];
        }
        let spec = residual(case[5] == "1");
        let model = base
            .derive_projection(configured, &spec, Fault::None)
            .unwrap();
        let rows: Vec<_> = tokens.iter().filter(|r| &r[0] == name).collect();
        let ids: Vec<i32> = rows.iter().map(|r| r[2].parse().unwrap()).collect();
        let positions: Vec<usize> = activations
            .iter()
            .filter(|r| &r[0] == name && r[2] == "1" && r[3] == "attn_out" && r[4] == "1")
            .map(|r| index(&r[1]) - 1)
            .collect();
        model.projection_audit(&positions);
        model.projection_reset_stats();
        model.clear_memory();
        let entries = vec![crate::LiveSteer {
            intervention: 0,
            layer: 1,
            coef: 1.0,
            direction: (0..32)
                .map(|i| if i % 2 == 0 { 1.5 } else { -1.5 })
                .collect(),
        }];
        let mut live = if case[6] == "1" {
            Some(crate::live_steering::LiveSteering::prepare(&model, &entries).unwrap())
        } else {
            None
        };
        let mut start = 0;
        let prefill = index(&case[1]);
        while start < ids.len() {
            let end = if start < prefill {
                (start + 512).min(prefill)
            } else {
                start + 1
            };
            if let Some(live) = live.as_mut() {
                let coef = number(&rows[start][4]);
                live.apply_reply(
                    vec![crate::LiveCoefficient {
                        intervention: 0,
                        coef,
                    }],
                    start,
                    start as u32,
                )
                .unwrap();
            }
            model
                .decode_projection_tokens(&ids[start..end], start as i32, false)
                .unwrap();
            for position in start..end {
                if !positions.contains(&position) {
                    continue;
                }
                let native = model.logits_ith((position - start) as i32, 48).unwrap();
                for r in logits
                    .iter()
                    .filter(|r| &r[0] == name && index(&r[1]) == position + 1)
                {
                    close(f64::from(native[index(&r[2])]), number(&r[3]), &mut maximum);
                    values += 1;
                }
            }
            start = end;
        }
        if let Some(mut live) = live {
            live.restore().unwrap();
        }
        let (observed, row_witnesses) = model.projection_take_audit();
        if !dummy {
            let plan = model.projection().lock().as_ref().unwrap().plan.clone();
            for before in observed.iter().filter(|row| row.before) {
                let site = plan
                    .sites
                    .iter()
                    .find(|s| s.layer == before.layer && s.component == before.component)
                    .unwrap();
                let mut matching = observed.iter().filter(|after| {
                    !after.before
                        && after.position == before.position
                        && after.layer == before.layer
                        && after.component == before.component
                });
                let after = matching.next().unwrap();
                assert!(matching.next().is_none());
                assert_eq!(before.values.len(), site.direction.len());
                assert_eq!(after.values.len(), site.direction.len());
                // Independent scalar equation on the actual observed pre-row.
                // The post-row is read back from tensor storage by the observer.
                let mut dot = 0.0f64;
                for (&input, &direction) in before.values.iter().zip(site.direction.iter()) {
                    dot += f64::from(input) * direction;
                }
                assert!(dot.is_finite());
                for ((&input, &actual), &direction) in before
                    .values
                    .iter()
                    .zip(after.values.iter())
                    .zip(site.direction.iter())
                {
                    let updated = if site.coef == 0.0 {
                        f64::from(input)
                    } else {
                        f64::from(input) - (site.coef * direction) * dot
                    };
                    assert!(updated.is_finite() && updated.abs() <= f64::from(f32::MAX));
                    let expected = f64::from(updated as f32);
                    let delta = (f64::from(actual) - expected).abs();
                    let scaled = delta / (1.0 + expected.abs());
                    assert!(
                        scaled.is_finite() && scaled <= 2e-6,
                        "{name}: same-row delta {delta}"
                    );
                    same_row_maximum.0 = same_row_maximum.0.max(delta);
                    same_row_maximum.1 = same_row_maximum.1.max(scaled);
                    same_row_values += 1;
                }
            }
        }
        for r in activations.iter().filter(|r| &r[0] == name) {
            let found: Vec<_> = observed
                .iter()
                .filter(|o| {
                    !o.before
                        && o.position + 1 == index(&r[1])
                        && o.layer as usize + 1 == index(&r[2])
                        && o.component == component(&r[3])
                })
                .collect();
            assert_eq!(found.len(), 1, "{name}: missing/duplicate activation {r:?}");
            close(
                f64::from(found[0].values[index(&r[4]) - 1]),
                number(&r[5]),
                &mut maximum,
            );
            values += 1;
        }
        for r in sites.iter().filter(|r| &r[0] == name) {
            for (before, column) in [(true, 5), (false, 6)] {
                let found: Vec<_> = observed
                    .iter()
                    .filter(|o| {
                        o.before == before
                            && o.position + 1 == index(&r[1])
                            && o.layer as usize + 1 == index(&r[2])
                            && o.component == component(&r[3])
                    })
                    .collect();
                assert_eq!(found.len(), 1);
                close(
                    f64::from(found[0].values[index(&r[4]) - 1]),
                    number(&r[column]),
                    &mut maximum,
                );
                values += 1;
            }
        }
        if !dummy {
            let expected: Vec<_> = witnesses.iter().filter(|r| &r[0] == name).collect();
            assert_eq!(expected.len(), row_witnesses.len());
            for r in expected {
                let w = row_witnesses
                    .iter()
                    .find(|w| {
                        w.position + 1 == index(&r[1])
                            && w.layer as usize + 1 == index(&r[2])
                            && w.component == component(&r[3])
                    })
                    .unwrap();
                close(w.dot, number(&r[4]), &mut maximum);
                assert_eq!(w.write, r[5] == "1");
                close(w.before_norm, number(&r[6]), &mut maximum);
                close(w.after_norm, number(&r[7]), &mut maximum);
                values += 3;
            }
        }
        if micro_only {
            let expected = logits
                .iter()
                .filter(|r| &r[0] == name && index(&r[1]) == ids.len())
                .map(|r| number(&r[3]))
                .collect::<Vec<_>>();
            let (receipt, independent_max) =
                pruning_reference(&model, name, &ids, prefill, &expected);
            maximum.0 = maximum.0.max(independent_max.0);
            maximum.1 = maximum.1.max(independent_max.1);
            values += 48;
            pruning_cases.push(receipt);
        }
        executed += 1;
    }
    if micro_only {
        assert_eq!(executed, 3);
        assert_eq!(values, 10_042);
        assert_eq!(same_row_values, 704);
        assert_eq!(pruning_cases.len(), 3);
        println!(
            "F6E_PROJECTION_PRUNING {}",
            serde_json::json!({"schema":1,"status":"passed","source_manifest_sha256":std::env::var("F6E_SOURCE").unwrap_or_else(|_|"local-unreceipted".into()),"reference_manifest_sha256":REFERENCE,"model_sha256":TINY_SHA,"test_id":"projection::tests::projection_microbatches_pruning_and_graph_reuse","expected_cases":3,"executed_cases":pruning_cases.len(),"counts":{"independent_values":144,"fixed_schedule_final_values":144,"fixed_schedule_history_values":144,"aligned_replay_final_values":144,"aligned_replay_history_values":144,"grouped_replay_final_values":144,"grouped_replay_history_values":144,"cross_schedule_observation_values":144},"cases":pruning_cases,"limitation":"Independent0.01 acceptance follows the declared prefill/decode phases. Grouped all-prompt versus that reference is an unaccepted cross-schedule observation; no batching-invariant accuracy or kernel-cause claim."})
        );
    } else {
        assert_eq!(executed, 15);
        assert_eq!(values, 34_748);
        assert_eq!(same_row_values, 2944);
    }
    let same_row = serde_json::json!({"schema":1,"status":"passed","source_manifest_sha256":std::env::var("F6E_SOURCE").unwrap_or_else(|_|"local-unreceipted".into()),"reference_manifest_sha256":REFERENCE,"test_id":if micro_only {"projection::tests::projection_microbatches_pruning_and_graph_reuse"} else {"projection::tests::projection_forward_matches_independent_reference"},"requested_backend":if backend == crate::BackendKind::Cpu {"cpu"} else {"metal"},"expected_values":if micro_only {704} else {2944},"compared_values":same_row_values,"max_abs_error":same_row_maximum.0,"max_scaled_error":same_row_maximum.1,"scaled_error_definition":"abs(actual-expected_f32)/(1+abs(expected_f32))","scaled_error_limit":2e-6});
    println!("F6E_PROJECTION_SAME_ROW {same_row}");
    let result = serde_json::json!({"status":"passed","model_sha256":TINY_SHA,"expected_cases":executed,"executed_cases":executed,"expected_values":values,"compared_values":values,"max_abs_error":maximum.0,"max_rel_error":maximum.1,"same_row":same_row,"backend":backend_receipt});
    if marker {
        emit_relative(
            if micro_only {
                "projection_microbatches_pruning_and_graph_reuse"
            } else {
                "projection_forward_matches_independent_reference"
            },
            executed,
            values,
            0,
            maximum.0,
            maximum.1,
        );
    } else {
        println!("F6E_PROJECTION_METAL_FORWARD {result}");
    }
    result
}
fn composition_reference() {
    let _guard = crate::NativeGuard::try_acquire("projection live composition").unwrap();
    let base = tiny();
    let model = base
        .derive_projection(
            vec![axis(32, 1, Component::MlpOut, 1.0)],
            &residual(true),
            Fault::None,
        )
        .unwrap();
    let parameters = crate::GenerateParams {
        max_tokens: 3,
        temperature: 0.0,
        top_p: 1.0,
        seed: 17,
        stop: vec![],
    };
    let ordinary = model.generate(&[1, 7], &parameters).unwrap();
    let mut count = 0;
    let observed = model
        .generate_observed(
            &[1, 7],
            &parameters,
            &[1],
            &[Component::MlpOut, Component::Residual],
            &mut |state, _| {
                assert_eq!(state.rows.len(), 2);
                let mlp = state
                    .rows
                    .iter()
                    .find(|r| r.component == Component::MlpOut)
                    .unwrap();
                assert_eq!(mlp.values[1], 0.0);
                let residual = state
                    .rows
                    .iter()
                    .find(|r| r.component == Component::Residual)
                    .unwrap();
                assert_eq!(residual.values[2], 0.25);
                count += 1;
                Ok(())
            },
        )
        .unwrap();
    assert_eq!(ordinary, observed);
    assert_eq!(count, 3);
    let derived = model.derive_with_interventions(&residual(true)).unwrap();
    assert_eq!(ordinary, derived.generate(&[1, 7], &parameters).unwrap());
    let entries = vec![crate::LiveSteer {
        intervention: 0,
        layer: 1,
        coef: 1.0,
        direction: (0..32)
            .map(|i| if i % 2 == 0 { 1.5 } else { -1.5 })
            .collect(),
    }];
    {
        let mut live = crate::live_steering::LiveSteering::prepare(&model, &entries).unwrap();
        assert!(live
            .apply_reply(
                vec![crate::LiveCoefficient {
                    intervention: 1,
                    coef: 0.0
                }],
                1,
                2
            )
            .is_err());
        live.apply_reply(
            vec![crate::LiveCoefficient {
                intervention: 0,
                coef: 0.0,
            }],
            1,
            2,
        )
        .unwrap();
        live.restore().unwrap();
    }
    assert_eq!(ordinary, model.generate(&[1, 7], &parameters).unwrap());
    emit(
        "projection_capture_and_static_additive_composition",
        6,
        0,
        1,
        0.0,
    );
}
fn ownership_controls() {
    let _guard = crate::NativeGuard::try_acquire("projection ownership").unwrap();
    let base = tiny();
    let original = base.prompt_last_logits(&[1, 7], 48).unwrap();
    let mut rejected = 0;
    for fault in [Fault::AfterRow, Fault::Cancel, Fault::Panic] {
        let model = base
            .derive_projection(
                vec![axis(32, 0, Component::MlpOut, 1.0)],
                &empty(),
                Fault::None,
            )
            .unwrap();
        model.projection_fault(fault);
        assert!(model.prompt_last_logits(&[1, 7], 48).is_err());
        assert!(model.projection().failed());
        assert!(model.steering_restore_failed.get());
        assert!(model.prompt_last_logits(&[1, 7], 48).is_err());
        drop(model);
        assert_eq!(original, base.prompt_last_logits(&[1, 7], 48).unwrap());
        rejected += 1;
    }
    emit(
        "projection_cancel_fault_and_owner_cleanup",
        rejected,
        0,
        rejected,
        0.0,
    );
}
fn benchmark() {
    reference();
    if cfg!(debug_assertions) {
        panic!("release-only projection performance acceptance");
    }
    let exe = std::env::current_exe().unwrap();
    assert_eq!(
        exe.parent().unwrap().parent().unwrap().file_name().unwrap(),
        "release"
    );
    let _guard = crate::NativeGuard::try_acquire("projection release benchmark").unwrap();
    let path = PathBuf::from(std::env::var("F6E_MODEL").expect("F6E_MODEL"));
    let model_hash = std::env::var("F6E_MODEL_SHA256").expect("F6E_MODEL_SHA256");
    assert_eq!(digest(&path), model_hash);
    let source = std::env::var("F6E_SOURCE").expect("F6E_SOURCE");
    let name = std::env::var("F6E_BACKEND").expect("F6E_BACKEND");
    let backend = crate::BackendKind::parse(&name).unwrap();
    assert!(matches!(
        backend,
        crate::BackendKind::Cpu | crate::BackendKind::Metal
    ));
    let tiny_forward = if backend == crate::BackendKind::Metal {
        Some(forward_reference_backend(false, backend, false))
    } else {
        None
    };
    let _ = crate::available_backends();
    let log = crate::live_capture::tests::start_load_log();
    let control = crate::engine::load_for_live_feasibility(
        request(path.clone(), backend),
        Some(512),
        Some(128),
        false,
    )
    .unwrap();
    let control_receipt = crate::live_capture::tests::backend_receipt(&control, backend);
    let dormant = crate::engine::load_for_live_feasibility(
        request(path.clone(), backend),
        Some(512),
        Some(128),
        true,
    )
    .unwrap();
    let hooked_receipt = crate::live_capture::tests::backend_receipt(&dormant, backend);
    drop(log);
    assert_eq!(dormant.architecture(), "qwen2", "cached Qwen2 MLP gate");
    let h = dormant.hidden_size() as usize;
    let depth = dormant.num_layers() as usize;
    assert!(depth >= 3);
    let empty = InterventionSpec::new(h, depth);
    let layer = (depth / 2) as u32;
    let zero = dormant
        .derive_projection(
            vec![axis(h, layer, Component::MlpOut, 0.0)],
            &empty,
            Fault::None,
        )
        .unwrap();
    let one = dormant
        .derive_projection(
            vec![axis(h, layer, Component::MlpOut, 1.0)],
            &empty,
            Fault::None,
        )
        .unwrap();
    let multi = dormant
        .derive_projection(
            vec![
                axis(h, 0, Component::MlpOut, 1.0),
                axis(h, layer, Component::MlpOut, 1.0),
                axis(h, (depth - 1) as u32, Component::MlpOut, 1.0),
            ],
            &empty,
            Fault::None,
        )
        .unwrap();
    let (text,add,parse)=dormant.resolve_prompt_text("Write a detailed explanation of how photosynthesis works, including the role of light, water, carbon dioxide and chlorophyll. Use numbered steps and give examples.",true).unwrap();
    let ids = dormant.tokenize(&text, add, parse).unwrap();
    let params = crate::GenerateParams {
        max_tokens: 128,
        temperature: 0.8,
        top_p: 0.95,
        seed: 42,
        stop: vec![],
    };
    let models = [control, dormant, zero, one, multi];
    let names = [
        "callback_free",
        "dormant",
        "zero",
        "active_one",
        "active_multi",
    ];
    let orders = [[0, 1, 2, 3, 4], [4, 2, 0, 3, 1], [3, 1, 4, 2, 0]];
    let mut samples = Vec::new();
    let mut times: [Vec<f64>; 5] = std::array::from_fn(|_| Vec::with_capacity(3));
    let mut reference_generation = None;
    for round in 0..4 {
        let order = if round == 0 {
            [0, 1, 2, 3, 4]
        } else {
            orders[round - 1]
        };
        for mode in order {
            let model = &models[mode];
            model.projection_reset_stats();
            model.projection().clear_timings();
            let started = Instant::now();
            let result = model.generate(&ids, &params).unwrap();
            let elapsed = started.elapsed().as_secs_f64();
            let timing = model.projection().timings();
            let stats = model.projection_stats();
            let sample = serde_json::json!({"round":round,"warmup":round==0,"mode":names[mode],"prefill_seconds":timing.0,"decode_seconds":timing.1,"elapsed_seconds":elapsed,"decoded_tokens":result.tokens.len(),"site_rows":stats.rows,"read_bytes":stats.read_bytes,"write_bytes":stats.write_bytes,"barriers":stats.barriers});
            println!("F6E_PROJECTION_SAMPLE {sample}");
            samples.push(sample);
            assert_eq!(
                result.tokens.len(),
                128,
                "incomparable early termination; retain this failed sample"
            );
            if mode == 0 {
                reference_generation = Some(result.clone());
            } else if mode <= 2 {
                assert_eq!(
                    Some(&result),
                    reference_generation.as_ref(),
                    "callback/dormant/zero exact parity"
                );
            }
            if mode == 2 {
                assert_eq!(stats.write_bytes, 0);
                assert_eq!(stats.read_bytes, 0);
                assert_eq!(stats.barriers, 0);
            }
            if mode >= 3 {
                assert!(
                    stats.rows > 0
                        && stats.write_bytes > 0
                        && stats.read_bytes >= stats.write_bytes
                        && stats.barriers > 0
                );
            }
            if round > 0 {
                times[mode].push(elapsed);
            }
        }
    }
    let medians: Vec<f64> = times
        .iter_mut()
        .map(|s| {
            s.sort_by(f64::total_cmp);
            s[1]
        })
        .collect();
    let ratio = medians[1] / medians[0];
    println!(
        "F6E_PROJECTION_TIMING {}",
        serde_json::json!({"medians":medians,"dormant_ratio":ratio,"dormant_limit":1.05,"active_limit":null})
    );
    assert!(
        ratio <= 1.05,
        "dormant dispatcher exceeds the unchanged 5% gate"
    );
    // Positive marker is emitted only after all receipt/token/parity/gate checks.
    println!(
        "F6E_PROJECTION_BENCH {}",
        serde_json::json!({"schema":1,"status":"passed","source_manifest_sha256":source,"reference_manifest_sha256":REFERENCE,"model_sha256":model_hash,"model":path,"build_profile":"release","debug_assertions":cfg!(debug_assertions),"requested_backend":name,"resolved_backend":models[1].metadata().backend,"callback_free_backend":control_receipt,"hooked_backend":hooked_receipt,"tiny_forward":tiny_forward,"settings":{"n_batch":512,"n_ubatch":128,"context_length":768,"prompt_tokens":ids.len(),"max_tokens":128,"seed":42,"temperature":0.8,"top_p":0.95,"warmups_per_mode":1,"measured_rounds":3,"component":"mlp_out","single_layer_native":layer,"multi_layers_native":[0,layer,depth-1],"direction":"unit axis at native coordinate 1","coefficient":1.0},"samples":samples,"mode_order":names,"median_elapsed_seconds":medians,"dormant_ratio":ratio,"dormant_limit":1.05,"active_limit":null})
    );
}
