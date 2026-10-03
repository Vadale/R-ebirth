# F6a admission: every R CMD check CI leg, no model/native worker or download.
# These tests require the implementation under test; do not skip missing helpers.

test_that("live admission rejects malformed requests before native work or RNG", {
  local_mocked_bindings(
    rebirth_async_ready = function(...) stop("live admission reached native readiness"),
    rebirth_tokenize = function(...) stop("live admission tokenized the prompt"),
    .package = "relm")
  m <- stub_llm()
  set.seed(6241)
  before <- .Random.seed
  base <- list(m = m, prompt = "x", async = TRUE,
    on_state = function(state) invisible(NULL))
  invalid <- list(
    list(on_state = TRUE), list(on_state = list()), list(on_state = "callback"),
    list(async = FALSE), list(prompt = c("one", "two")),
    list(max_tokens = 1025), list(schema = '{"type":"string"}'),
    list(images = "unread-live-image.png"),
    list(layers = c(1L, 1L)), list(layers = 0L), list(layers = -1L),
    list(layers = 1.5), list(layers = m$layers + 1L), list(layers = 2^31),
    list(layers = NA_integer_), list(layers = Inf), list(layers = NaN),
    list(layers = TRUE), list(layers = "1"), list(layers = 1 + 0i),
    list(components = character()), list(components = NA_character_),
    list(components = "not_a_component"), list(components = list("residual")),
    list(top = 0L), list(top = -1L), list(top = 129L), list(top = 1.5),
    list(top = c(1L, 2L)), list(top = NA_integer_), list(top = Inf),
    list(top = "5"), list(top = TRUE), list(top = 1 + 0i),
    list(spill = NA), list(spill = c(TRUE, FALSE)), list(spill = 1L),
    list(spill_dir = character()), list(spill_dir = NA_character_),
    list(spill_dir = c("one", "two")), list(spill_dir = 1L))
  for (change in invalid) {
    args <- base
    args[names(change)] <- change
    error <- tryCatch(do.call(llm_generate, args), error = identity)
    expect_s3_class(error, "relm_error_argument")
    expect_identical(.Random.seed, before)
  }
  small <- m
  small$.vocab_size <- 8L
  expect_error(llm_generate(small, "x", async = TRUE, on_state = base$on_state,
    top = 9L), class = "relm_error_argument")
  expect_identical(.Random.seed, before)
})

test_that("nondefault live capture arguments require an observer", {
  local_mocked_bindings(
    rebirth_async_ready = function(...) stop("must reject before readiness"),
    rebirth_tokenize = function(...) stop("must reject before tokenization"),
    .package = "relm")
  m <- stub_llm()
  set.seed(6242)
  before <- .Random.seed
  for (change in list(list(layers = NULL), list(layers = 1L),
    list(components = "mlp_out"), list(top = 0L), list(top = 21L),
    list(spill = FALSE), list(spill_dir = tempdir()))) {
    args <- c(list(m = m, prompt = "x", async = TRUE), change)
    expect_error(do.call(llm_generate, args), class = "relm_error_argument")
    expect_identical(.Random.seed, before)
  }
})

test_that("live admission resolves filters using metadata without context access", {
  local_mocked_bindings(
    rebirth_async_ready = function(...) stop("pure validation reached readiness"),
    rebirth_tokenize = function(...) stop("pure validation reached tokenizer"),
    .package = "relm")
  m <- stub_llm()
  validate <- function(...) {
    args <- list(m = m, prompt = "x", max_tokens = 1024L, async = TRUE,
      on_state = function(state) invisible(NULL), layers = integer(),
      components = "residual", top = 20L, spill = TRUE, spill_dir = NULL,
      schema = NULL, has_images = FALSE)
    change <- list(...)
    args[names(change)] <- change
    do.call(relm:::live_validate_arguments, args)
  }
  expect_null(validate(on_state = NULL))
  logits <- validate()
  expect_identical(logits$layers, integer())
  expect_identical(logits$top, 20L)
  full <- validate(layers = NULL, top = 0L)
  expect_identical(full$layers, seq_len(m$layers))
  selected <- validate(layers = c(3, 1), top = 0,
    components = c("residual", "mlp_out", "residual"))
  expect_setequal(selected$layers, c(1L, 3L))
  expect_type(selected$layers, "integer")
  expect_setequal(selected$components, c("residual", "mlp_out"))
  expect_identical(anyDuplicated(selected$components), 0L)
  expect_identical(selected$top, 0L)
  # A projector-equipped handle with text-only input is explicitly allowed.
  expect_no_error(validate(m = stub_llm(projector = "projector.gguf")))
  expect_error(validate(has_images = TRUE), class = "relm_error_argument")
  expect_error(validate(top = 0L), class = "relm_error_argument")
  old <- options(relm.trace_budget = 64 * 1024^2)
  on.exit(options(old), add = TRUE)
  expect_equal(validate()$budget_bytes, 32 * 1024^2)
  options(relm.trace_budget = 1024)
  expect_equal(validate()$budget_bytes, 1024)
})

test_that("F6a callback replies reserve the protocol by requiring NULL", {
  expect_null(relm:::live_reply(NULL))
  expect_null(relm:::live_reply(invisible(NULL)))
  for (reply in list(FALSE, TRUE, 0L, character(), list(),
    list(steer = data.frame(intervention = 1L, coef = 0)), identity,
    new.env(parent = emptyenv()))) {
    expect_error(relm:::live_reply(reply), class = "relm_error_argument")
  }
  # Dependency availability is mandatory in the ordinary R CI legs; do not turn
  # a missing promises package into a whole-feature skip.
  expect_error(relm:::live_reply(promises::promise_resolve(NULL)),
    class = "relm_error_argument")
})

# Integrated-review P2: normalized live metadata is part of the same 16 MiB
# copied-input/descriptor admission contract as prompt and stop strings.
test_that("public live metadata rejects an already full ordinary input before seed or submit", {
  prompt <- strrep("p", 1024^2)
  stop <- strrep("s", 15 * 1024^2)
  # Control: exactly 16 MiB was legal before adding the four live strings.
  expect_no_error(relm:::async_validate_inputs(prompt, stop, NULL, NULL, 1L, 0, NULL))
  prepared <- submitted <- FALSE
  local_mocked_bindings(
    async_check_dependencies = function() invisible(NULL),
    rebirth_async_ready = function(...) list(ok = TRUE),
    live_prepare = function(live, m, prompt, max_tokens) {
      prepared <<- TRUE
      live$native_config <- list(spill_dir = "/tmp/live-normalized",
        trace_id = "fixed-live-nonce", model = m$path, spec_key = "live-v1|fixed-spec")
      live
    },
    async_generate = function(...) {
      submitted <<- TRUE
      stop("over-budget live input reached submission")
    }, .package = "relm")
  set.seed(6245)
  before <- .Random.seed
  error <- tryCatch(llm_generate(stub_llm(), prompt, stop = stop,
    max_tokens = 1L, temperature = 0, async = TRUE,
    on_state = function(state) invisible(NULL)), error = identity)
  expect_s3_class(error, "relm_error_argument")
  expect_true(prepared)
  expect_false(submitted)
  expect_identical(.Random.seed, before)
})

test_that("four live strings count toward retained input descriptors even when empty", {
  # R/native descriptor contract: 64 bytes per string, 32 per prompt row.
  # The largest representable total sits 32 bytes below the 16 MiB cap;
  # one extra stop descriptor exceeds it by 32 bytes.
  max_stops <- 16 * 1024^2 / 64 - 6L
  validate <- function(n, live_strings) relm:::async_validate_inputs(
    "p", rep.int("", n), NULL, NULL, 1L, 0, NULL, live_strings = live_strings)
  expect_no_error(validate(max_stops, rep.int("", 4L)))
  expect_no_error(validate(max_stops + 4L, character()))
  error <- tryCatch(validate(max_stops + 1L, rep.int("", 4L)), error = identity)
  expect_s3_class(error, "relm_error_argument")
  expect_identical(error$reason, "async_input_storage")
  expect_equal(error$estimate_bytes, 16 * 1024^2 + 32)
  expect_equal(error$limit_bytes, 16 * 1024^2)
})

test_that("the exact complete UTF-8 input boundary includes all four live strings", {
  live_strings <- c("/tmp/live-é", "fixed-live-nonce", "/models/test.gguf", "live-v1|spec")
  prompt <- strrep("p", 1024^2)
  metadata_bytes <- sum(nchar(live_strings, type = "bytes"))
  expect_gt(metadata_bytes, sum(nchar(live_strings)))
  stop <- strrep("s", 16 * 1024^2 - nchar(prompt, type = "bytes") - metadata_bytes)
  expect_equal(nchar(prompt, type = "bytes") + nchar(stop, type = "bytes") + metadata_bytes,
    16 * 1024^2)
  checked <- relm:::async_validate_inputs(prompt, stop, NULL, NULL, 1L, 0, NULL,
    live_strings = live_strings)
  expect_identical(checked$prompt, prompt)
  expect_identical(checked$stop, stop)
  one_byte_over <- live_strings
  one_byte_over[[4L]] <- paste0(one_byte_over[[4L]], "!")
  expect_error(relm:::async_validate_inputs(prompt, stop, NULL, NULL, 1L, 0, NULL,
    live_strings = one_byte_over), class = "relm_error_argument")
})
