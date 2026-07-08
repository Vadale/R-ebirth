#' Raise a classed rebirth condition
#'
#' The single place the package turns a `(class, message, fields)` decision into
#' an R error. The `rebirth-ffi` boundary decides the class and structured
#' fields; this helper does the actual `stop()`, so condition raising stays in R
#' (ARCHITECTURE.md sections 2 and 8). Every rebirth error inherits
#' `c(<specific>, "rebirth_error", "error", "condition")` (API-GRAMMAR.md
#' section 1.8) and carries its structured fields as list elements for
#' programmatic handling.
#'
#' @param class Character scalar: the specific leaf class, e.g.
#'   `"rebirth_error_model_load"`.
#' @param message Character scalar: an actionable message (what happened ->
#'   likely cause -> what to try).
#' @param fields Named list of structured fields to attach to the condition.
#' @param call The call to record; defaults to the caller's caller.
#' @return Never returns; always raises.
#' @keywords internal
#' @noRd
rebirth_abort <- function(class, message, fields = list(), call = sys.call(-1L)) {
  cond <- structure(
    c(list(message = message, call = call), fields),
    class = c(class, "rebirth_error", "error", "condition")
  )
  stop(cond)
}

#' Raise a `rebirth_error_argument` for a specific argument
#'
#' A thin specialization of [rebirth_abort()] for the common case of an invalid
#' function argument: it fixes the class to `"rebirth_error_argument"` and
#' attaches the offending argument's name as the structured `argument` field, so
#' each call site states only its argument name and its specific message.
#'
#' @param argument Character scalar: the name of the offending argument (carried
#'   as the condition's `argument` field).
#' @param message Character scalar: the specific, actionable message.
#' @param call The call to record; defaults to the caller's caller, so the
#'   condition points at the user-facing function rather than at this helper.
#' @return Never returns; always raises.
#' @keywords internal
#' @noRd
abort_argument <- function(argument, message, call = sys.call(-1L)) {
  rebirth_abort(
    "rebirth_error_argument", message, list(argument = argument),
    call = call
  )
}

#' Raise a `rebirth_error_intervention` for a failed steer/ablate validation
#'
#' A thin specialization of [rebirth_abort()] fixing the class to
#' `"rebirth_error_intervention"` (API-GRAMMAR.md section 6: dimension/layer
#' validation for `llm_steer()`/`llm_ablate()`). The intervention-domain checks
#' (unsupported architecture, out-of-range layer, the layer-1 steer limit,
#' `direction`/`neurons`/`coef`/`value` shape, position/component restrictions)
#' all funnel through here; each call site attaches the offending argument name
#' as the structured `argument` field where one is at fault.
#'
#' @param message Character scalar: the specific, actionable message.
#' @param fields Named list of structured fields to attach (e.g.
#'   `list(argument = "layer")`).
#' @param call The call to record; defaults to the caller's caller, so the
#'   condition points at the user-facing function rather than at this helper.
#' @return Never returns; always raises.
#' @keywords internal
#' @noRd
abort_intervention <- function(message, fields = list(), call = sys.call(-1L)) {
  rebirth_abort("rebirth_error_intervention", message, fields, call = call)
}

#' Raise a `rebirth_error_download` for a failed model download
#'
#' A thin specialization of [rebirth_abort()] fixing the class to
#' `"rebirth_error_download"` (API-GRAMMAR.md section 6: checksum failures are
#' fail-closed). The download-domain rejections (a non-HTTPS URL, an unknown
#' registry alias, a network failure, a SHA256 mismatch, an unwritable cache
#' directory) all funnel through here; a checksum mismatch attaches the
#' structured `expected`/`actual`/`url` fields so callers can react
#' programmatically. Pure argument-type violations stay
#' `rebirth_error_argument` — this class is for a download that cannot proceed
#' or did not verify.
#'
#' @param message Character scalar: the specific, actionable message.
#' @param fields Named list of structured fields to attach (e.g.
#'   `list(expected = ..., actual = ..., url = ...)`).
#' @param call The call to record; defaults to the caller's caller, so the
#'   condition points at the user-facing function rather than at this helper.
#' @return Never returns; always raises.
#' @keywords internal
#' @noRd
abort_download <- function(message, fields = list(), call = sys.call(-1L)) {
  rebirth_abort("rebirth_error_download", message, fields, call = call)
}

#' Raise from an FFI payload, or return it unchanged on success
#'
#' Boundary functions return a list payload. On failure (`ok == FALSE`) this
#' raises the classed condition the payload describes; on success it returns the
#' payload so the caller can build its result.
#'
#' @param payload A list with at least `ok`; on failure also `class`, `message`,
#'   and `fields`.
#' @return The payload (invisibly-usable) when `ok` is `TRUE`.
#' @keywords internal
#' @noRd
rebirth_check <- function(payload, call = sys.call(-1L)) {
  if (isFALSE(payload$ok)) {
    fields <- payload$fields
    if (is.null(fields)) fields <- list()
    rebirth_abort(payload$class, payload$message, fields, call = call)
  }
  payload
}
