# Rendering smoke/parameter ownership in ordinary R CI. Image readability is a
# separately recorded visual acceptance; a device opening is not that proof.
test_that("model map is metadata-only with explicit supported and generic detail", {
  path <- tempfile(fileext = ".pdf"); grDevices::pdf(path, width = 10, height = 7)
  on.exit({ grDevices::dev.off(); unlink(path) })
  m <- stub_llm(interventions = list(list(kind = "steer", layer = 2L), list(kind = "ablate", layer = 2L)))
  before <- graphics::par(no.readonly = TRUE)
  d <- plot.llm(m, layers = c(1, 2, 5))
  expect_identical(d$layer, rep(c(1L, 2L, 5L), each = 3))
  expect_equal(sum(d$configured_steers), 1L)
  expect_true(grepl("unavailable", d$detail[1]))
  expect_identical(graphics::par(no.readonly = TRUE), before)
  m$architecture <- "unverified"
  generic <- plot.llm(m, layers = 2:3)
  expect_identical(generic$site, rep("block", 2))
  expect_error(plot.llm(m, bad_option = TRUE), class = "relm_error_argument")
  expect_error(plot.llm(m, layers = c(1, 1)), class = "relm_error_argument")
  m$state$closed <- TRUE
  expect_error(plot.llm(m), class = "relm_error_closed")
})

test_that("comparison and timeline restore graphics state and return plotted data", {
  path <- tempfile(fileext = ".pdf"); grDevices::pdf(path, width = 10, height = 7)
  on.exit({ grDevices::dev.off(); unlink(path) })
  a <- graphics_state_fixture(); x <- llm_compare(a, a, graphics_context_fixture(), 2)
  h <- llm_timeline(a)
  before <- graphics::par(no.readonly = TRUE)
  expect_identical(plot.relm_comparison(x, main = "Controlled example"), x)
  expect_identical(graphics::par(no.readonly = TRUE), before)
  expect_identical(plot.relm_timeline(h), h)
  expect_identical(graphics::par(no.readonly = TRUE), before)
  expect_error(plot.relm_comparison(x, col = "not a color"), class = "relm_error_argument")
  expect_identical(graphics::par(no.readonly = TRUE), before)
})

test_that("truncation preserves change timing without inventing a visible event", {
  h <- llm_timeline(graphics_state_fixture(), max_states = 2)
  for (i in 2:4) h <- llm_timeline(graphics_state_fixture(i, coef = -0.5,
    revision = 1, after = 1), h, max_states = 2)
  expect_identical(h$state_id, 3:4)
  expect_identical(h$applied_after_state, c(1L, 1L))
  expect_identical(graphics_change_states(h), integer())
  h <- llm_timeline(graphics_state_fixture(5, coef = 0, revision = 2, after = 4), h, max_states = 2)
  expect_identical(graphics_change_states(h), 5L)
})

test_that("a middle block selection labels both omitted boundary ranges", {
  recorded <- character(); original <- graphics::text
  local_mocked_bindings(text = function(x, y, labels, ...) {
    labels_seen <- as.character(labels)
    recorded <<- c(recorded, labels_seen)
    original(x, y, labels_seen, ...)
  }, .package = "graphics")
  path <- tempfile(fileext = ".pdf"); on.exit(unlink(path))
  grDevices::pdf(path, width = 10, height = 7)
  tryCatch(plot.llm(stub_llm(), layers = 5:6), finally = grDevices::dev.off())
  expect_true("... blocks 1-4 omitted" %in% recorded)
  expect_true("... blocks 7-24 omitted" %in% recorded)
})
