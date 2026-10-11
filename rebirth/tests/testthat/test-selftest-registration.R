# Both production and explicit selftest builds run this gate in ordinary R CI.
test_that("native fixture registration matches the requested build mode", {
  registered <- sort(relm_selftest_registered())
  expected <- if (identical(Sys.getenv("RELM_ENABLE_SELFTESTS"), "1")) {
    sort(relm_selftest_names)
  } else character()
  expect_identical(registered, expected)
})

test_that("a required missing native fixture fails instead of skipping", {
  require_fixture <- require_relm_selftest
  environment(require_fixture) <- list2env(list(
    relm_selftest_registered = function() character(),
    Sys.getenv = function(...) "1"
  ), parent = environment(require_fixture))
  expect_error(require_fixture("rebirth_selftest_new_handle"),
    "Required selftest build is incomplete", fixed = TRUE)
})
