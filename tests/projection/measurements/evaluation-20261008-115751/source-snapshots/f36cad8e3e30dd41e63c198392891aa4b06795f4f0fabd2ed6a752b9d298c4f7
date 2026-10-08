// Registered bounded constructor bridge. Combined R/native owner admission has
// passed; fixed harness/fault entrypoints remain private-feature only.
type ProjectionBridgeOuterResult =
    Result<Result<Robj, Box<dyn std::error::Error>>, Box<dyn Any + Send>>;
type ProjectionBridgeInnerResult = std::thread::Result<Result<Robj, RebirthError>>;
fn projection_bridge_frame_bytes() -> u64 {
    use std::mem::size_of;
    // extendr-macros0.9 wrappers.rs: seven SEXP arguments, seven protected Robj
    // locals, seven TryFrom<&Robj> clones passed as our owned arguments; this
    // function's catch_unwind closure borrows those seven arguments. Count the
    // generated wrapper and inner catch result descriptors separately. R vector
    // data is borrowed unchanged; no vector or metadata copy is introduced.
    (size_of::<[extendr_api::SEXP; 7]>()
        + 2 * size_of::<[Robj; 7]>()
        + size_of::<[&Robj; 7]>()
        + size_of::<ProjectionBridgeOuterResult>()
        + size_of::<ProjectionBridgeInnerResult>()) as u64
}
#[extendr]
fn rebirth_projection_construct(
    ptr: Robj,
    config: Robj,
    steer_layers: Robj,
    steer_vectors: Robj,
    ablate_layers: Robj,
    ablate_neurons: Robj,
    ablate_values: Robj,
) -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        projection_construct_boundary(
            &ptr,
            &config,
            [
                &steer_layers,
                &steer_vectors,
                &ablate_layers,
                &ablate_neurons,
                &ablate_values,
            ],
            false,
        )
    })))
}
