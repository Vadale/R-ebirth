# Standalone relm example. Source this file into a fresh environment, then call
# run_example(). Sourcing performs no installation, download, model load or write.
# See docs/agents.md for prerequisites and the difference between usage checks
# (download-free CI) and successful model execution (explicit local input).
run_example <- function(model_path, expected_sha256) {
  stopifnot(requireNamespace("later", quietly = TRUE),
            requireNamespace("promises", quietly = TRUE))
  stopifnot(is.character(model_path), length(model_path) == 1L,
    file.exists(model_path), !dir.exists(model_path),
    is.character(expected_sha256), length(expected_sha256) == 1L,
    grepl("^[0-9a-f]{64}$", expected_sha256))
  if (!identical(unname(tools::sha256sum(model_path)), expected_sha256))
    stop("Model checksum differs from the independently recorded checksum.")
  m <- relm::llm(model_path, backend = "cpu", context_length = 512L)
  on.exit(close(m), add = TRUE)
  done <- FALSE; failure <- NULL; accepted <- FALSE
  pending <- relm::llm_generate(m, "List instruments used for navigation:",
    async = TRUE, chat = FALSE, max_tokens = 8L, temperature = 0, seed = 16102L,
    top = 5L, layers = integer(),
    on_state = function(state) {
      accepted <<- relm::llm_cancel(m)
      NULL
    })
  observer <- promises::then(pending,
    onFulfilled = function(value) { done <<- TRUE; NULL },
    onRejected = function(e) { failure <<- e; done <<- TRUE; NULL })
  deadline <- proc.time()[["elapsed"]] + 60
  while (!done && proc.time()[["elapsed"]] < deadline) later::run_now(0.05)
  if (!done) {
    relm::llm_cancel(m)
    drain <- proc.time()[["elapsed"]] + 10
    while (!done && proc.time()[["elapsed"]] < drain) later::run_now(0.05)
    stop("Timed out; cancellation is cooperative, not a hard deadline.")
  }
  if (!inherits(failure, "relm_error_cancelled")) {
    if (!is.null(failure)) stop(failure)
    stop("Generation ended before an observed cancellation; no cancellation claim.")
  }
  stopifnot(accepted)
  list(accepted = accepted, condition = class(failure)[1L])
}

# Run by CI: an actual public-API refusal, not a successful model run.
usage_check <- function() {
  condition <- tryCatch(relm::llm_cancel(NULL), error = identity)
  stopifnot(inherits(condition, "relm_error"))
  class(condition)[1L]
}
