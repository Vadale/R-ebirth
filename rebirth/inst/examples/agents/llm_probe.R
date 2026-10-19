# Standalone relm example. Source this file into a fresh environment, then call
# run_example(). Sourcing performs no installation, download, model load or write.
# See docs/agents.md for prerequisites and the difference between usage checks
# (download-free CI) and successful model execution (explicit local input).
# Entirely synthetic data: API demonstration, not model-quality evidence.
run_example <- function() {
  stopifnot(requireNamespace("glmnet", quietly = TRUE))
  label <- rep(0:1, 18)
  trace <- expand.grid(neuron = 1:3, layer = 1:2, prompt_id = seq_along(label))
  trace$token_pos <- 1L; trace$token <- "synthetic"; trace$component <- "residual"
  trace$value <- cos(trace$prompt_id * trace$neuron) + label[trace$prompt_id]
  class(trace) <- c("relm_trace", "data.frame")
  groups <- paste0("document-", seq_along(label))
  fit <- relm::llm_probe(label ~ relm::activations(layer = 1:2), trace,
    groups = groups, test_groups = tail(groups, 12), cv = 3L, seed = 16103L)
  predicted <- predict(fit, trace)
  stopifnot(length(predicted) == length(label), all(is.finite(predicted)))
  list(summary = summary(fit), predictions = predicted)
  # Fewer than 20 held-out groups: intervals are withheld with a reason.
}
