// Diagnostic only: no tolerance, golden, or runtime change. This ignored case
// separates the two factors changed by the retained native-07 failure.
struct DiagnosticOutput {
    id: String,
    logits: Vec<f32>,
    continuation: Vec<f32>,
}

fn diagnostic_delta(actual: &[f32], expected: &[f32]) -> serde_json::Value {
    assert_eq!(actual.len(), 48);
    assert_eq!(expected.len(), 48);
    let mut maximum = 0.0f64;
    let mut token = 0;
    let mut above = 0;
    for (i, (&a, &b)) in actual.iter().zip(expected).enumerate() {
        let delta = (f64::from(a) - f64::from(b)).abs();
        assert!(delta.is_finite());
        if delta > maximum {
            maximum = delta;
            token = i;
        }
        above += usize::from(delta > 0.01);
    }
    serde_json::json!({"compared_values":48,"max_abs_error":maximum,"max_error_token_native":token,"count_above_0_01":above,"bitwise_equal":actual.iter().zip(expected).all(|(a,b)|a.to_bits()==b.to_bits())})
}

fn diagnostic_compare(a: &DiagnosticOutput, b: &DiagnosticOutput) {
    println!(
        "F6E_PROJECTION_DIAGNOSTIC_PAIR {}",
        serde_json::json!({"left":a.id,"right":b.id,"final_logits":diagnostic_delta(&a.logits,&b.logits),"continuation_logits":diagnostic_delta(&a.continuation,&b.continuation)})
    );
}

fn diagnostic_run(
    model: &LoadedModel,
    mode: &str,
    run: &str,
    ids: &[i32],
    schedule: &[usize],
    last_only: bool,
    audit: bool,
) -> DiagnosticOutput {
    assert_eq!(ids.len(), 514);
    assert_eq!(schedule.iter().sum::<usize>(), 514);
    assert!(schedule.iter().all(|&n| n > 0 && n <= 512));
    model.clear_memory();
    model.projection_reset_stats();
    if audit {
        model.projection_audit(&[0, 127, 511, 512, 513, 514]);
    }
    let mut steps = Vec::with_capacity(schedule.len() + 1);
    let mut start = 0;
    for &n in schedule {
        model
            .decode_projection_tokens(&ids[start..start + n], start as i32, last_only)
            .unwrap();
        let stats = model.projection_stats();
        steps.push(serde_json::json!({"start_native":start,"tokens":n,"last_only":last_only,"cumulative_site_rows":stats.rows,"cumulative_read_bytes":stats.read_bytes,"cumulative_write_bytes":stats.write_bytes,"cumulative_barriers":stats.barriers}));
        start += n;
    }
    // Same slot rule as prompt_last_logits, independent of last-only/all-row.
    let logits = model
        .logits_ith((*schedule.last().unwrap() - 1) as i32, 48)
        .unwrap();
    // A common next token exposes any retained-history difference. No cache
    // reset, adapter update, or new context occurs between these two outputs.
    model.decode_projection_tokens(&[1], 514, true).unwrap();
    let continuation = model.logits_ith(0, 48).unwrap();
    let stats = model.projection_stats();
    steps.push(serde_json::json!({"start_native":514,"tokens":1,"last_only":true,"token_native":1,"cumulative_site_rows":stats.rows,"cumulative_read_bytes":stats.read_bytes,"cumulative_write_bytes":stats.write_bytes,"cumulative_barriers":stats.barriers}));
    let mut observed = Vec::new();
    let mut witnesses = Vec::new();
    let mut same_count = 0usize;
    let mut same_max = 0.0f64;
    let mut same_above = 0usize;
    let mut site_counts = [0usize; 2];
    let mut site_missing = [515usize; 2];
    let mut duplicates = 0usize;
    if audit {
        let (rows, raw_witnesses) = model.projection_take_audit();
        assert!(rows.len() <= 128 && raw_witnesses.len() <= 2048);
        let plan = model.projection().lock().as_ref().unwrap().plan.clone();
        assert_eq!(plan.sites.len(), 2);
        for before in rows.iter().filter(|r| r.before) {
            let site = plan
                .sites
                .iter()
                .find(|s| s.layer == before.layer && s.component == before.component)
                .unwrap();
            let after = rows
                .iter()
                .find(|r| {
                    !r.before
                        && r.position == before.position
                        && r.layer == before.layer
                        && r.component == before.component
                })
                .unwrap();
            assert_eq!(before.values.len(), 32);
            assert_eq!(after.values.len(), 32);
            let mut dot = 0.0f64;
            for (&value, &direction) in before.values.iter().zip(site.direction.iter()) {
                dot += f64::from(value) * direction;
            }
            for ((&value, &actual), &direction) in before
                .values
                .iter()
                .zip(after.values.iter())
                .zip(site.direction.iter())
            {
                let want = if site.coef == 0.0 {
                    value
                } else {
                    (f64::from(value) - (site.coef * direction) * dot) as f32
                };
                let scaled =
                    (f64::from(actual) - f64::from(want)).abs() / (1.0 + f64::from(want).abs());
                assert!(scaled.is_finite());
                same_count += 1;
                same_max = same_max.max(scaled);
                same_above += usize::from(scaled > 2e-6);
            }
        }
        observed = rows
            .iter()
            .map(|r| serde_json::json!({"position_native":r.position,"layer_native":r.layer,"component":r.component.as_str(),"before":r.before,"values":r.values}))
            .collect();
        let mut seen = [[false; 515]; 2];
        for w in raw_witnesses {
            let site = plan
                .sites
                .iter()
                .position(|s| s.layer == w.layer && s.component == w.component)
                .unwrap();
            assert!(w.position < 515);
            duplicates += usize::from(seen[site][w.position]);
            seen[site][w.position] = true;
            site_counts[site] += 1;
            witnesses.push(serde_json::json!([
                site,
                w.position,
                w.write,
                w.dot,
                w.before_norm,
                w.after_norm
            ]));
        }
        for (i, positions) in seen.iter().enumerate() {
            site_missing[i] = positions.iter().filter(|&&value| !value).count();
        }
    }
    let golden = if mode == "active" {
        let rows = csv("forward-logits.csv");
        let mut delta = Vec::with_capacity(48);
        for r in rows
            .iter()
            .filter(|r| r[0] == "long_prefill" && r[1] == "514")
        {
            let token = index(&r[2]);
            let expected = number(&r[3]);
            let actual = f64::from(logits[token]);
            delta.push(serde_json::json!({"token_native":token,"expected":expected,"actual":actual,"abs_error":(actual-expected).abs(),"within_0_01":(actual-expected).abs()<=0.01}));
        }
        assert_eq!(delta.len(), 48);
        Some(delta)
    } else {
        None
    };
    let site_metadata: Vec<_> = model.projection().lock().as_ref().map_or_else(Vec::new, |runtime| {
        runtime.plan.sites.iter().map(|site| serde_json::json!({"layer_native":site.layer,"component":site.component.as_str(),"coefficient":site.coef,"direction":site.direction.as_ref()})).collect()
    });
    let id = format!("{mode}/{run}");
    let receipt = serde_json::json!({"schema":1,"id":id,"mode":mode,"schedule":schedule,"last_only":last_only,"audit":audit,"cache_cleared_before_run":true,"continuation_without_cache_reset":true,"sites":site_metadata,"steps":steps,"final_logits":logits,"continuation_logits":continuation,"golden":golden,"observed_rows":observed,"witness_columns":["site_index","position_native","write","dot","before_norm","after_norm"],"witnesses":witnesses,"site_counts":site_counts,"site_missing":site_missing,"duplicate_positions":duplicates,"same_row":{"compared_values":same_count,"max_scaled_error":same_max,"count_above_2e_6":same_above},"status":"collected"});
    let encoded = receipt.to_string();
    assert!(encoded.len() <= 1024 * 1024, "bounded diagnostic receipt");
    println!("F6E_PROJECTION_DIAGNOSTIC_RUN {encoded}");
    DiagnosticOutput {
        id,
        logits,
        continuation,
    }
}

fn long_prefill_schedule_diagnostic() {
    reference();
    let _guard = crate::NativeGuard::try_acquire("projection schedule diagnostic").unwrap();
    let _ = crate::available_backends();
    let log = crate::live_capture::tests::start_load_log();
    let base = tiny();
    let backend = crate::live_capture::tests::backend_receipt(&base, crate::BackendKind::Cpu);
    drop(log);
    let ids: Vec<i32> = csv("forward-tokens.csv")
        .iter()
        .filter(|r| r[0] == "long_prefill")
        .map(|r| r[2].parse().unwrap())
        .collect();
    assert_eq!(ids.len(), 514);
    println!(
        "F6E_PROJECTION_DIAGNOSTIC_START {}",
        serde_json::json!({"schema":1,"source_manifest_sha256":std::env::var("F6E_SOURCE").unwrap_or_else(|_|"local-unreceipted".into()),"reference_manifest_sha256":REFERENCE,"model_sha256":TINY_SHA,"backend":backend,"tokens_native":ids,"n_batch":base.n_batch(),"n_ubatch":unsafe{ffi::llama_n_ubatch(base.ctx_ptr())},"runs_expected":16,"whole_forward_tolerance":0.01,"same_row_scaled_tolerance":2e-6,"status":"diagnostic_only"})
    );
    let ordinary_a = diagnostic_run(
        &base,
        "ordinary",
        "split_all",
        &ids,
        &[512, 1, 1],
        false,
        false,
    );
    let ordinary_d = diagnostic_run(
        &base,
        "ordinary",
        "grouped_last",
        &ids,
        &[512, 2],
        true,
        false,
    );
    diagnostic_compare(&ordinary_a, &ordinary_d);
    let mut runs = 2;
    for active in [false, true] {
        let mode = if active { "active" } else { "zero" };
        let mut sites = sites_for("long_prefill");
        if !active {
            for site in &mut sites {
                site.coef = 0.0;
            }
        }
        let model = base
            .derive_projection(sites, &empty(), Fault::None)
            .unwrap();
        // The first transition reproduces the failing test's protocol: observed
        // [512,1,1]/all, followed by cleared [512,2]/last without observation.
        let a = diagnostic_run(
            &model,
            mode,
            "split_all_audit",
            &ids,
            &[512, 1, 1],
            false,
            true,
        );
        let d = diagnostic_run(
            &model,
            mode,
            "grouped_last_no_audit",
            &ids,
            &[512, 2],
            true,
            false,
        );
        let repeat = diagnostic_run(
            &model,
            mode,
            "grouped_last_repeat",
            &ids,
            &[512, 2],
            true,
            false,
        );
        let a_no = diagnostic_run(
            &model,
            mode,
            "split_all_no_audit",
            &ids,
            &[512, 1, 1],
            false,
            false,
        );
        let d_yes = diagnostic_run(
            &model,
            mode,
            "grouped_last_audit",
            &ids,
            &[512, 2],
            true,
            true,
        );
        let b = diagnostic_run(
            &model,
            mode,
            "grouped_all_audit",
            &ids,
            &[512, 2],
            false,
            true,
        );
        let c = diagnostic_run(
            &model,
            mode,
            "split_last_audit",
            &ids,
            &[512, 1, 1],
            true,
            true,
        );
        for other in [&d, &a_no, &d_yes, &b, &c] {
            diagnostic_compare(&a, other);
        }
        diagnostic_compare(&d, &repeat);
        diagnostic_compare(&d, &d_yes);
        if !active {
            diagnostic_compare(&ordinary_a, &a_no);
            diagnostic_compare(&ordinary_d, &d);
        }
        runs += 7;
    }
    assert_eq!(runs, 16);
    println!(
        "F6E_PROJECTION_DIAGNOSTIC_COMPLETE {}",
        serde_json::json!({"schema":1,"runs_expected":16,"runs_collected":runs,"audit_runs_expected":8,"same_row_values_per_audit_run_expected":384,"witnesses_per_audit_run_expected":1030,"status":"collected","acceptance_claim":false,"no_tolerance_or_golden_change":true})
    );
}
