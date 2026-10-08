// Internal model-free R-hosted regression. Use an initialized main-thread R
// process; no model handle, tokenizer, backend initialization or inference.
#[extendr]
fn rebirth_selftest_projection_budget_error() -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        fn field(list: &List, key: &str) -> Robj {
            list.iter().find(|(name, _)| *name == key).unwrap().1
        }
        let p = ProjectionAllocationProfile::compiled(projection_native_profile()?);
        let mut i = rebirth_llm::ProjectionAdmission {
            mode: ProjectionAdmissionMode::NewSite,
            hidden_size: 32,
            layers: 3,
            previous_sites: 0,
            steer_entries: 0,
            ablate_entries: 0,
            source_baseline_values: 0,
            metadata_bytes: 0,
            metadata_scratch_bytes: 0,
            backend: 0,
            existing_direction_estimate: 0,
            r_projection_fixed_bytes: 4096,
            r_adapter_bytes: 0,
            max_bytes: 64 * 1024 * 1024,
        };
        let expected = p.estimate(&i)?;
        i.max_bytes = expected.total_bytes;
        assert_eq!(p.estimate(&i)?.fields(), expected.fields());
        let mut cases = 1;
        i.max_bytes -= 1;
        let oom = projection_resolve(Ok(p.estimate(&i).map(|_| Robj::from(()))));
        let failure = oom.as_list().unwrap();
        assert_eq!(
            failure.names().unwrap().collect::<Vec<_>>(),
            ["ok", "class", "message", "fields"]
        );
        assert_eq!(field(&failure, "ok").as_bool(), Some(false));
        assert_eq!(field(&failure, "class").as_str(), Some("relm_error_oom"));
        cases += 1;
        let fields = field(&failure, "fields").as_list().unwrap();
        assert_eq!(
            fields.names().unwrap().collect::<Vec<_>>(),
            ["estimate_bytes", "budget_bytes"]
        );
        assert_eq!(
            field(&fields, "estimate_bytes").as_real(),
            Some(expected.total_bytes as f64)
        );
        assert_eq!(
            field(&fields, "budget_bytes").as_real(),
            Some(i.max_bytes as f64)
        );
        cases += 1;
        let message = field(&failure, "message");
        assert_eq!(message.as_str(), Some("Projection owners and working copies exceed max_bytes. Reduce projection sites or increase max_bytes."));
        assert!(message.as_str().unwrap().len() <= p.error_format_bytes as usize);
        cases += 1;
        let mut malformed = i;
        malformed.max_bytes = 0;
        let malformed = projection_resolve(Ok(p.estimate(&malformed).map(|_| Robj::from(()))));
        let failure = malformed.as_list().unwrap();
        assert_eq!(
            field(&failure, "class").as_str(),
            Some("relm_error_intervention")
        );
        assert_eq!(
            field(&failure, "fields")
                .as_list()
                .unwrap()
                .names()
                .unwrap()
                .collect::<Vec<_>>(),
            ["reason"]
        );
        cases += 1;
        let mut overflow = i;
        overflow.existing_direction_estimate = u64::MAX;
        let overflow = projection_resolve(Ok(p.estimate(&overflow).map(|_| Robj::from(()))));
        assert_eq!(
            field(&overflow.as_list().unwrap(), "class").as_str(),
            Some("relm_error_intervention")
        );
        cases += 1;
        let error_response_bytes = projection_error_response_bytes();
        assert!(error_response_bytes <= p.ffi_response_bytes);
        cases += 1;
        // These two compiled fields are source-preserved after adding the
        // fixed two-scalar OOM transport. The dynamic registry is independent.
        assert_eq!(p.error_format_bytes, 150);
        assert_eq!(p.ffi_response_bytes, 1512);
        cases += 1;
        assert_eq!(cases, 8);
        println!("F6E_PROJECTION_BUDGET_CLASS_TEST {{\"test\":\"projection_budget_error_rhost\",\"status\":\"passed\",\"expected_cases\":8,\"executed_cases\":{cases},\"expected_rejections\":3,\"rejected_cases\":3,\"error_response_bytes\":{error_response_bytes},\"ffi_response_bytes\":{},\"error_format_bytes\":{},\"model_loads\":0,\"inference_calls\":0}}",p.ffi_response_bytes,p.error_format_bytes);
        Ok(List::from_names_and_values(
            [
                "ok",
                "oom",
                "malformed",
                "overflow",
                "profile",
                "inputs",
                "terms",
                "error_response_bytes",
            ],
            [
                Robj::from(true),
                oom,
                malformed,
                overflow,
                projection_numeric_list(p.fields())?,
                projection_numeric_list(i.fields())?,
                projection_numeric_list(expected.fields())?,
                Robj::from(error_response_bytes as f64),
            ],
        )
        .expect("fixed budget error selftest response")
        .into())
    })))
}
