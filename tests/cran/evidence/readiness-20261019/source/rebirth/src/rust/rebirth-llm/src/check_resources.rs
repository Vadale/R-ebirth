//! Honor R's check resource budget at every owned context boundary.
//!
//! This is deliberately read when a context is created, not cached globally.
//! Ordinary R/native/CUDA sessions keep the upstream thread configuration.

pub(crate) fn threads(requested: i32) -> i32 {
    limited_threads(
        requested,
        std::env::var("_R_CHECK_LIMIT_CORES_").ok().as_deref(),
    )
}

fn limited_threads(requested: i32, check: Option<&str>) -> i32 {
    let limited = check.is_some_and(|value| {
        !value.is_empty() && !matches!(value.to_ascii_lowercase().as_str(), "false" | "f" | "0")
    });
    if limited {
        requested.clamp(1, 2)
    } else {
        requested
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_budget_caps_defaults_and_automatic_values_without_changing_normal_sessions() {
        let active = std::env::var("_R_CHECK_LIMIT_CORES_").ok();
        assert_eq!(threads(4), limited_threads(4, active.as_deref()));
        for value in [
            None,
            Some(""),
            Some("FALSE"),
            Some("false"),
            Some("F"),
            Some("0"),
        ] {
            for count in [-1, 0, 1, 2, 4, 16] {
                assert_eq!(limited_threads(count, value), count);
            }
        }
        for value in ["TRUE", "true", "T", "1", "warn"] {
            for (count, expected) in [(-1, 1), (0, 1), (1, 1), (2, 2), (4, 2), (16, 2)] {
                assert_eq!(limited_threads(count, Some(value)), expected);
            }
        }
    }
}
