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
