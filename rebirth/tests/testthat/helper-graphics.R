# Small independently specified observations for all ordinary R CI legs.
graphics_state_fixture <- function(id = 1L, values = c(1, -2, 3, 0),
                                   token = 9L, coef = 0.25,
                                   revision = 0L, after = 0L) {
  id <- as.integer(id)
  tr <- data.frame(prompt_id = 1L, token_pos = id + 2L, token = "x",
    layer = 2L, component = "residual", neuron = seq_along(values), value = values)
  tr <- structure(tr, class = c("relm_trace", "data.frame"), model = "/fixture.gguf",
    prompts = "A small prompt", spilled = FALSE, position_space = "model_context",
    prompt_token_count = 3L, state_id = id)
  step <- data.frame(state_id = id, prompt_id = 1L, token_pos = id,
    token_id = as.integer(token), context_pos = id + 3L, source_pos = id + 2L,
    source = if (id == 1L) "prompt" else "generated", elapsed = id / 10,
    steering_revision = as.integer(revision), applied_after_state = as.integer(after),
    effective_source_pos = if (revision == 0L) 1L else as.integer(after + 3L))
  logits <- data.frame(prompt_id = 1L, rank = 1:2, token_id = c(9L, 10L),
    token = c("a", "b"), logit = c(2, 1), prob = c(0.5, 0.2))
  structure(list(step = step, logits = logits, trace = tr),
    steering = data.frame(intervention = 1L, layer = 2L, coef = as.double(coef)))
}

graphics_context_fixture <- function(a = 9L, b = 9L) {
  one <- function(tokens) list(model_sha256 = paste(rep("a", 64L), collapse = ""),
    settings = list(seed = 1, chat = FALSE, temperature = 0, top_p = 0.95,
      max_tokens = 8L, stop = NULL, context_length = 512L, backend = "cpu",
      relm_version = "0.3.0", engine_revision = "b10828-patched"),
    generated_tokens = as.integer(tokens))
  list(reference = one(a), intervention = one(b))
}
