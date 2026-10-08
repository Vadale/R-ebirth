# Synthetic, independently specified observations for download-free examples.
# These editable records illustrate the schema; they are not measured model data.
example_state <- function(k = 1L, values = c(1, -2, 3, 0), coefficient = 0.25,
                          revision = 0L, after = 0L) {
  trace <- data.frame(prompt_id = 1L, token_pos = k + 2L, token = "x", layer = 2L,
    component = "residual", neuron = seq_along(values), value = as.double(values))
  trace <- structure(trace, class = c("relm_trace", "data.frame"), model = "synthetic.gguf",
    prompts = "Synthetic prompt", spilled = FALSE, position_space = "model_context",
    prompt_token_count = 3L, state_id = k)
  step <- data.frame(state_id = k, prompt_id = 1L, token_pos = k, token_id = 9L,
    context_pos = k + 3L, source_pos = k + 2L, source = if (k == 1L) "prompt" else "generated",
    elapsed = k / 10, steering_revision = revision, applied_after_state = after,
    effective_source_pos = if (revision == 0L) 1L else 3L + after)
  logits <- data.frame(prompt_id = 1L, rank = 1:2, token_id = c(9L, 10L),
    token = c("a", "b"), logit = c(2, 1), prob = c(0.5, 0.2))
  structure(list(step = step, logits = logits, trace = trace),
    steering = data.frame(intervention = 1L, layer = 2L, coef = as.double(coefficient)))
}
reference <- example_state()
intervention <- example_state(values = c(1.5, -3, 4, 0))
settings <- list(seed = 1, chat = FALSE, temperature = 0, top_p = 0.95,
  max_tokens = 8L, stop = NULL, context_length = 512L, backend = "cpu",
  relm_version = "synthetic-example", engine_revision = "synthetic-example")
record <- list(model_sha256 = strrep("0", 64), settings = settings, generated_tokens = 9L)
context <- list(reference = record, intervention = record)
