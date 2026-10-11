// One prefix-local diagnostic for the retained Linux 7501d6c activation failure.
// Raw outliers are observations, never a substitute acceptance bound.
struct PrefixDebtReference {
    ids: Vec<i32>,
    activations: Vec<Vec<String>>,
    sites: Vec<Vec<String>>,
    logits: Vec<f64>,
}

struct PrefixDebtOutput {
    id: &'static str,
    logits: Vec<f32>,
    rows: Vec<Observation>,
    witnesses: Vec<Witness>,
}

fn prefix_debt_row(rows: &[Observation], position: usize, layer: u32, c: Component) -> &[f32] {
    let mut matching = rows
        .iter()
        .filter(|r| r.position == position && r.layer == layer && r.component == c && !r.before);
    let row = matching.next().unwrap();
    assert!(matching.next().is_none());
    &row.values
}

fn prefix_debt_run(
    model: &LoadedModel,
    id: &'static str,
    active: bool,
    chunk: usize,
    audit: bool,
    reference: &PrefixDebtReference,
) -> PrefixDebtOutput {
    assert_eq!(reference.ids.len(), 512);
    assert!([1, 128, 512].contains(&chunk));
    model.clear_memory();
    model.projection_reset_stats();
    if audit {
        model.projection_audit(&[0, 1, 127, 511]);
    }
    for (i, tokens) in reference.ids.chunks(chunk).enumerate() {
        model
            .decode_projection_tokens(tokens, (i * chunk) as i32, false)
            .unwrap();
    }
    let logits = model.logits_ith((chunk - 1) as i32, 48).unwrap();
    let stats = model.projection_stats();
    let (rows, witnesses) = if audit {
        model.projection_take_audit()
    } else {
        (Vec::new(), Vec::new())
    };
    let mut raw_rows = Vec::with_capacity(rows.len());
    let mut same_values = 0;
    let mut same_max = 0.0f64;
    let mut missing = 0;
    let mut duplicate = 0;
    let mut writes = 0;
    let mut coverage = [[false; 512]; 2];
    let mut raw_witnesses = Vec::with_capacity(witnesses.len());
    let mut addends = serde_json::Value::Null;
    if audit {
        assert_eq!(rows.len(), 44);
        assert_eq!(witnesses.len(), 1024);
        let plan = model.projection().lock().as_ref().unwrap().plan.clone();
        assert_eq!(plan.sites.len(), 2);
        for before in rows.iter().filter(|r| r.before) {
            let site = plan
                .sites
                .iter()
                .find(|s| s.layer == before.layer && s.component == before.component)
                .unwrap();
            let after = prefix_debt_row(&rows, before.position, before.layer, before.component);
            let mut dot = 0.0f64;
            for (&value, &direction) in before.values.iter().zip(site.direction.iter()) {
                dot += f64::from(value) * direction;
            }
            assert!(dot.is_finite());
            for ((&value, &actual), &direction) in
                before.values.iter().zip(after).zip(site.direction.iter())
            {
                let expected = if site.coef == 0.0 {
                    value
                } else {
                    (f64::from(value) - (site.coef * direction) * dot) as f32
                };
                let scaled = (f64::from(actual) - f64::from(expected)).abs()
                    / (1. + f64::from(expected).abs());
                assert!(scaled.is_finite());
                same_values += 1;
                same_max = same_max.max(scaled);
            }
        }
        for row in &rows {
            assert_eq!(row.values.len(), 32);
            assert!(row.values.iter().all(|v| v.is_finite()));
            let expected = active.then(|| {
                (0..32)
                    .map(|neuron| {
                        let source = if row.before {
                            &reference.sites
                        } else {
                            &reference.activations
                        };
                        let r = source
                            .iter()
                            .find(|r| {
                                index(&r[1]) == row.position + 1
                                    && index(&r[2]) == row.layer as usize + 1
                                    && component(&r[3]) == row.component
                                    && index(&r[4]) == neuron + 1
                            })
                            .unwrap();
                        number(&r[5])
                    })
                    .collect::<Vec<_>>()
            });
            let signed = expected.as_ref().map(|values| {
                row.values
                    .iter()
                    .zip(values)
                    .map(|(&a, &e)| f64::from(a) - e)
                    .collect::<Vec<_>>()
            });
            raw_rows.push(serde_json::json!({
                "source_pos":row.position+1,"layer":row.layer+1,
                "component":row.component.as_str(),"before":row.before,
                "values":row.values.as_ref(),"reference_values":expected,"signed_errors":signed
            }));
        }
        for witness in &witnesses {
            let site = plan
                .sites
                .iter()
                .position(|s| s.layer == witness.layer && s.component == witness.component)
                .unwrap();
            assert!(witness.position < 512);
            duplicate += usize::from(coverage[site][witness.position]);
            coverage[site][witness.position] = true;
            writes += usize::from(witness.write);
            raw_witnesses.push(serde_json::json!([
                site,
                witness.position + 1,
                witness.write,
                witness.dot,
                witness.before_norm,
                witness.after_norm
            ]));
        }
        missing = coverage
            .iter()
            .flatten()
            .filter(|&&present| !present)
            .count();
        let input = prefix_debt_row(&rows, 511, 0, Component::Residual)[12];
        let attn = prefix_debt_row(&rows, 511, 1, Component::AttnOut)[12];
        let mlp = prefix_debt_row(&rows, 511, 1, Component::MlpOut)[12];
        let residual = prefix_debt_row(&rows, 511, 1, Component::Residual)[12];
        let native_sum = (input + attn) + mlp;
        let expected = active.then(|| {
            [
                (1, Component::Residual),
                (2, Component::AttnOut),
                (2, Component::MlpOut),
                (2, Component::Residual),
            ]
            .map(|(layer, component)| {
                let r = reference
                    .activations
                    .iter()
                    .find(|r| {
                        r[1] == "512"
                            && index(&r[2]) == layer
                            && r[3] == component.as_str()
                            && r[4] == "13"
                    })
                    .unwrap();
                number(&r[5])
            })
        });
        let actual = [input, attn, mlp, residual];
        let signed =
            expected.map(|e| std::array::from_fn::<_, 4, _>(|i| f64::from(actual[i]) - e[i]));
        addends = serde_json::json!({
            "source_pos":512,"layer":2,"neuron":13,
            "columns":["previous_residual","attn_out","mlp_out","residual"],
            "values":actual,"reference_values":expected,"signed_errors":signed,
            "native_f32_sum":native_sum,
            "native_addition_bitwise_equal":native_sum.to_bits()==residual.to_bits()
        });
    }
    let errors = active.then(|| {
        logits
            .iter()
            .zip(&reference.logits)
            .map(|(&a, &e)| f64::from(a) - e)
            .collect::<Vec<_>>()
    });
    let receipt = serde_json::json!({
        "id":id,"active":active,"audit":audit,"chunk_tokens":chunk,
        "decode_calls":512/chunk,"last_only":false,"prefix_tokens":512,"cache_cleared":true,
        "final_logits":logits,"reference_logits":if active {Some(&reference.logits)} else {None},
        "logit_signed_errors":errors,"rows":raw_rows,
        "witness_columns":["site_index","source_pos","write","dot","before_norm","after_norm"],
        "witnesses":raw_witnesses,"site_missing":missing,"site_duplicates":duplicate,
        "witness_writes":writes,"same_row_values":same_values,
        "same_row_max_scaled_error":same_max,"same_row_scaled_bound":2e-6,
        "site_rows":stats.rows,"read_bytes":stats.read_bytes,
        "write_bytes":stats.write_bytes,"barriers":stats.barriers,
        "failing_coordinate_addends":addends,"downstream_bound":0.01,"acceptance_claim":false
    });
    let encoded = receipt.to_string();
    assert!(encoded.len() <= 1024 * 1024);
    println!("F6E_PREFIX_DEBT_RUN {encoded}");
    // Emit raw evidence before a proof failure. Whole-forward outliers above
    // .01 remain visible observations; the original acceptance is unchanged.
    assert!(logits.iter().all(|v| v.is_finite()));
    if audit {
        assert_eq!((missing, duplicate, same_values), (0, 0, 256));
        assert!(same_max <= 2e-6);
        assert_eq!(writes, if active { 1024 } else { 0 });
        assert_eq!(stats.rows, 1024);
    }
    assert_eq!(stats.write_bytes, if active { 1024 * 32 * 4 } else { 0 });
    PrefixDebtOutput {
        id,
        logits,
        rows,
        witnesses,
    }
}

#[test]
#[ignore = "One first-512-prefix localization of retained 7501d6c failure; owner only"]
fn projection_long_prefill_debt_diagnostic() {
    reference();
    let _guard = crate::NativeGuard::try_acquire("projection prefix debt diagnosis").unwrap();
    let _ = crate::available_backends();
    let log = crate::live_capture::tests::start_load_log();
    let base = tiny();
    let backend = crate::live_capture::tests::backend_receipt(&base, crate::BackendKind::Cpu);
    drop(log);
    let mut ids: Vec<i32> = csv("forward-tokens.csv")
        .iter()
        .filter(|r| r[0] == "long_prefill")
        .map(|r| r[2].parse().unwrap())
        .collect();
    assert_eq!(ids.len(), 514);
    ids.truncate(512);
    let fixture = PrefixDebtReference {
        ids,
        activations: csv("forward-activations.csv")
            .into_iter()
            .filter(|r| r[0] == "long_prefill")
            .collect(),
        sites: csv("forward-sites.csv")
            .into_iter()
            .filter(|r| r[0] == "long_prefill")
            .collect(),
        logits: csv("forward-logits.csv")
            .iter()
            .filter(|r| r[0] == "long_prefill" && r[1] == "512")
            .map(|r| number(&r[3]))
            .collect(),
    };
    assert_eq!(fixture.logits.len(), 48);
    let sites = sites_for("long_prefill");
    assert_eq!(sites.len(), 2);
    let active = base
        .derive_projection(sites.clone(), &empty(), Fault::None)
        .unwrap();
    let mut zero_sites = sites.clone();
    for site in &mut zero_sites {
        site.coef = 0.;
    }
    let zero = base
        .derive_projection(zero_sites, &empty(), Fault::None)
        .unwrap();
    println!(
        "F6E_PREFIX_DEBT_START {}",
        serde_json::json!({
            "schema":1,
            "source":std::env::var("F6E_SOURCE").unwrap_or_else(|_|"local-unreceipted".into()),
            "reference_manifest_sha256":REFERENCE,"model_sha256":TINY_SHA,"backend":backend,
            "n_batch":base.n_batch(),"n_ubatch":unsafe{ffi::llama_n_ubatch(base.ctx_ptr())},
            "tokens_native":fixture.ids,"positions_public":[1,2,128,512],
            "sites":sites.iter().map(|s|serde_json::json!({
                "layer":s.layer+1,"component":s.component.as_str(),
                "coef":s.coef,"direction":s.direction.as_ref()
            })).collect::<Vec<_>>(),
            "runs_expected":7,"tiny_loads":1,"derived_handles":2,"acceptance_claim":false
        })
    );
    let runs = [
        prefix_debt_run(&active, "active/default", true, 512, true, &fixture),
        prefix_debt_run(&active, "active/repeat", true, 512, true, &fixture),
        prefix_debt_run(&active, "active/four_calls", true, 128, true, &fixture),
        prefix_debt_run(&active, "active/token_at_a_time", true, 1, true, &fixture),
        prefix_debt_run(&active, "active/no_audit", true, 512, false, &fixture),
        prefix_debt_run(&zero, "zero/audit", false, 512, true, &fixture),
        prefix_debt_run(&base, "ordinary", false, 512, false, &fixture),
    ];
    for right in [1, 2, 3, 4] {
        println!(
            "F6E_PREFIX_DEBT_PAIR {}",
            serde_json::json!({"left":runs[0].id,"right":runs[right].id,"final_logits":diagnostic_delta(&runs[0].logits,&runs[right].logits)})
        );
    }
    println!(
        "F6E_PREFIX_DEBT_PAIR {}",
        serde_json::json!({"left":runs[5].id,"right":runs[6].id,"final_logits":diagnostic_delta(&runs[5].logits,&runs[6].logits)})
    );
    assert!(same_logit_bits(&runs[0].logits, &runs[1].logits));
    assert!(same_logit_bits(&runs[5].logits, &runs[6].logits));
    assert_eq!(runs[0].rows.len(), runs[1].rows.len());
    for (a, b) in runs[0].rows.iter().zip(&runs[1].rows) {
        assert_eq!(
            (a.position, a.layer, a.component, a.before),
            (b.position, b.layer, b.component, b.before)
        );
        assert!(a
            .values
            .iter()
            .zip(b.values.iter())
            .all(|(a, b)| a.to_bits() == b.to_bits()));
    }
    assert_eq!(runs[0].witnesses.len(), runs[1].witnesses.len());
    for (a, b) in runs[0].witnesses.iter().zip(&runs[1].witnesses) {
        assert_eq!(
            (a.position, a.layer, a.component, a.write),
            (b.position, b.layer, b.component, b.write)
        );
        assert_eq!(
            (
                a.dot.to_bits(),
                a.before_norm.to_bits(),
                a.after_norm.to_bits()
            ),
            (
                b.dot.to_bits(),
                b.before_norm.to_bits(),
                b.after_norm.to_bits()
            )
        );
    }
    println!(
        "F6E_PREFIX_DEBT_COMPLETE {}",
        serde_json::json!({
            "schema":1,"status":"collected","runs":7,"audited_runs":5,
            "rows_per_audited_run":44,"values_per_audited_run":1408,
            "witnesses_per_audited_run":1024,"same_row_values":1280,
            "repeat_row_values":1408,"repeat_witnesses":1024,"repeat_logit_values":48,
            "zero_logit_values":48,"repeat_bitwise_equal":true,"zero_bitwise_equal":true,
            "tiny_loads":1,"derived_handles":2,"prefix_decode_calls":521,
            "acceptance_claim":false,"golden_or_tolerance_change":false
        })
    );
}
