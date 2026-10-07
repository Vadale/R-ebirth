# Every ordinary R CI leg; no model required. Values independently calculated.
test_that("paired values retain identity and exact signed differences", {
  a <- graphics_state_fixture()
  b <- graphics_state_fixture(values = c(1.5, -3, 4, 0), token = 10L)
  x <- llm_compare(a, b, graphics_context_fixture(9L, 10L), layer = 2)
  expect_s3_class(x, "relm_comparison")
  expect_identical(x$neuron, 1:4)
  expect_identical(x$reference, c(1, -2, 3, 0))
  expect_identical(x$difference, c(0.5, -1, 1, 0))
  expect_true(attr(x, "alignment")$matched)
  expect_identical(attr(x, "outputs")$sampled, c(reference = 9L, intervention = 10L))
  expect_identical(a$trace$value, c(1, -2, 3, 0))
})

test_that("all prior token IDs matter but the current sample does not align input", {
  a <- graphics_state_fixture(2, token = 8L)
  b <- graphics_state_fixture(2, values = c(2, -1, 4, 1), token = 8L)
  x <- llm_compare(a, b, graphics_context_fixture(c(9L, 8L), c(10L, 8L)), 2)
  expect_false(attr(x, "alignment")$matched)
  expect_identical(attr(x, "alignment")$first_divergence, 4L)
  expect_true(all(is.na(x$difference)))
  expect_true(all(is.na(attr(x, "outputs")$logits$difference_prob)))
  expect_identical(x$intervention, c(2, -1, 4, 1))
})

test_that("top-k absence is missing rather than zero or an invented KL", {
  a <- graphics_state_fixture(); b <- a
  b$logits$token_id[2] <- 11L
  x <- llm_compare(a, b, graphics_context_fixture(), 2)
  out <- attr(x, "outputs")$logits
  expect_identical(out$token_id, c(9L, 10L, 11L))
  expect_true(is.na(out$intervention_prob[2]))
  expect_true(is.na(out$reference_prob[3]))
  expect_true(is.na(out$difference_prob[2]))
})

test_that("mismatched provenance and coordinates fail before pairing", {
  a <- graphics_state_fixture(); b <- a; ctx <- graphics_context_fixture()
  ctx$intervention$settings$seed <- 2
  expect_error(llm_compare(a, b, ctx, 2), class = "relm_error_argument")
  b$trace$neuron[4] <- 3L
  expect_error(llm_compare(a, b, graphics_context_fixture(), 2), class = "relm_error_trace")
  expect_error(llm_compare(a, a, graphics_context_fixture(), 2, neurons = c(1, 1)),
    class = "relm_error_argument")
  expect_error(llm_compare(a, a, graphics_context_fixture(), 2, max_bytes = 1024),
    class = "relm_error_argument")
})

test_that("metadata cannot retain hidden environments or native owners", {
  ctx <- graphics_context_fixture(); attr(ctx, "hidden") <- new.env()
  expect_error(llm_compare(graphics_state_fixture(), graphics_state_fixture(), ctx, 2), class = "relm_error_argument")
  a <- graphics_state_fixture(); attr(a$step, "hidden") <- new.env()
  expect_error(llm_compare(a, a, graphics_context_fixture(), 2), class = "relm_error_trace")
})

test_that("selected coordinates and materialized budgets are independently checked", {
  a <- graphics_state_fixture(); b <- graphics_state_fixture(values = c(1.5, -3, 4, 0))
  x <- llm_compare(a, b, graphics_context_fixture(), 2, neurons = c(4, 2))
  expect_identical(x$neuron, c(2L, 4L))
  expect_identical(x$difference, c(-1, 0))
  expect_lte(as.numeric(object.size(x)), attr(x, "estimate_bytes"))
  expect_lte(attr(x, "estimate_bytes"), attr(x, "max_bytes"))
  expect_error(llm_compare(a, b, graphics_context_fixture(), 2, max_bytes = 65536), class = "relm_error_oom")
})

test_that("malformed current token, source position and partial captures fail", {
  a <- graphics_state_fixture(); bad <- a
  bad$step$context_pos <- 8L
  expect_error(llm_compare(a, bad, graphics_context_fixture(), 2), class = "relm_error_trace")
  ctx <- graphics_context_fixture(8L, 9L)
  expect_error(llm_compare(a, a, ctx, 2), class = "relm_error_argument")
  bad <- a; bad$trace <- bad$trace[-3, ]
  expect_error(llm_compare(a, bad, graphics_context_fixture(), 2), class = "relm_error_trace")
  bad <- a; bad$trace$value[1] <- Inf
  expect_error(llm_compare(a, bad, graphics_context_fixture(), 2), class = "relm_error_trace")
})

test_that("the last sampled state can exceed consumed context by one", {
  a <- graphics_state_fixture()
  ctx <- graphics_context_fixture()
  ctx$reference$settings$context_length <- 3L
  ctx$intervention$settings$context_length <- 3L
  expect_true(attr(llm_compare(a, a, ctx, 2), "alignment")$matched)
  ctx$reference$settings$context_length <- 2L
  ctx$intervention$settings$context_length <- 2L
  expect_error(llm_compare(a, a, ctx, 2), class = "relm_error_argument")
})

test_that("ragged step, logits and steering frames fail with classed conditions", {
  a <- graphics_state_fixture()
  ragged <- function(x, field, value) {
    attrs <- attributes(x); y <- unclass(x); y[[field]] <- value
    attributes(y) <- attrs; y
  }
  for (value in list(double(), c(0.1, 0.2))) {
    b <- a; b$step <- ragged(b$step, "elapsed", value)
    expect_error(llm_compare(a, b, graphics_context_fixture(), 2), class = "relm_error_trace")
    expect_error(llm_timeline(b), class = "relm_error_trace")
  }
  b <- a; b$step <- ragged(b$step, "token_id", c(9L, 10L))
  expect_error(llm_timeline(b), class = "relm_error_trace")
  b <- a; b$logits <- ragged(b$logits, "token_id", 9L)
  expect_error(llm_compare(a, b, graphics_context_fixture(), 2), class = "relm_error_trace")
  b <- a; attr(b, "steering") <- ragged(attr(b, "steering"), "intervention", c(1L, 2L))
  expect_error(llm_timeline(b), class = "relm_error_trace")
})
