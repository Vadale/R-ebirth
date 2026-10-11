use super::*;

fn numeric_json<const N: usize>(fields: [(&str, u64); N]) -> String {
    fields
        .iter()
        .map(|(key, value)| format!("\"{key}\":{value}"))
        .collect::<Vec<_>>()
        .join(",")
}
fn r_size(value: &Robj) -> u64 {
    let bytes = eval_string_with_params("as.numeric(utils::object.size(param.0))", &[value])
        .expect("bounded R size measurement")
        .as_real()
        .expect("numeric object.size");
    assert!(bytes.is_finite() && bytes >= 0. && bytes.fract() == 0. && bytes < 9007199254740992.);
    bytes as u64
}
fn tag_receipt(
    a: &ExternalPtr<LlmHandle>,
    b: &ExternalPtr<LlmHandle>,
    profile: &ProjectionAllocationProfile,
) {
    assert!(a.is_closed() && b.is_closed());
    assert!(a.state.model.borrow().is_none() && b.state.model.borrow().is_none());
    let tag_a = a.tag();
    let tag_b = b.tag();
    let name = std::any::type_name::<LlmHandle>();
    assert_eq!(tag_a.len(), 1);
    assert_eq!(tag_b.len(), 1);
    assert_eq!(tag_a.as_str(), Some(name));
    assert_eq!(tag_b.as_str(), Some(name));
    assert_eq!(profile.ffi_handle_tag_bytes, name.len() as u64);
    let tag_type = eval_string_with_params("typeof(param.0)", &[&tag_a]).unwrap();
    assert_eq!(tag_type.as_str(), Some("character"));
    // ASCII type-name bytes point into the actual interned CHARSXP. Compare
    // identity but never print addresses; two models are not constructed.
    let shared_character_payload =
        tag_a.as_str().unwrap().as_ptr() == tag_b.as_str().unwrap().as_ptr();
    assert!(
        shared_character_payload,
        "tag ledger counts one interned character payload"
    );
    let ptr_a: Robj = a.clone().into();
    let ptr_b: Robj = b.clone().into();
    let pointer_type = eval_string_with_params("typeof(param.0)", &[&ptr_a]).unwrap();
    assert_eq!(pointer_type.as_str(), Some("externalptr"));
    let protected_is_null = a.protected().is_null() && b.protected().is_null();
    assert!(protected_is_null);
    let pair: Robj = List::from_values([ptr_a.clone(), ptr_b.clone()]).into();
    let tags: Robj = List::from_values([tag_a.clone(), tag_b.clone()]).into();
    let combined: Robj =
        List::from_values([ptr_a.clone(), ptr_b.clone(), tag_a.clone(), tag_b.clone()]).into();
    let empty_pair: Robj = List::from_values([Robj::from(()), Robj::from(())]).into();
    let empty_quad: Robj = List::from_values([
        Robj::from(()),
        Robj::from(()),
        Robj::from(()),
        Robj::from(()),
    ])
    .into();
    let charged_tag_bytes = 2 * rebirth_llm::live_r_vector_bytes(8).unwrap()
        + rebirth_llm::live_r_vector_bytes(profile.ffi_handle_tag_bytes + 1).unwrap();
    println!("F6E_PROJECTION_R_TAG {{\"fixture\":\"two_closed_llm_handles\",\"model_count\":0,\"externalptr_r_type\":\"externalptr\",\"protected_is_null\":true,\"tag_r_type\":\"character\",\"tag_length\":1,\"tag_utf8_bytes\":{},\"externalptr_bytes\":[{},{}],\"tag_bytes\":[{},{}],\"pointer_pair_bytes\":{},\"tag_pair_bytes\":{},\"combined_bytes\":{},\"empty_pair_bytes\":{},\"empty_quad_bytes\":{},\"charged_tag_bytes\":{},\"shared_character_payload\":{}}}",
        name.len(),r_size(&ptr_a),r_size(&ptr_b),r_size(&tag_a),r_size(&tag_b),r_size(&pair),r_size(&tags),r_size(&combined),r_size(&empty_pair),r_size(&empty_quad),charged_tag_bytes,shared_character_payload);
}
fn twin_receipts(profile: &ProjectionAllocationProfile) {
    use rebirth_llm::{
        ProjectionAdmission,
        ProjectionAdmissionMode::{Inherit, NewSite},
    };
    // Shape arithmetic only: no direction, dense adapter, model or context is
    // allocated, including the maximum-width/count fixtures.
    let cases = [
        ("new_empty_h1_cpu", NewSite, 1, 0, 0, 0, 0),
        ("new_steer_h32_metal", NewSite, 32, 1, 2, 0, 1),
        ("new_ablate_h65536_cuda", NewSite, 65536, 31, 0, 3, 2),
        ("new_both_h1_metal", NewSite, 1, 31, 2, 3, 1),
        ("new_both_h32_cuda", NewSite, 32, 0, 2, 3, 2),
        ("new_empty_h65536_cpu", NewSite, 65536, 1, 0, 0, 0),
        ("inherit_empty_h1_cpu", Inherit, 1, 0, 0, 0, 0),
        ("inherit_steer_h32_cuda", Inherit, 32, 1, 2, 0, 2),
        ("inherit_ablate_h65536_metal", Inherit, 65536, 32, 0, 3, 1),
        ("inherit_both_h1_cuda", Inherit, 1, 31, 2, 3, 2),
        ("inherit_empty_h32_metal", Inherit, 32, 32, 0, 0, 1),
        ("inherit_both_h65536_cpu", Inherit, 65536, 1, 2, 3, 0),
    ];
    assert_eq!(cases.len(), 12);
    for (case_index, (case, mode, h, previous_sites, steer_entries, ablate_entries, backend)) in
        cases.into_iter().enumerate()
    {
        let mut inputs = ProjectionAdmission {
            mode,
            hidden_size: h,
            layers: 3,
            previous_sites,
            steer_entries,
            ablate_entries,
            source_baseline_values: if steer_entries > 0 { 3 * h } else { 0 },
            metadata_bytes: 0,
            metadata_scratch_bytes: 0,
            backend,
            existing_direction_estimate: 4097,
            r_projection_fixed_bytes: 4096 + case_index as u64,
            r_adapter_bytes: if steer_entries > 0 || ablate_entries > 0 {
                1537
            } else {
                0
            },
            max_bytes: 512 * 1024 * 1024,
        };
        let terms = profile
            .estimate(&inputs)
            .expect("synthetic admission within cap");
        assert!(terms.total_bytes > 0);
        inputs.max_bytes = terms.total_bytes;
        let exact = profile
            .estimate(&inputs)
            .expect("exact combined budget admits");
        assert_eq!(exact.fields(), terms.fields());
        let mut under = inputs;
        under.max_bytes -= 1;
        assert!(
            profile.estimate(&under).is_err(),
            "budget minus one must refuse {case}"
        );
        // These are actual native results, not a hand-assembled expected
        // profile. The parent independently recomputes all13 terms in R.
        println!("F6E_PROJECTION_LEDGER_TWIN {{\"case\":\"{case}\",\"profile\":{{{}}},\"inputs\":{{{}}},\"terms\":{{{}}}}}",
            numeric_json(profile.fields()),numeric_json(inputs.fields()),numeric_json(terms.fields()));
    }
}
pub(super) fn projection_profile_ffi_descriptors_and_schema_are_exact() {
    // Empty closed handles retain the real ExternalPtr<LlmHandle> type
    // and tag, but contain no model and cannot enter the native engine.
    let pointer_a = ExternalPtr::new(LlmHandle::empty());
    let pointer_b = ExternalPtr::new(LlmHandle::empty());
    let ffi = projection_native_profile().unwrap();
    assert_eq!(
        ffi.adapter_fixed_bytes,
        3 * std::mem::size_of::<Vec<i32>>() as u64 + 2 * std::mem::size_of::<Vec<f64>>() as u64
    );
    let p = ProjectionAllocationProfile::compiled(ffi);
    let list = rebirth_projection_allocation_profile().as_list().unwrap();
    assert_eq!(list.len(), PROJECTION_PROFILE_FIELDS);
    for (key, value) in p.fields() {
        assert_eq!(
            list.iter().find(|(k, _)| *k == key).unwrap().1.as_real(),
            Some(value as f64)
        );
    }
    let bad = list!(
        mode = "new_site",
        layer = 1.,
        component = "mlp_out",
        coef = 1.,
        direction = vec![1.],
        steer_entries = 0.,
        ablate_entries = 0.,
        existing_direction_estimate = 0.,
        r_projection_fixed_bytes = 0.,
        r_adapter_bytes = 0.,
        max_bytes = 67108864.
    );
    assert!(projection_scalars(&bad).is_ok());
    for x in [-1., f64::INFINITY, f64::NAN, 1.5, 9007199254740992.] {
        assert!(projection_uint(&Robj::from(x)).is_err());
    }
    let mut duplicated = bad.clone();
    duplicated.set_names(["mode"; 11]).unwrap();
    assert!(projection_scalars(&duplicated).is_err());
    assert!(projection_registry_charge(usize::MAX).is_err());
    println!(
        "F6E_PROJECTION_ALLOCATION_PROFILE {{{}}}",
        numeric_json(p.fields())
    );
    tag_receipt(&pointer_a, &pointer_b, &p);
    twin_receipts(&p);
    println!("F6E_PROJECTION_LEDGER_TEST {{\"test\":\"projection_profile_ffi_descriptors_and_schema_are_exact\",\"status\":\"passed\",\"expected_cases\":47,\"executed_cases\":47,\"expected_rejections\":19,\"rejected_cases\":19}}");
}
