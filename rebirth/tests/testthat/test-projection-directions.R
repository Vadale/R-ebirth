# New schema2 references frozen independently in d8a4800 before product changes.
test_that("schema2 canonical streams match all eleven independent vectors", {
  index <- read.csv(test_path("fixtures", "projection", "encoding-index.csv"),
    colClasses = "character", check.names = FALSE)
  expect_identical(nrow(index), 11L)
  for (i in seq_len(nrow(index))) {
    node <- direction_fixture_nodes(index$case[i], "projection"); chunks <- list()
    relm:::direction_stream(index$domain[i], node$value, function(bytes) {
      expect_lte(length(bytes), 4096L); chunks[[length(chunks) + 1L]] <<- bytes
    }, vector = node$vector, schema = "relm_direction/2")
    frozen <- readBin(test_path("fixtures", "projection", index$binary[i]), "raw", n = as.integer(index$bytes[i]))
    expect_identical(do.call(c, chunks), frozen, info = index$case[i])
    expect_identical(relm:::direction_hash(index$domain[i], node$value,
      length(frozen), node$vector, schema = "relm_direction/2"), index$sha256[i])
    expect_false(identical(relm:::direction_hash(index$domain[i], node$value,
      length(frozen), node$vector), index$sha256[i]))
  }
})

test_that("both independent schema2 artifacts validate without product construction", {
  index <- read.csv(test_path("fixtures", "projection", "encoding-index.csv"), colClasses = "character")
  for (component in c("mlp_out", "attn_out")) {
    key <- paste0(component, "_artifact")
    payload <- direction_fixture_nodes(key, "projection")$value
    payload$direction$digests$payload <- index$sha256[index$case == key]
    artifact <- structure(payload[c("neuron", "value")], class = c("relm_direction", "data.frame"),
      row.names = .set_row_names(length(payload$value)), direction = payload$direction)
    expect_identical(relm:::direction_validate(artifact)$artifact, artifact)
    for (change in c("schema", "component", "capture", "layer")) {
      bad <- artifact
      if (change == "schema") attr(bad, "direction")$schema <- "relm_direction/1"
      if (change == "component") attr(bad, "direction")$component <- "residual"
      if (change == "capture") attr(bad, "direction")$context$capture$component <- "residual"
      if (change == "layer") attr(bad, "direction")$layer <- 0L
      expect_error(relm:::direction_validate(bad), class = "relm_error_intervention")
    }
  }
})

test_that("component construction preserves paired arithmetic at first and last layers", {
  f <- direction_test_fixture(); residual <- direction_test_build(f)
  expect_identical(attr(residual, "direction")$schema, "relm_direction/1")
  for (component in c("mlp_out", "attn_out")) {
    f$context$capture$component <- component
    for (layer in c(1L, f$context$model$layers)) {
      x <- llm_direction(f$target, f$control, f$context, layer = layer)
      meta <- attr(x, "direction")
      expect_identical(meta$schema, "relm_direction/2")
      expect_identical(meta$component, component)
      expect_identical(meta$layer, layer)
      expect_identical(x$value, residual$value)
      expect_identical(relm:::direction_validate(x)$artifact, x)
      expect_output(print(x), component)
      expect_error(llm_apply_direction(direction_test_handle(f$context$model),
        x, f$context$model), class = "relm_error_intervention")
    }
  }
})

test_that("schema2 retains full-width and capture bounds and schema1 layer rules", {
  f <- direction_test_fixture()
  expect_error(llm_direction(f$target, f$control, f$context, 1L), class = "relm_error_argument")
  f$context$capture$component <- "mlp_out"
  expect_error(llm_direction(f$target, f$control, f$context, 0L), class = "relm_error_argument")
  expect_error(llm_direction(f$target, f$control, f$context, 25L), class = "relm_error_argument")
  f$context$capture$component <- "mlp"
  expect_error(llm_direction(f$target, f$control, f$context, 1L), class = "relm_error_argument")
  f$context$capture$component <- c(name = "mlp_out")
  expect_error(llm_direction(f$target, f$control, f$context, 1L), class = "relm_error_argument")
  f$context$capture$component <- "mlp_out"; f$context$capture$positions <- "all"
  expect_error(llm_direction(f$target, f$control, f$context, 1L), class = "relm_error_argument")
  f$context$capture$positions <- "last"; f$context$model$hidden_size <- 8L
  expect_error(llm_direction(f$target, f$control, f$context, 1L), class = "relm_error_argument")
})
