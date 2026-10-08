// Private test support for the no_vocab fixture, outside construction/admission.
// The fixed token sequence and vocabulary are never supplied by R.
#[extendr]
fn rebirth_selftest_projection_combined_logits(ptr: Robj) -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        #[cfg(not(feature = "projection-private"))]
        {
            let _ = &ptr;
            Err(RebirthError::Intervention {
                reason: "Projection combined logits selftest is unavailable in this build.".into(),
            })
        }
        #[cfg(feature = "projection-private")]
        {
            let values = {
                let source = checked_handle(&ptr)?;
                source.run(LoadedModel::projection_combined_test_logits)?
            };
            // source.run has released both its model borrow and native guard.
            // Only now allocate R output; the exact-size iterator fills one
            // ordinary double vector directly, with no native f64 copy.
            let logits = Doubles::from_values(values.iter().map(|&x| f64::from(x)));
            Ok(list!(ok = true, logits = logits).into())
        }
    })))
}
