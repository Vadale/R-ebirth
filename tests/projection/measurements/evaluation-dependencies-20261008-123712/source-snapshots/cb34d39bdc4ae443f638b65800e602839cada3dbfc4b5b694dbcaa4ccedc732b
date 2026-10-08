//! Fixed no-vocabulary fixture adapter for the private R-hosted constructor gate.
//! This module is absent from ordinary builds and is not a general token API.

use crate::{LoadedModel, NativeGuard, RebirthError};

fn check_fixture_shape(h: i32, d: i32, vocab: i32, context: u32) -> Result<(), RebirthError> {
    if h != 32 || d != 3 || vocab != 48 || context < 3 {
        return Err(RebirthError::Intervention {
            reason: "Projection combined logits selftest requires H32/D3/vocab48/context>=3."
                .into(),
        });
    }
    Ok(())
}

impl LoadedModel {
    /// Private harness only: read the fixed synthetic fixture's final logit row.
    /// Scalar shape checks allocate no metadata and precede the unchanged raw
    /// prompt path, including its normal KV reset and existing projection hook.
    #[doc(hidden)]
    pub fn projection_combined_test_logits(&self) -> Result<Vec<f32>, RebirthError> {
        let _native = NativeGuard::try_acquire("projection combined logits selftest")?;
        check_fixture_shape(
            self.hidden_size(),
            self.num_layers(),
            self.n_vocab(),
            self.context_length(),
        )?;
        self.prompt_last_logits(&[1, 7, 13], 48)
    }
}

#[cfg(test)]
mod tests {
    use super::check_fixture_shape;

    #[test]
    fn fixed_fixture_shape() {
        assert!(check_fixture_shape(32, 3, 48, 3).is_ok());
        assert!(check_fixture_shape(32, 3, 48, 768).is_ok());
        for (h, d, vocab, context) in [
            (31, 3, 48, 3),
            (32, 2, 48, 3),
            (32, 3, 47, 3),
            (32, 3, 48, 2),
        ] {
            let error = check_fixture_shape(h, d, vocab, context).unwrap_err();
            assert_eq!(error.class(), "relm_error_intervention");
        }
        println!("F6E_PROJECTION_COMBINED_TOKEN_TEST {{\"test\":\"fixed_fixture_shape\",\"status\":\"passed\",\"expected_cases\":6,\"executed_cases\":6,\"expected_rejections\":4,\"rejected_cases\":4,\"model_count\":0}}");
    }
}
