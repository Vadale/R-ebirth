# Standalone relm example. Source this file into a fresh environment, then call
# run_example(). Sourcing performs no installation, download, model load or write.
# See docs/agents.md for prerequisites and the difference between usage checks
# (download-free CI) and successful model execution (explicit local input).
run_example <- function() {
  specification <- label ~ relm::activations(layer = 1:2, component = "residual")
  # A formula marker, not a function that extracts an activation matrix.
  condition <- tryCatch(relm::activations(layer = 1:2), error = identity)
  stopifnot(inherits(condition, "relm_error_probe"))
  list(formula = specification, outside_formula = class(condition)[1L])
}
