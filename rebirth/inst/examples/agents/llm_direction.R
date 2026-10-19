# Standalone relm example. Source this file into a fresh environment, then call
# run_example(). Sourcing performs no installation, download, model load or write.
# See docs/agents.md for prerequisites and the difference between usage checks
# (download-free CI) and successful model execution (explicit local input).
# Synthetic coordinates and provenance labels, not observations from a model.
run_example <- function() {
  control <- rbind(c(1, 0, 2, 0), c(0, 2, 1, 0))
  target <- control + rbind(c(2, 1, 0, 0), c(0, 3, 0, 0))
  dimnames(target) <- dimnames(control) <- list(c("north", "south"), as.character(1:4))
  hashes <- sprintf("%064x", 11:16)
  context <- list(
    model = list(sha256 = strrep("a", 64), architecture = "synthetic",
      quantization = "synthetic", hidden_size = 4L, layers = 3L,
      engine_revision = "synthetic-schema-example"),
    capture = list(component = "residual", positions = "last",
      input_format = "raw_text", tokenizer = "gguf_embedded", add_special = TRUE,
      parse_special = FALSE, template_sha256 = NULL, context_length = 128L,
      backend = "cpu", relm_version = as.character(utils::packageVersion("relm"))),
    pairs = data.frame(pair_id = rownames(target), target_sha256 = hashes[1:2],
      control_sha256 = hashes[3:4], target_pos = c(3L, 4L), control_pos = c(4L, 3L)),
    splits = data.frame(prompt_sha256 = hashes,
      split = c(rep("construction", 4), "selection", "evaluation")), seed = NULL)
  direction <- relm::llm_direction(target, control, context, layer = 2L)
  stopifnot(max(abs(direction$value - c(1, 2, 0, 0) / sqrt(5))) < 1e-12)
  print(direction)
  direction
}
