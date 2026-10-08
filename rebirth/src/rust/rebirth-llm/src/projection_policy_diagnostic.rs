// A new failure-localization experiment, not a replacement acceptance gate.
// It leaves the original pruning bitwise assertion and all numerical bounds intact.
#[test]
#[ignore = "run explicitly after an output-policy failure; not ordinary acceptance"]
fn projection_output_policy_failure_diagnostic() {
    let _guard = crate::NativeGuard::try_acquire("projection policy diagnosis").unwrap();
    let _ = crate::available_backends();
    let load_log = crate::live_capture::tests::start_load_log();
    let base = tiny();
    let backend = crate::live_capture::tests::backend_receipt(&base, crate::BackendKind::Cpu);
    drop(load_log);
    println!("F6E_OUTPUT_POLICY_DIAGNOSTIC_BACKEND {backend}");
    let ids: Vec<i32> = csv("forward-tokens.csv")
        .iter()
        .filter(|r| r[0] == "mlp_out_last_c1")
        .map(|r| r[2].parse().unwrap())
        .collect();
    assert_eq!(ids.len(), 5);
    let active_sites = sites_for("mlp_out_last_c1");
    assert_eq!(active_sites.len(), 1);
    let mut zero_sites = active_sites.clone();
    zero_sites[0].coef = 0.;
    let zero = base
        .derive_projection(zero_sites, &empty(), Fault::None)
        .unwrap();
    let active = base
        .derive_projection(active_sites.clone(), &empty(), Fault::None)
        .unwrap();
    let mut records = Vec::new();
    for (variant, model) in [("original", &base), ("zero", &zero), ("active", &active)] {
        for last_only in [false, true] {
            let mut repeated = Vec::new();
            for repeat in 0..2 {
                model.clear_memory();
                if variant != "original" {
                    model.projection_audit(&[ids.len() - 1]);
                }
                model.decode_projection_tokens(&ids, 0, last_only).unwrap();
                let logits = model.logits_ith((ids.len() - 1) as i32, 48).unwrap();
                let mut rows = Vec::new();
                if variant != "original" {
                    let (observations, _) = model.projection_take_audit();
                    let site = &active_sites[0];
                    let matched: Vec<_> = observations
                        .iter()
                        .filter(|o| {
                            o.position == ids.len() - 1
                                && o.layer == site.layer
                                && o.component == site.component
                        })
                        .collect();
                    assert_eq!(matched.len(), 2);
                    let before = matched.iter().find(|o| o.before).unwrap();
                    let after = matched.iter().find(|o| !o.before).unwrap();
                    assert_eq!(before.values.len(), 32);
                    assert_eq!(after.values.len(), 32);
                    let coef = if variant == "zero" { 0. } else { site.coef };
                    let dot: f64 = before
                        .values
                        .iter()
                        .zip(site.direction.iter())
                        .map(|(&x, &v)| f64::from(x) * v)
                        .sum();
                    for (j, (&input, &output)) in
                        before.values.iter().zip(&after.values).enumerate()
                    {
                        let expected = if coef == 0. {
                            input
                        } else {
                            (f64::from(input) - (coef * site.direction[j]) * dot) as f32
                        };
                        let error = (f64::from(output) - f64::from(expected)).abs();
                        assert!(error <= 2e-6 * (1. + f64::from(expected).abs()));
                        if coef == 0. {
                            assert_eq!(input.to_bits(), output.to_bits());
                        }
                    }
                    rows.push(serde_json::json!({"before":before.values,"after":after.values,"direction":site.direction.as_ref(),"coef":coef,"dot":dot}));
                }
                let history = fixed_history_logits(model, ids.len());
                let record = serde_json::json!({"variant":variant,"last_only":last_only,"repeat":repeat,"tokens":ids,"final_logits":logits,"history_logits":history,"site_rows":rows});
                println!("F6E_OUTPUT_POLICY_DIAGNOSTIC_ROW {record}");
                repeated.push((logits, history));
                records.push(record);
            }
            // Same policy replay remains bitwise strict; cross-policy differences
            // are retained as observations and do not excuse the original failure.
            assert!(same_logit_bits(&repeated[0].0, &repeated[1].0));
            assert!(same_logit_bits(&repeated[0].1, &repeated[1].1));
        }
    }
    assert_eq!(records.len(), 12);
    println!("F6E_OUTPUT_POLICY_DIAGNOSTIC_COMPLETE records=12 tiny_loads=1 constructors=2 acceptance_replaced=0");
}
