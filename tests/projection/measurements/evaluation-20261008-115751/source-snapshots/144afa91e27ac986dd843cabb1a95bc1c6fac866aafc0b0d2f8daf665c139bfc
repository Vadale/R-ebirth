//! Independent arithmetic/layout tests; no backend, model, or decode.
use super::*;

fn inputs(mode: ProjectionAdmissionMode, h: u64, p: u64) -> ProjectionAdmission {
    ProjectionAdmission {
        mode,
        hidden_size: h,
        layers: 3,
        previous_sites: p,
        steer_entries: 2,
        ablate_entries: 3,
        source_baseline_values: 3 * h,
        metadata_bytes: 100,
        metadata_scratch_bytes: 32,
        backend: 0,
        existing_direction_estimate: 1000,
        r_projection_fixed_bytes: 2000,
        r_adapter_bytes: 3000,
        max_bytes: 512 * 1024 * 1024,
    }
}
fn marker(name: &str, cases: usize, rejected: usize) {
    println!("F6E_PROJECTION_LEDGER_TEST {{\"test\":\"{name}\",\"status\":\"passed\",\"expected_cases\":{cases},\"executed_cases\":{cases},\"expected_rejections\":{rejected},\"rejected_cases\":{rejected}}}");
}
#[test]
fn projection_profile_independent_new_site_equations() {
    let p = ProjectionAllocationProfile::compiled(ProjectionFfiProfile::default());
    for (h, previous) in [(1, 0), (32, 1), (65536, 31)] {
        let i = inputs(ProjectionAdmissionMode::NewSite, h, previous);
        let e = p.estimate(&i).unwrap();
        let owners = 1 + u64::from(previous > 0);
        let sites = previous + 1;
        assert_eq!(
            e.direction_bytes,
            sites * (8 * h + p.direction_arc_header_bytes)
        );
        assert_eq!(
            e.plan_bytes,
            owners * p.plan_arc_bytes + (previous + sites) * p.site_bytes
        );
        assert_eq!(
            e.context_bytes,
            owners * (4 * h + p.runtime_bytes) + 2 * p.model_owner_bytes
        );
        assert_eq!(
            e.probe_bytes,
            20 * h
                + p.direction_arc_header_bytes
                + p.plan_arc_bytes
                + p.site_bytes
                + p.runtime_bytes
                + p.probe_state_bytes
                + p.model_owner_bytes
                + p.probe_frame_bytes
        );
        assert_eq!(
            e.adapter_data_bytes,
            4 * 3 * h + 4 * h * 3 * 4 + 4 * h + 8 * h * 2 + 4 * 2 + 16 * 3
        );
        assert_eq!(
            e.r_projection_bytes,
            2000 + (previous + 2) * r_growth(8 * h).unwrap()
        );
        assert_eq!(
            e.total_bytes,
            1000 + e.direction_bytes
                + e.plan_bytes
                + e.context_bytes
                + e.frame_bytes
                + e.probe_bytes
                + e.residual_probe_bytes
                + e.adapter_data_bytes
                + e.adapter_fixed_bytes
                + e.metadata_bytes
                + e.r_projection_bytes
                + 3000
        );
    }
    marker("projection_profile_independent_new_site_equations", 3, 0);
}
#[test]
fn projection_profile_inheritance_shares_exact_owners() {
    let p = ProjectionAllocationProfile::compiled(ProjectionFfiProfile::default());
    for previous in [0, 1, 32] {
        let i = inputs(ProjectionAdmissionMode::Inherit, 32, previous);
        let e = p.estimate(&i).unwrap();
        if previous == 0 {
            assert_eq!(e.projection_bytes, 0);
            assert_eq!(e.r_projection_bytes, 0);
        } else {
            assert_eq!(
                e.direction_bytes,
                previous * (256 + p.direction_arc_header_bytes)
            );
            assert_eq!(e.plan_bytes, p.plan_arc_bytes + previous * p.site_bytes);
            assert_eq!(
                e.context_bytes,
                2 * (128 + p.runtime_bytes) + 2 * p.model_owner_bytes
            );
            assert_eq!(
                e.r_projection_bytes,
                2000 + previous * r_growth(256).unwrap()
            );
        }
    }
    let d: std::sync::Arc<[f64]> = std::sync::Arc::from([1., 0.]);
    let plan = std::sync::Arc::new(crate::projection_layout::Plan {
        width: 2,
        depth: 1,
        sites: vec![crate::projection_layout::Site {
            layer: 0,
            component: crate::Component::MlpOut,
            coef: 1.,
            direction: d.clone(),
        }]
        .into_boxed_slice(),
    });
    let shared = plan.clone();
    assert!(std::sync::Arc::ptr_eq(&plan, &shared));
    assert!(std::sync::Arc::ptr_eq(&d, &shared.sites[0].direction));
    assert_eq!(std::sync::Arc::strong_count(&d), 2);
    marker("projection_profile_inheritance_shares_exact_owners", 4, 0);
}
#[test]
fn projection_profile_boundaries_are_checked_before_allocation() {
    let p = ProjectionAllocationProfile::compiled(ProjectionFfiProfile::default());
    let good = inputs(ProjectionAdmissionMode::NewSite, 32, 0);
    let mut bad = Vec::new();
    for h in [0, 65537, u64::MAX] {
        let mut i = good;
        i.hidden_size = h;
        bad.push(i);
    }
    let mut i = good;
    i.previous_sites = 32;
    bad.push(i);
    let mut i = good;
    i.layers = 0;
    bad.push(i);
    let mut i = good;
    i.steer_entries = u64::MAX;
    bad.push(i);
    let mut i = good;
    i.ablate_entries = u64::MAX;
    bad.push(i);
    let mut i = good;
    i.existing_direction_estimate = u64::MAX;
    bad.push(i);
    let mut i = good;
    i.max_bytes = 0;
    bad.push(i);
    let mut i = good;
    i.max_bytes = 512 * 1024 * 1024 + 1;
    bad.push(i);
    for i in &bad {
        assert!(p.estimate(i).is_err());
    }
    let e = p.estimate(&good).unwrap();
    let mut exact = good;
    exact.max_bytes = e.total_bytes;
    assert!(p.estimate(&exact).is_ok());
    exact.max_bytes -= 1;
    assert!(p.estimate(&exact).is_err());
    marker(
        "projection_profile_boundaries_are_checked_before_allocation",
        12,
        11,
    );
}
#[test]
fn projection_profile_compiled_layout_and_live_charge() {
    use crate::projection_layout::{Plan, Probe, Proof, Runtime, Site, Slot};
    use std::alloc::Layout;
    let p = ProjectionAllocationProfile::compiled(ProjectionFfiProfile::default());
    let header = Layout::new::<[std::sync::atomic::AtomicUsize; 2]>();
    assert_eq!(
        p.direction_arc_header_bytes,
        header.extend(Layout::array::<f64>(3).unwrap()).unwrap().1 as u64
    );
    assert_eq!(
        p.plan_arc_bytes,
        header
            .extend(Layout::new::<Plan>())
            .unwrap()
            .0
            .pad_to_align()
            .size() as u64
    );
    assert_eq!(p.runtime_bytes, std::mem::size_of::<Runtime>() as u64);
    assert_eq!(p.site_bytes, std::mem::size_of::<Site>() as u64);
    assert_eq!(p.probe_state_bytes, std::mem::size_of::<Probe>() as u64);
    assert_eq!(p.proof_bytes, std::mem::size_of::<Proof>() as u64);
    assert_eq!(p.slot_bytes, std::mem::size_of::<Slot>() as u64);
    assert_eq!(
        crate::live_capture::capture_allocation_bytes(0, 0, 0, 0, 0).unwrap(),
        std::mem::size_of::<crate::live_capture::LiveDispatcher>()
            + std::mem::size_of::<crate::live_capture::LiveSnapshot>()
    );
    assert!(
        std::mem::offset_of!(crate::live_capture::LiveDispatcher, projection)
            + std::mem::size_of::<Slot>()
            <= std::mem::size_of::<crate::live_capture::LiveDispatcher>()
    );
    let info = std::mem::size_of::<crate::ffi::ProjectionInfo>() as u64;
    assert_eq!(p.projection_info_bytes, info);
    assert!(p.callback_frame_bytes >= 2 * info + p.cpp_access_frame_bytes + p.cpp_name_frame_bytes);
    let fields = p.fields();
    assert_eq!(fields.len(), PROJECTION_PROFILE_FIELDS);
    assert!(fields.iter().all(|(_, v)| *v < 9007199254740992));
    marker("projection_profile_compiled_layout_and_live_charge", 12, 0);
}

#[test]
fn projection_profile_owned_capacities_refuse_hidden_spare_storage() {
    let i = inputs(ProjectionAdmissionMode::NewSite, 32, 1);
    let exact = [2, 64, 3, 3, 3, 96, 96, 96, 32, 96];
    assert!(i.validate_adapter_capacities(exact).is_ok());
    for j in 0..exact.len() {
        let mut spare = exact;
        spare[j] += 1;
        assert!(i.validate_adapter_capacities(spare).is_err());
    }
    marker(
        "projection_profile_owned_capacities_refuse_hidden_spare_storage",
        11,
        10,
    );
}

#[test]
fn projection_profile_error_grammar_owns_one_exact_copy() {
    for (status, width) in [(i32::MIN, usize::MAX), (i32::MAX, 0)] {
        let ablate=bounded_intervention_error(format_args!("The engine rejected the ablation mask (intervention setter returned {status}); its width must equal the model's hidden size ({width})."));
        let steer=bounded_intervention_error(format_args!("The engine rejected the steering adapter (setter status {status}, hidden width {width})."));
        for error in [ablate, steer] {
            let RebirthError::Intervention { reason } = error else {
                panic!("wrong class")
            };
            assert!(reason.len() <= ERROR_BYTES);
            assert_eq!(reason.capacity(), reason.len());
            assert!(reason.contains(&status.to_string()));
            assert!(reason.contains(&width.to_string()));
        }
    }
    for status in [i32::MIN, i32::MAX] {
        let reason = bounded_error_reason(format_args!("llama_decode returned {status}"));
        assert_eq!(reason, format!("llama_decode returned {status}"));
        assert_eq!(reason.capacity(), reason.len());
        assert!(reason.len() <= ERROR_BYTES);
    }
    marker("projection_profile_error_grammar_owns_one_exact_copy", 6, 0);
}

#[test]
fn projection_budget_oom_class_preserves_arithmetic_and_error_capacity() {
    let p = ProjectionAllocationProfile::compiled(ProjectionFfiProfile::default());
    let mut cases = 0;
    let mut refusals = 0;
    for (mode, h, previous) in [
        (ProjectionAdmissionMode::NewSite, 1, 0),
        (ProjectionAdmissionMode::NewSite, 32, 1),
        (ProjectionAdmissionMode::Inherit, 32, 2),
        (ProjectionAdmissionMode::NewSite, 65536, 31),
    ] {
        let mut i = inputs(mode, h, previous);
        let estimate = p.estimate(&i).unwrap();
        i.max_bytes = estimate.total_bytes;
        assert_eq!(p.estimate(&i).unwrap().fields(), estimate.fields());
        cases += 1;
        i.max_bytes -= 1;
        let error = p.estimate(&i).unwrap_err();
        assert_eq!(error.class(), "relm_error_oom");
        match error {
            RebirthError::Oom {
                estimate_bytes,
                budget_bytes,
                suggestion,
            } => {
                assert_eq!(estimate_bytes, estimate.total_bytes);
                assert_eq!(budget_bytes, i.max_bytes);
                assert_eq!(suggestion, BUDGET_MESSAGE);
                assert_eq!(suggestion.capacity(), suggestion.len());
                assert!(suggestion.capacity() <= p.error_format_bytes as usize);
            }
            other => panic!("expected predictive OOM, got {other:?}"),
        }
        cases += 1;
        refusals += 1;
    }
    for invalid in 0..3 {
        let mut i = inputs(ProjectionAdmissionMode::NewSite, 32, 0);
        match invalid {
            0 => i.max_bytes = 0,
            1 => i.max_bytes = MAX_BYTES + 1,
            _ => i.existing_direction_estimate = u64::MAX,
        }
        let error = p.estimate(&i).unwrap_err();
        assert_eq!(error.class(), "relm_error_intervention");
        assert!(matches!(error, RebirthError::Intervention { .. }));
        cases += 1;
        refusals += 1;
    }
    // New fixed OOM text fits the already admitted largest setter/context
    // grammar. Enum/format-frame/layout charges therefore remain unchanged.
    assert_eq!(p.error_format_bytes, 150);
    assert_eq!(ERROR_BYTES, 150);
    assert_eq!((cases, refusals), (11, 7));
    marker(
        "projection_budget_oom_class_preserves_arithmetic_and_error_capacity",
        cases,
        refusals,
    );
}
