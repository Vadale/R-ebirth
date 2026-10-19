# Standalone relm example. Source this file into a fresh environment, then call
# run_example(). Sourcing performs no installation, download, model load or write.
# See docs/agents.md for prerequisites and the difference between usage checks
# (download-free CI) and successful model execution (explicit local input).
# A fresh, bounded construction and application example. Selection/evaluation
# texts are reserved but NOT evaluated here. This is not an efficacy experiment.
run_example <- function(model_path, expected_sha256, engine_revision) {
  stopifnot(is.character(engine_revision), length(engine_revision) == 1L,
            nzchar(engine_revision))
  stopifnot(is.character(model_path), length(model_path) == 1L,
    file.exists(model_path), !dir.exists(model_path),
    is.character(expected_sha256), length(expected_sha256) == 1L,
    grepl("^[0-9a-f]{64}$", expected_sha256))
  if (!identical(unname(tools::sha256sum(model_path)), expected_sha256))
    stop("Model checksum differs from the independently recorded checksum.")
  m <- relm::llm(model_path, backend = "cpu", context_length = 512L)
  on.exit(close(m), add = TRUE)
  model_record <- list(sha256 = expected_sha256, architecture = m$architecture,
    quantization = m$quantization, hidden_size = as.integer(m$hidden_size),
    layers = as.integer(m$layers), engine_revision = engine_revision)
  texts <- c("Describe how a compass works briefly.",
             "Describe how a compass works in detail.",
             "Describe how a barometer works briefly.",
             "Describe how a barometer works in detail.",
             "Describe a measuring tape.", "Describe a weighing scale.")
  hash_text <- function(x) {
    p <- tempfile(); on.exit(unlink(p), add = TRUE)
    writeBin(charToRaw(enc2utf8(x)), p); unname(tools::sha256sum(p))
  }
  hashes <- vapply(texts, hash_text, character(1))
  observations <- lapply(texts[1:4], function(x) relm::llm_trace(m, x,
    layers = 2L, positions = "last", components = "residual", spill = FALSE))
  target <- rbind(as.matrix(observations[[1L]], layer = 2L),
                  as.matrix(observations[[3L]], layer = 2L))
  control <- rbind(as.matrix(observations[[2L]], layer = 2L),
                   as.matrix(observations[[4L]], layer = 2L))
  dimnames(target) <- dimnames(control) <- list(c("compass", "barometer"),
                                             as.character(seq_len(m$hidden_size)))
  context <- list(model = model_record,
    capture = list(component = "residual", positions = "last",
      input_format = "raw_text", tokenizer = "gguf_embedded", add_special = TRUE,
      parse_special = FALSE, template_sha256 = NULL, context_length = 512L,
      backend = "cpu", relm_version = as.character(utils::packageVersion("relm"))),
    pairs = data.frame(pair_id = c("compass", "barometer"),
      target_sha256 = hashes[c(1L, 3L)], control_sha256 = hashes[c(2L, 4L)],
      target_pos = vapply(observations[c(1L, 3L)], function(x) unique(x$token_pos), integer(1)),
      control_pos = vapply(observations[c(2L, 4L)], function(x) unique(x$token_pos), integer(1))),
    splits = data.frame(prompt_sha256 = hashes,
      split = c(rep("construction", 4L), "selection", "evaluation")), seed = NULL)
  direction <- relm::llm_direction(target, control, context, layer = 2L)
  edited <- relm::llm_apply_direction(m, direction, model_record, coef = 0)
  on.exit(close(edited), add = TRUE)
  list(direction = direction, model = summary(edited))
  # The caller records the real engine revision. It is not inferred from weights.
}

# Run by CI: an actual public-API refusal, not a successful model run.
usage_check <- function() {
  condition <- tryCatch(relm::llm_apply_direction(NULL, NULL, NULL), error = identity)
  stopifnot(inherits(condition, "relm_error"))
  class(condition)[1L]
}
