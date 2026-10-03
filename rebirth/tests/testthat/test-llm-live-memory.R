# F6a materialized R64 memory controls: every R CMD check CI leg, no model.
# Literal pool boundaries and real object.size() observations are independent
# of the native/R allocation formula; do not reproduce that formula as a test.

test_that("live vector allocation covers the independently pinned R64 pools", {
  payload <- c(0, 1, 8, 9, 16, 17, 32, 33, 48, 49, 64, 65, 128, 129, 135, 136, 137)
  total <- c(48, 56, 56, 64, 64, 80, 80, 96, 96, 112, 112, 176, 176, 184, 184, 184, 192)
  expect_identical(relm:::live_r_vector_bytes(payload), total)
  observed <- vapply(payload, function(n) as.numeric(object.size(raw(n))), numeric(1))
  expect_identical(observed, total)
  for (bad in list(-1, 0.5, Inf, -Inf, NaN, NA_real_, 2^53 - 8, 2^53,
    "8", TRUE, 1 + 0i)) {
    expect_error(relm:::live_r_vector_bytes(bad), class = "relm_error_argument")
  }
})

live_memory_test_state <- function(hidden, layers, components, top, piece_bytes, m, prompt) {
  n <- hidden * length(layers) * length(components)
  # Distinct top strings prevent CHARSXP interning from hiding vocabulary costs.
  pieces <- if (top) {
    if (piece_bytes < 8) sprintf("%0*d", piece_bytes, seq_len(top)) else
      paste0(strrep("z", piece_bytes - 8L), sprintf("%08d", seq_len(top)))
  } else character()
  if (top) stopifnot(all(nchar(pieces, type = "bytes") == piece_bytes))
  trace <- structure(data.frame(
    prompt_id = rep.int(1L, n), token_pos = rep.int(3L, n),
    token = rep.int(strrep("x", piece_bytes), n),
    layer = rep(layers, each = hidden * length(components)),
    component = rep(rep(components, each = hidden), times = length(layers)),
    neuron = rep(seq_len(hidden), times = length(layers) * length(components)),
    value = rep.int(0.25, n), stringsAsFactors = FALSE),
    class = c("relm_trace", "data.frame"), model = m$path, prompts = prompt,
    spilled = FALSE, position_space = "model_context", prompt_token_count = 3L,
    state_id = 1L)
  state <- list(step = data.frame(state_id = 1L, prompt_id = 1L, token_pos = 1L,
    token_id = 4L, context_pos = 4L, source_pos = 3L, source = "prompt", elapsed = 0.5,
    steering_revision = 0L, applied_after_state = 0L, effective_source_pos = 1L),
    logits = data.frame(prompt_id = rep.int(1L, top), rank = seq_len(top),
      token_id = seq_len(top), token = pieces, logit = rep.int(0.125, top),
      prob = rep.int(0.001, top), stringsAsFactors = FALSE), trace = trace)
  attr(state, "steering") <- relm:::live_steering_table(m$interventions)
  state
}

test_that("live materialized bound covers actual small large and string-heavy states", {
  specs <- list(
    list(hidden = 1L, layers = 1L, components = "residual", top = 1L, piece = 1L,
      steers = 0L),
    list(hidden = 32L, layers = 1:2, components = c("attn_out", "mlp_out", "residual"),
      top = 5L, piece = 8L, steers = 1L),
    list(hidden = 896L, layers = integer(), components = "residual", top = 128L,
      piece = 256L, steers = 17L),
    list(hidden = 4096L, layers = 1:4, components = c("attn_out", "mlp_out", "residual"),
      top = 128L, piece = 256L, steers = 64L))
  for (spec in specs) {
    m <- stub_llm()
    m$hidden_size <- spec$hidden
    m$interventions <- lapply(seq_len(spec$steers), function(i) list(kind = "steer",
      layer = 1L, coef = i / 64, direction = rep.int(0.25, spec$hidden)))
    prompt <- c(input = "Measured memory fixture")
    config <- list(layers = spec$layers, components = spec$components, top = as.double(spec$top),
      budget_bytes = 32 * 1024^2, r_fixed_bytes = 0, spill = TRUE,
      spill_dir = tempdir(), trace_id = "materialized-memory-fixture", model = m$path,
      spec_key = "live-materialized-memory-spec")
    fixed <- relm:::live_fixed_bytes(config, m, prompt)
    bound <- relm:::live_memory_bound(spec$hidden, spec$layers, spec$components,
      spec$top, spec$piece, fixed, steers = spec$steers)
    state <- live_memory_test_state(spec$hidden, spec$layers, spec$components,
      spec$top, spec$piece, m, prompt)
    expect_lte(as.numeric(object.size(state)), bound$materialized_bytes)
    if (spec$top) expect_identical(length(unique(state$logits$token)), spec$top)
    empty_trace <- state
    empty_trace$trace <- relm:::live_empty_trace(m, prompt)
    expect_lte(as.numeric(object.size(empty_trace)), bound$logits_bytes)
    expect_gte(bound$materialized_bytes, bound$logits_bytes)
  }
})

test_that("live allocation rejects fractional nonfinite and overflowing dimensions", {
  base <- list(hidden_size = 32, layers = 1:2, components = "residual",
    top = 5, max_piece_bytes = 8, r_fixed_bytes = 16384)
  for (field in c("hidden_size", "top", "max_piece_bytes", "r_fixed_bytes", "steers")) {
    for (value in list(-1, 0.5, Inf, NA_real_, 1 + 0i)) {
      args <- base
      args[[field]] <- value
      expect_error(do.call(relm:::live_memory_bound, args), class = "relm_error_argument")
    }
  }
  overflow <- base
  overflow$hidden_size <- 2^52
  expect_error(do.call(relm:::live_memory_bound, overflow), class = "relm_error_argument")
  overflow <- base
  overflow$max_piece_bytes <- 2^52
  expect_error(do.call(relm:::live_memory_bound, overflow), class = "relm_error_argument")
})

test_that("native memory disagreement is rejected during live preparation", {
  local_mocked_bindings(rebirth_live_preflight = function(...) list(ok = TRUE,
    max_piece_bytes = 8, materialized_bytes = 1, logits_bytes = 1),
    rebirth_async_ready = function(...) list(ok = TRUE),
    async_generate = function(...) stop("allocation disagreement reached submission"),
    .package = "relm")
  m <- stub_llm()
  live <- list(callback = function(state) invisible(NULL), layers = 1L,
    components = "residual", top = 5L, spill = FALSE, spill_dir = NULL,
    budget_bytes = 32 * 1024^2)
  set.seed(6244)
  before <- .Random.seed
  error <- tryCatch(relm:::live_prepare(live, m, "x", 2L), error = identity)
  expect_s3_class(error, "relm_error_internal")
  expect_identical(error$reason, "live_allocation_invariant")
  expect_identical(.Random.seed, before)
  public_error <- tryCatch(llm_generate(m, "x", async = TRUE,
    on_state = function(state) invisible(NULL), layers = 1L, top = 5L,
    spill = FALSE), error = identity)
  expect_s3_class(public_error, "relm_error_internal")
  expect_identical(public_error$reason, "live_allocation_invariant")
  expect_identical(.Random.seed, before)
})
