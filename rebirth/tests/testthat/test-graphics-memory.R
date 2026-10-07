# Independent simultaneous-object prototypes, every ordinary R CI leg.
# These are not process RSS or arbitrary hostile IPC decoder memory bounds.
test_that("comparison ledger exceeds materialized simultaneous base-R shapes", {
  for (n in c(1L, 16L, 4096L, 65536L)) {
    ids <- seq_len(n); a <- rep(0.5, n); b <- rep(-1, n)
    frame <- data.frame(layer = rep(2L, n), component = rep("residual", n), neuron = ids,
      reference = a, intervention = b, difference = b - a)
    # Deliberately count shared vectors repeatedly. Include independent slices,
    # result/assembly copies and index/sort/match/coverage workspaces.
    objects <- list(a, b, a, b, frame, frame, frame, ids, ids, ids, ids,
      logical(n), logical(n), double(n), double(n), integer(n), integer(n))
    actual <- sum(vapply(objects, function(x) as.numeric(object.size(x)), numeric(1)))
    expect_lte(actual, 32768 + 2048 * n)
  }
})

test_that("timeline ledger exceeds expanded history and replacement shapes", {
  for (n in c(1L, 8L, 256L, 4096L)) {
    step <- graphics_state_fixture()$step
    frame <- step[rep(1L, n), , drop = FALSE]
    frame$intervention <- rep(1L, n); frame$layer <- rep(2L, n); frame$coef <- rep(0.25, n)
    objects <- list(frame, frame, frame, frame, seq_len(n), seq_len(n), logical(n), double(n))
    actual <- sum(vapply(objects, function(x) as.numeric(object.size(x)), numeric(1)))
    expect_lte(actual, 32768 + 2048 * n)
  }
})

test_that("wide selected vectors refuse before materialization under small budgets", {
  a <- graphics_state_fixture(values = rep(0, 8192))
  expect_error(llm_compare(a, a, graphics_context_fixture(), 2, neurons = 1, max_bytes = 1024^2), class = "relm_error_oom")
  h <- llm_timeline(graphics_state_fixture())
  huge <- graphics_state_fixture(2)
  attr(huge, "steering") <- data.frame(intervention = 1:1000, layer = rep(2L, 1000), coef = rep(0, 1000))
  before <- h
  expect_error(llm_timeline(huge, h, max_bytes = 65536), class = "relm_error_oom")
  expect_identical(h, before)
})
