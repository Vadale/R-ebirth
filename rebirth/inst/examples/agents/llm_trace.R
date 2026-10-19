# Standalone relm example. Source this file into a fresh environment, then call
# run_example(). Sourcing performs no installation, download, model load or write.
# See docs/agents.md for prerequisites and the difference between usage checks
# (download-free CI) and successful model execution (explicit local input).
run_example <- function(model_path, expected_sha256) {
  stopifnot(is.character(model_path), length(model_path) == 1L,
    file.exists(model_path), !dir.exists(model_path),
    is.character(expected_sha256), length(expected_sha256) == 1L,
    grepl("^[0-9a-f]{64}$", expected_sha256))
  if (!identical(unname(tools::sha256sum(model_path)), expected_sha256))
    stop("Model checksum differs from the independently recorded checksum.")
  m <- relm::llm(model_path, backend = "cpu", context_length = 512L)
  on.exit(close(m), add = TRUE)
  captured <- relm::llm_trace(m, "A sundial uses a shadow.", layers = 2L,
    positions = "last", components = "residual", spill = FALSE)
  values <- as.matrix(captured, layer = 2L)
  stopifnot(is.matrix(values), nrow(values) == 1L)
  list(trace = captured, matrix = values)
  # This observes the prompt pass, not tokens from a generated answer.
}

# Run by CI: an actual public-API refusal, not a successful model run.
usage_check <- function() {
  condition <- tryCatch(relm::llm_trace(NULL, "text", layers = 2L), error = identity)
  stopifnot(inherits(condition, "relm_error"))
  class(condition)[1L]
}
