# D045 input/provenance/persistence checks on all four ordinary R CI legs.
test_that("paired matrices require exact complete coordinates and plain finite input", {
  f <- direction_test_fixture()
  for (kind in c("integer", "rows", "columns", "partial", "attribute", "nonfinite")) {
    bad <- f
    if (kind == "integer") storage.mode(bad$target) <- "integer"
    if (kind == "rows") bad$target <- bad$target[3:1, , drop = FALSE]
    if (kind == "columns") bad$target <- bad$target[, 4:1, drop = FALSE]
    if (kind == "partial") bad$target <- bad$target[, -1, drop = FALSE]
    if (kind == "attribute") attr(bad$target, "origin") <- "unvalidated"
    if (kind == "nonfinite") bad$target[1, 1] <- Inf
    expect_error(direction_test_build(bad), class = "relm_error_argument", info = kind)
  }
  expect_error(llm_direction(f$target, f$control, f$context, 1L), class = "relm_error_argument")
  expect_error(direction_test_build(f, normalize_pairs = 1), class = "relm_error_argument")
  expect_error(direction_test_build(f, orthogonalize = NA), class = "relm_error_argument")
})

test_that("recorded capture and splits fail closed without silent reconciliation", {
  f <- direction_test_fixture()
  for (kind in c("overlap", "missing", "order", "width", "capture", "special", "position", "unknown", "digest")) {
    bad <- f
    if (kind == "overlap") bad$context$splits$prompt_sha256[7] <- bad$context$splits$prompt_sha256[1]
    if (kind == "missing") bad$context$splits$split[7] <- "evaluation"
    if (kind == "order") bad$context$pairs <- bad$context$pairs[3:1, ]
    if (kind == "width") bad$context$model$hidden_size <- 3L
    if (kind == "capture") bad$context$capture$component <- "attn_out"
    if (kind == "special") bad$context$capture$parse_special <- TRUE
    if (kind == "position") bad$context$pairs$target_pos[1] <- 0L
    if (kind == "unknown") bad$context$extra <- 1
    if (kind == "digest") bad$context$model$sha256 <- "same-path.gguf"
    expect_error(direction_test_build(bad), class = "relm_error_argument", info = kind)
  }
})

test_that("direction construction preserves inputs and random state", {
  f <- direction_test_fixture(); saved <- serialize(f, NULL)
  existed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
  previous <- if (existed) get(".Random.seed", envir = .GlobalEnv) else NULL
  on.exit(if (existed) assign(".Random.seed", previous, envir = .GlobalEnv)
          else if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE))
            rm(".Random.seed", envir = .GlobalEnv), add = TRUE)
  set.seed(345)
  seed <- .Random.seed
  result <- direction_test_build(f)
  expect_identical(serialize(f, NULL), saved)
  expect_identical(.Random.seed, seed)
  expect_identical(class(result), c("relm_direction", "data.frame"))
  expect_identical(names(result), c("neuron", "value"))
  expect_identical(result$neuron, 1:4)
  expect_identical(typeof(result$value), "double")
  expect_equal(sum(result$value^2), 1, tolerance = 1e-12)
  expect_identical(attr(result, "direction")$context, f$context)
})

test_that("record field order canonicalizes but coordinate order does not", {
  f <- direction_test_fixture(); expected <- direction_test_build(f)
  f$context <- f$context[rev(names(f$context))]
  f$context$model <- f$context$model[rev(names(f$context$model))]
  f$context$pairs <- f$context$pairs[rev(names(f$context$pairs))]
  expect_identical(direction_test_build(f), expected)
})

test_that("trusted RDS preserves exact artifact values and validates on print", {
  x <- direction_test_build(); p <- tempfile(fileext = ".rds")
  on.exit(unlink(p), add = TRUE)
  saveRDS(x, p, version = 3); y <- readRDS(p)
  expect_identical(y, x)
  lines <- capture.output(value <- withVisible(print(y)))
  expect_identical(value$value, y)
  expect_false(value$visible)
  expect_lte(length(lines), 12L)
  expect_match(paste(lines, collapse = " "), "recorded|Recorded")
  expect_error(print(y, digits = 3), class = "relm_error_argument")
})

test_that("artifact tampering and incompatibility refuse before native derivation", {
  x <- direction_test_build(); context <- attr(x, "direction")$context$model
  m <- direction_test_handle(context); calls <- 0L
  testthat::local_mocked_bindings(llm_steer = function(...) {
    calls <<- calls + 1L; stop("Unexpected derivation")
  }, .package = "relm")
  for (kind in c("value", "neuron", "layer", "model", "schema", "split", "attribute")) {
    bad <- x
    if (kind == "value") bad$value[1] <- bad$value[1] + .1
    if (kind == "neuron") bad$neuron <- 4:1
    if (kind == "layer") attr(bad, "direction")$layer <- 3L
    if (kind == "model") attr(bad, "direction")$context$model$quantization <- "Q4_K_M"
    if (kind == "schema") attr(bad, "direction")$schema <- "relm_direction/2"
    if (kind == "split") attr(bad, "direction")$context$splits$split[1] <- "evaluation"
    if (kind == "attribute") attr(bad, "undocumented") <- TRUE
    expect_error(llm_apply_direction(m, bad, context), class = "relm_error_intervention", info = kind)
  }
  foreign <- context; foreign$sha256 <- paste(rep("b", 64), collapse = "")
  expect_error(llm_apply_direction(m, x, foreign), class = "relm_error_intervention")
  m$quantization <- "Q4_K_M"
  expect_error(llm_apply_direction(m, x, context), class = "relm_error_intervention")
  expect_identical(calls, 0L)
})

test_that("checked application delegates exactly the approved existing intervention", {
  x <- direction_test_build(); context <- attr(x, "direction")$context$model
  m <- direction_test_handle(context); seen <- NULL
  testthat::local_mocked_bindings(llm_steer = function(m, layer, direction, coef, positions) {
    seen <<- list(m, layer, direction, coef, positions)
    structure(list(marker = TRUE), class = "llm")
  }, .package = "relm")
  result <- llm_apply_direction(m, x, context, coef = -0.5)
  expect_s3_class(result, "llm")
  expect_identical(seen, list(m, 2L, x$value, -0.5, "all"))
  expect_identical(m$interventions, list())
})

test_that("admission refuses before checksumming oversized working sets", {
  f <- direction_test_fixture(n = 8L, h = 65536L); hashes <- 0L
  testthat::local_mocked_bindings(direction_hash = function(...) {
    hashes <<- hashes + 1L; stop("Unexpected checksum")
  }, .package = "relm")
  expect_error(direction_test_build(f, max_bytes = 2^20), class = "relm_error_oom")
  expect_identical(hashes, 0L)
  expect_error(direction_test_build(max_bytes = 512 * 2^20 + 1), class = "relm_error_argument")
})

test_that("temporary checksum files close and disappear after failures", {
  before <- list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE)
  original <- relm:::direction_stream
  testthat::local_mocked_bindings(direction_stream = function(domain, x, emit, vector) {
    emit(as.raw(c(1, 2, 3))); stop("injected write-body failure")
  }, .package = "relm")
  expect_error(relm:::direction_hash("values", list(), 1024), class = "relm_error_intervention")
  expect_identical(list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE), before)
  expect_true(is.function(original))
})

test_that("ignored row names cannot smuggle environments into retained artifacts", {
  f <- direction_test_fixture(); hidden <- new.env(parent = emptyenv())
  hidden$not_in_the_ledger <- raw(1024)
  for (frame in c("pairs", "splits")) {
    bad <- f
    attr(bad$context[[frame]], "row.names") <- structure(as.character(seq_len(nrow(bad$context[[frame]]))), hidden = hidden)
    expect_error(direction_test_build(bad), class = "relm_error_argument")
  }
  x <- direction_test_build()
  bad <- x; attr(bad, "row.names") <- structure(as.character(seq_len(nrow(x))), hidden = hidden)
  expect_error(print(bad), class = "relm_error_intervention")
  bad <- x; p <- attr(bad, "direction")$diagnostics$pairs
  attr(p, "row.names") <- structure(as.character(seq_len(nrow(p))), hidden = hidden)
  attr(bad, "direction")$diagnostics$pairs <- p
  expect_error(print(bad), class = "relm_error_intervention")
  # Ordinary row labels are non-semantic and canonicalized, never retained.
  rownames(f$context$pairs) <- c("one", "two", "three")
  y <- direction_test_build(f)
  expect_identical(attr(y, "direction")$context$pairs, attr(x, "direction")$context$pairs)
})
