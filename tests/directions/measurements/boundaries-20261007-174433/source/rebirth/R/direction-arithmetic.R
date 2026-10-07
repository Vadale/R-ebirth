# Independent reference and guards were frozen in golden commit e80166e.
direction_norm <- function(x) {
  scale <- max(abs(x))
  result <- if (scale == 0) 0 else scale * sqrt(sum((x / scale)^2))
  if (!is.finite(result)) {
    direction_fail("nonfinite_norm", "A direction norm is not representable. Rescale the supplied activations explicitly.")
  }
  result
}

direction_arithmetic <- function(target, control, normalize_pairs, orthogonalize, estimate, context) {
  n <- nrow(target); h <- ncol(target); guard <- 64 * .Machine$double.eps
  mean_difference <- double(h); mean_control <- double(h)
  norms <- data.frame(pair_id = rownames(target), target_norm = double(n),
    control_norm = double(n), difference_norm = double(n), used_norm = double(n))
  for (i in seq_len(n)) {
    t <- target[i, ]; c <- control[i, ]
    if (anyNA(t) || anyNA(c) || any(!is.finite(t)) || any(!is.finite(c))) {
      relm_abort("relm_error_argument", "Every activation must be finite; no pair is silently dropped.",
        list(argument = "target/control", reason = "nonfinite_input", pair_id = rownames(target)[i]))
    }
    d <- t - c
    if (any(!is.finite(d))) {
      direction_fail("nonfinite_difference", "A pair difference overflowed. Rescale the supplied activations explicitly.", pair_id = rownames(target)[i])
    }
    tn <- direction_norm(t); cn <- direction_norm(c); dn <- direction_norm(d)
    if (dn == 0 || dn <= guard * max(tn, cn)) {
      direction_fail("degenerate_pair", "A target-control pair has no stable direction. Revise the construction corpus.", pair_id = rownames(target)[i])
    }
    if (normalize_pairs) d <- d / dn
    un <- if (normalize_pairs) direction_norm(d) else dn
    norms[i, -1L] <- c(tn, cn, dn, un)
    mean_difference <- mean_difference + d / n
    mean_control <- mean_control + c / n
    if (any(!is.finite(mean_difference)) || any(!is.finite(mean_control))) {
      direction_fail("nonfinite_mean", "A direction mean overflowed. Rescale the supplied activations explicitly.")
    }
    # Simultaneous materialized objects plus reserved row-operation temporaries.
    direction_stage(estimate, target, control, context, norms, t, c, d,
      mean_difference, mean_control, double(8L * h), raw(4096L))
  }
  mp <- sum(norms$used_norm / n); mc <- sum(norms$control_norm / n)
  before <- direction_norm(mean_difference); control_norm <- direction_norm(mean_control)
  if (before == 0 || before <= guard * mp) {
    direction_fail("degenerate_mean", "Pair differences cancel to an unstable mean. Revise the construction corpus.")
  }
  if (orthogonalize) {
    if (control_norm == 0 || control_norm <= guard * mc) {
      direction_fail("degenerate_control_mean", "The original control mean is unstable; it cannot define a projection.")
    }
    u <- mean_control / control_norm
    mean_difference <- mean_difference - u * sum(u * mean_difference)
    if (any(!is.finite(mean_difference))) direction_fail("nonfinite_projection", "Control-mean projection overflowed.")
  }
  after <- direction_norm(mean_difference)
  if (after == 0 || after <= guard * before) {
    direction_fail("degenerate_projection", "Orthogonalization leaves no stable direction. Revise the corpus or disable orthogonalization.")
  }
  value <- unname(mean_difference / after)
  diagnostics <- list(guard_relative = guard, pairs = norms, mean_pair_norm = mp,
    control_mean_norm = control_norm, mean_control_norm = mc,
    pre_projection_norm = before, post_projection_norm = after, final_norm = direction_norm(value))
  direction_stage(estimate, target, control, context, norms, t, c, d,
    mean_difference, mean_control, value, diagnostics, double(8L * h), raw(4096L))
  list(value = value, diagnostics = diagnostics)
}
