# F6d model-free fixtures; ordinary Mac/Linux R checks, no inference.
direction_test_fixture <- function(n = 3L, h = 4L) {
  ids <- paste0("pair-", seq_len(n))
  control <- matrix(rep(c(1, 2, -1, 0.5), length.out = n * h), n, h,
    dimnames = list(ids, as.character(seq_len(h))))
  target <- control + matrix(rep(c(2, -1, 0.25, 3, 1, 2), length.out = n * h), n, h)
  hashes <- sprintf("%064x", seq_len(2L * n + 2L))
  context <- list(
    model = list(sha256 = paste(rep("a", 64), collapse = ""), architecture = "qwen2",
      quantization = "Q8_0", hidden_size = as.integer(h), layers = 24L,
      engine_revision = "synthetic-test-record"),
    capture = list(component = "residual", positions = "last", input_format = "raw_text",
      tokenizer = "gguf_embedded", add_special = TRUE, parse_special = FALSE,
      template_sha256 = NULL, context_length = 512L, backend = "cpu", relm_version = "0.3.0"),
    pairs = data.frame(pair_id = ids, target_sha256 = hashes[seq_len(n)],
      control_sha256 = hashes[n + seq_len(n)], target_pos = rep(3L, n), control_pos = rep(4L, n)),
    splits = data.frame(prompt_sha256 = hashes,
      split = c(rep("construction", 2L * n), "selection", "evaluation")),
    seed = NULL)
  list(target = target, control = control, context = context)
}

direction_test_build <- function(x = direction_test_fixture(), ...) {
  llm_direction(x$target, x$control, x$context, layer = 2L, ...)
}

direction_test_handle <- function(record) {
  state <- new.env(parent = emptyenv()); state$closed <- FALSE
  structure(c(record[c("architecture", "quantization", "hidden_size", "layers")],
    list(state = state, ptr = NULL, interventions = list())), class = "llm")
}
