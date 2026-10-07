test_that("directions match all independent accepted arithmetic and diagnostics", {
  cases <- direction_csv("cases.csv"); inputs <- direction_csv("inputs.csv")
  expected <- direction_csv("expected.csv"); diagnostics <- direction_csv("diagnostics.csv")
  norms <- direction_csv("pair-norms.csv"); count <- 0L
  near <- function(a, b) expect_true(all(abs(a - b) <= 1e-12 + 1e-12 * abs(b)))
  for (id in cases$case[cases$outcome == "accepted"]) {
    spec <- cases[cases$case == id, ]; rows <- inputs[inputs$case == id, ]
    f <- direction_test_fixture(as.integer(spec$n_pairs), as.integer(spec$width))
    f$target[] <- matrix(as.double(rows$target), nrow(f$target), ncol(f$target), byrow = TRUE)
    f$control[] <- matrix(as.double(rows$control), nrow(f$control), ncol(f$control), byrow = TRUE)
    x <- direction_test_build(f, normalize_pairs = spec$normalize_pairs == "1", orthogonalize = spec$orthogonalize == "1")
    near(x$value, as.double(expected$value[expected$case == id]))
    d <- attr(x, "direction")$diagnostics
    scalars <- diagnostics[diagnostics$case == id, ]
    near(unlist(d[scalars$field], use.names = FALSE), as.double(scalars$value))
    pairs <- norms[norms$case == id, ]
    for (field in names(pairs)[-c(1L, 2L)]) near(d$pairs[[field]], as.double(pairs[[field]]))
    expect_identical(relm:::direction_validate(x)$artifact, x)
    count <- count + length(x$value)
  }
  expect_identical(count, 52L)
})

test_that("independent degenerate and overflow cases refuse without dropping pairs", {
  cases <- direction_csv("cases.csv"); inputs <- direction_csv("inputs.csv")
  for (id in cases$case[cases$outcome == "rejected"]) {
    spec <- cases[cases$case == id, ]; rows <- inputs[inputs$case == id, ]
    f <- direction_test_fixture(as.integer(spec$n_pairs), as.integer(spec$width))
    f$target[] <- matrix(as.double(rows$target), nrow(f$target), ncol(f$target), byrow = TRUE)
    f$control[] <- matrix(as.double(rows$control), nrow(f$control), ncol(f$control), byrow = TRUE)
    e <- tryCatch(direction_test_build(f, normalize_pairs = spec$normalize_pairs == "1", orthogonalize = spec$orthogonalize == "1"), error = identity)
    expect_s3_class(e, if (spec$reason == "nonfinite_input") "relm_error_argument" else "relm_error_intervention", info = id)
    expect_identical(e$reason, spec$reason, info = id)
    if (nzchar(spec$pair_id)) expect_identical(e$pair_id, spec$pair_id, info = id)
  }
})

test_that("canonical R bytes exactly match all independent typed streams", {
  index <- direction_csv("encoding.csv")
  for (i in seq_len(nrow(index))) {
    f <- direction_fixture_nodes(index$case[i]); emitted <- list()
    relm:::direction_stream(index$domain[i], f$value, function(chunk) {
      expect_lte(length(chunk), 4096L)
      emitted[[length(emitted) + 1L]] <<- chunk
    }, vector = f$vector)
    actual <- do.call(c, emitted)
    bytes <- readBin(testthat::test_path("fixtures", "directions", index$binary[i]), "raw", n = as.integer(index$bytes[i]))
    expect_identical(actual, bytes, info = index$case[i])
    expect_identical(relm:::direction_hash(index$domain[i], f$value, length(bytes), f$vector), index$sha256[i])
  }
})

test_that("independent binary artifact survives full validation and rejects edits", {
  payload <- direction_fixture_nodes("artifact")$value
  index <- direction_csv("encoding.csv")
  payload$direction$digests$payload <- index$sha256[index$case == "artifact"]
  artifact <- structure(payload[c("neuron", "value")], class = c("relm_direction", "data.frame"),
    row.names = .set_row_names(length(payload$value)), direction = payload$direction)
  expect_identical(relm:::direction_validate(artifact)$artifact, artifact)
  bad <- artifact; attr(bad, "direction")$digests$target <- paste(rep("a", 64), collapse = "")
  expect_error(relm:::direction_validate(bad), class = "relm_error_intervention")
})
