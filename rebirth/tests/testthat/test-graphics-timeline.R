# Every ordinary R CI leg; independent worker-audit and window expectations.
test_that("timeline records applied revisions at the next decode boundary", {
  h <- llm_timeline(graphics_state_fixture())
  h <- llm_timeline(graphics_state_fixture(2, coef = -0.5, revision = 1, after = 1), h)
  h <- llm_timeline(graphics_state_fixture(3, coef = 0, revision = 2, after = 2), h)
  expect_identical(h$state_id, 1:3)
  expect_identical(h$coef, c(0.25, -0.5, 0))
  expect_identical(h$effective_source_pos, c(1L, 4L, 5L))
  expect_identical(h$applied_after_state, c(0L, 1L, 2L))
  expect_null(attr(h, "trace"))
})

test_that("rolling retention drops complete states and reports truncation", {
  h <- llm_timeline(graphics_state_fixture(), max_states = 2)
  h <- llm_timeline(graphics_state_fixture(2), h, max_states = 2)
  h <- llm_timeline(graphics_state_fixture(3), h, max_states = 2)
  expect_identical(h$state_id, 2:3)
  expect_identical(attr(h, "dropped_states"), 1L)
  expect_error(llm_timeline(graphics_state_fixture(3), h), class = "relm_error_trace")
  expect_error(llm_timeline(graphics_state_fixture(5), h), class = "relm_error_trace")
})

test_that("no steering retains one sampled-state row and failures preserve inputs", {
  state <- graphics_state_fixture()
  attr(state, "steering") <- data.frame(intervention = integer(), layer = integer(), coef = double())
  h <- llm_timeline(state)
  expect_equal(nrow(h), 1L)
  expect_true(is.na(h$intervention))
  old <- h
  expect_error(llm_timeline(graphics_state_fixture(2), h), class = "relm_error_trace")
  expect_identical(h, old)
})

test_that("byte bound rolls whole multi-intervention states and preserves source audit", {
  make <- function(i) {
    a <- graphics_state_fixture(i)
    attr(a, "steering") <- data.frame(intervention = 1:8, layer = rep(2L, 8), coef = rep(0.25, 8))
    a
  }
  h <- NULL
  for (i in 1:20) h <- llm_timeline(make(i), h, max_bytes = 200000)
  expect_true(attr(h, "dropped_states") > 0L)
  expect_true(nrow(h) %% 8L == 0L)
  expect_identical(utils::tail(h$state_id, 8L), rep(20L, 8))
  expect_lte(as.numeric(object.size(h)), attr(h, "estimate_bytes"))
  expect_lte(attr(h, "estimate_bytes"), 200000)
})

test_that("same revision cannot change coefficients and next revision must move boundary", {
  h <- llm_timeline(graphics_state_fixture())
  expect_error(llm_timeline(graphics_state_fixture(2, coef = 3), h), class = "relm_error_trace")
  bad <- graphics_state_fixture(2, coef = 3, revision = 1, after = 1)
  bad$step$effective_source_pos <- 3L
  expect_error(llm_timeline(bad, h), class = "relm_error_trace")
  bad <- graphics_state_fixture(2); bad$step$elapsed <- 0
  expect_error(llm_timeline(bad, h), class = "relm_error_trace")
})

test_that("corrupt missing history coordinates produce a classed failure", {
  h <- llm_timeline(graphics_state_fixture())
  for (nm in names(graphics_state_fixture()$step)) {
    bad <- h; bad[[nm]][1] <- NA
    expect_error(llm_timeline(graphics_state_fixture(2), bad), class = "relm_error_trace")
  }
})
