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
  edited <- relm::llm_ablate(m, layer = 2L, neurons = 1L, value = 0)
  on.exit(close(edited), add = TRUE)
  summary(edited) # Residual ablation, after steering; no weight edit.
}

# Run by CI: an actual public-API refusal, not a successful model run.
usage_check <- function() {
  condition <- tryCatch(relm::llm_ablate(NULL, 2L, 1L), error = identity)
  stopifnot(inherits(condition, "relm_error"))
  class(condition)[1L]
}
