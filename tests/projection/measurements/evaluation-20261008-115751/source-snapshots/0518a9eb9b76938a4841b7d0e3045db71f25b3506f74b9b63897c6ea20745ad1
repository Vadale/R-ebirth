// D046: these tests were written against the separately frozen d8a4800 oracle
// before the projection implementation. No expected value comes from the engine.
use super::*;

#[test]
fn projection_row_matches_independent_reference() {
    arithmetic_reference();
}
#[test]
fn projection_boundary_rejects_invalid_inputs() {
    boundary_reference();
}
#[test]
fn projection_capacity_ledger_matches_owned_buffers() {
    capacity_reference();
}
#[test]
fn projection_classifier_accepts_only_declared_dense_sites() {
    classifier_reference();
}
#[test]
fn projection_buffer_identity_accepts_only_host_or_default_shared() {
    let bits = unsafe { ffi::relm_projection_buffer_controls() };
    assert_eq!(bits, (1 << 21) - 1, "buffer identity control mask");
    emit(
        "projection_buffer_identity_accepts_only_host_or_default_shared",
        21,
        0,
        17,
        0.0,
    );
}
#[test]
fn projection_probe_rejects_missing_noop_and_wrong_site() {
    probe_controls();
}
#[test]
fn projection_forward_matches_independent_reference() {
    forward_reference(false);
}
#[test]
fn projection_microbatches_pruning_and_graph_reuse() {
    forward_reference(true);
}
#[test]
fn projection_capture_and_static_additive_composition() {
    composition_reference();
}
#[test]
fn projection_cancel_fault_and_owner_cleanup() {
    ownership_controls();
}
#[test]
#[ignore = "D046 private release feasibility; owner sets F6E_MODEL/F6E_MODEL_SHA256/F6E_SOURCE/F6E_REFERENCE_MANIFEST_SHA256/F6E_BACKEND"]
fn projection_feasibility_model() {
    benchmark();
}

#[test]
#[ignore = "Focused retained native-07 failure diagnosis; owner execution only"]
fn projection_long_prefill_schedule_diagnostic() {
    long_prefill_schedule_diagnostic();
}

include!("projection_test_support.rs");
include!("projection_diagnostic.rs");
