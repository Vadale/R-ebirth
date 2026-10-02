# Pure-R admission, representation, serialization and materialized-memory gates.
# Every R CI leg; no model, native worker, download, or optional service.
test_that("stream admission rejects invalid sinks before RNG submission or header", {
  local_mocked_bindings(rebirth_async_ready = function(...) stop("must not submit"),
    .package = "relm")
  m <- stub_llm()
  set.seed(125)
  before <- .Random.seed
  for (bad in list(TRUE, 1L, "file.csv", list(), raw(), structure(1L, class = "connection"))) {
    expect_error(llm_generate(m, "x", async = TRUE, on_token = bad),
      class = "relm_error_argument")
  }
  expect_error(llm_generate(m, "x", on_token = identity), class = "relm_error_argument")
  path <- tempfile()
  con <- file(path, "wb")
  on.exit({ close(con); unlink(path) }, add = TRUE)
  expect_error(llm_generate(m, character(), async = TRUE, on_token = con),
    class = "relm_error_argument")
  expect_error(llm_generate(m, "x", max_tokens = 0, async = TRUE, on_token = con),
    class = "relm_error_argument")
  expect_identical(file.info(path)$size, 0)
  expect_identical(seek(con, where = NA, rw = "write"), 0)
  expect_identical(.Random.seed, before)
})

test_that("native file admission distinguishes regular files from devices and invalid paths", {
  regular <- function(path) relm:::relm_check(relm:::rebirth_stream_regular_file(path))$regular
  path <- tempfile()
  expect_true(file.create(path))
  on.exit(unlink(path), add = TRUE)
  expect_true(regular(path))
  expect_false(regular(tempfile()))
  expect_false(regular(tempdir()))
  for (bad in list(character(), c(path, path), NA_character_, "", 1L, list(path))) {
    expect_error(regular(bad), class = "relm_error_argument")
  }
  if (.Platform$OS.type == "unix") {
    expect_false(regular("/dev/null"))
    link <- tempfile()
    on.exit(unlink(link), add = TRUE)
    expect_true(file.symlink(path, link))
    expect_true(regular(link))
    unlink(link)
    expect_true(file.symlink("/dev/null", link))
    expect_false(regular(link))
    con <- file(link, "wb", raw = TRUE)
    on.exit(close(con), add = TRUE)
    expect_error(llm_generate(stub_llm(), "x", async = TRUE, on_token = con),
      class = "relm_error_argument")
    expect_true(isOpen(con))
  }
})

test_that("only caller-owned empty writable seekable binary regular files are admitted", {
  path <- tempfile()
  on.exit(unlink(path), add = TRUE)
  for (mode in c("wb", "w+b", "r+b")) {
    if (mode == "r+b") file.create(path)
    con <- file(path, mode)
    tryCatch({
      sink <- relm:::stream_validate_sink(con, TRUE)
      expect_identical(sink$kind, "file")
      expect_identical(sink$conn_id, attr(con, "conn_id"))
      expect_true(isOpen(con))
    }, finally = close(con))
  }
  for (mode in c("w", "ab", "rb")) {
    con <- file(path, mode)
    expect_error(relm:::stream_validate_sink(con, TRUE), class = "relm_error_argument")
    close(con)
  }
  con <- file(path, "wb")
  writeBin(as.raw(65), con)
  flush(con)
  expect_error(relm:::stream_validate_sink(con, TRUE), class = "relm_error_argument")
  close(con)
  con <- file(path, "wb")
  seek(con, 10, rw = "write")
  expect_error(relm:::stream_validate_sink(con, TRUE), class = "relm_error_argument")
  close(con)
  expect_error(relm:::stream_validate_sink(con, TRUE), class = "relm_error_argument")
  con <- rawConnection(raw(), "wb")
  expect_error(relm:::stream_validate_sink(con, TRUE), class = "relm_error_argument")
  close(con)
  con <- gzfile(path, "wb")
  expect_error(relm:::stream_validate_sink(con, TRUE), class = "relm_error_argument")
  close(con)
  if (.Platform$OS.type == "unix") {
    con <- file("/dev/null", "wb")
    expect_error(relm:::stream_validate_sink(con, TRUE), class = "relm_error_argument")
    close(con)
  }
})

test_that("closed and reused connection slots cannot redirect the stream", {
  first <- tempfile()
  second <- tempfile()
  on.exit(unlink(c(first, second)), add = TRUE)
  con <- file(first, "wb")
  sink <- relm:::stream_validate_sink(con, TRUE)
  slot <- as.integer(con)
  close(con)
  replacement <- file(second, "wb")
  on.exit(close(replacement), add = TRUE)
  expect_identical(as.integer(replacement), slot)
  error <- tryCatch(relm:::stream_check_connection(sink), error = identity)
  expect_s3_class(error, "relm_error_stream")
  expect_identical(error$reason, "closed")
  expect_s3_class(error$parent, "condition")
  expect_identical(file.info(second)$size, 0)
})

test_that("CSV preserves quoting newlines Unicode literal NA and typed missing fields", {
  path <- tempfile()
  con <- file(path, "wb")
  on.exit({ close(con); unlink(path) }, add = TRUE)
  batch <- stream_test_batch()
  batch <- batch[rep(1:3, 2), ]
  rownames(batch) <- NULL
  batch$event_id <- seq_len(nrow(batch))
  batch$text <- c("", 'NA,"double"\nline\n雪é', "", "", "NA", "")
  batch$validated <- c(NA, NA, NA, FALSE, FALSE, TRUE)
  batch$elapsed <- c(0, 0.1, 1 / 3, 0.12345678901234567, 12345.987654321, 1000000)
  old <- options(OutDec = ",", digits = 2, scipen = 999)
  on.exit(options(old), add = TRUE)
  writeBin(relm:::stream_csv_bytes(), con)
  bytes <- relm:::stream_csv_bytes(batch)
  writeBin(bytes, con)
  flush(con)
  observed <- stream_test_read(path)
  expect_identical(observed, batch)
  expect_true(grepl('"NA,""double""\nline\n雪é"', rawToChar(bytes), fixed = TRUE))
  expect_true(grepl(',FALSE\n', rawToChar(bytes), fixed = TRUE))
  expect_false(grepl(',NA,', rawToChar(bytes), fixed = TRUE))
  expect_identical(tail(bytes, 1), charToRaw("\n"))
  # Base read.csv normalizes embedded CRLF; the CSV itself must retain it.
  batch$text[2] <- "line\r\nnext"
  expect_true(grepl('"line\r\nnext"', rawToChar(relm:::stream_csv_bytes(batch)), fixed = TRUE))
})

test_that("representation validation rejects malformed data before consumer execution", {
  batch <- stream_test_batch()
  expect_no_error(relm:::stream_validate_batch(stream_test_job(), batch))
  structured <- batch
  structured$validated <- c(FALSE, FALSE, TRUE)
  expect_no_error(relm:::stream_validate_batch(stream_test_job(TRUE), structured))
  mutations <- list(
    function(x) { x$event_id[2] <- 3L; x },
    function(x) { x$prompt_id[2] <- 2L; x },
    function(x) { x$token_id[1] <- 0L; x },
    function(x) { x$token_pos[1] <- 2L; x },
    function(x) { x$elapsed[2] <- -1; x },
    function(x) { x$elapsed[3] <- Inf; x },
    function(x) { x$text[2] <- ""; x },
    function(x) { x$event[1] <- "other"; x },
    function(x) { x$finish_reason[3] <- "other"; x },
    function(x) { x$validated[1] <- FALSE; x },
    function(x) { x$text[2] <- strrep("x", 16385); x },
    function(x) { x$elapsed <- as.integer(x$elapsed); x })
  for (mutate in mutations) {
    error <- tryCatch(relm:::stream_validate_batch(stream_test_job(), mutate(batch)), error = identity)
    expect_s3_class(error, "relm_error_stream")
    expect_identical(error$reason, "invariant")
  }
  batch$text[2] <- rawToChar(as.raw(255))
  Encoding(batch$text[2]) <- "bytes"
  error <- tryCatch(relm:::stream_validate_batch(stream_test_job(), batch), error = identity)
  expect_identical(error$reason, "encoding")
})

test_that("stream memory bounds cover materialized columns and CSV escaping copies", {
  for (rows in c(1L, 64L)) {
    bytes <- min(relm:::relm_stream_batch_bytes, rows * relm:::relm_stream_chunk_bytes)
    batch <- stream_test_batch()[rep(2L, rows), ]
    batch$event_id <- seq_len(rows)
    # Distinct quote-rich payloads force escaping growth and defeat string sharing.
    batch$text <- paste0(strrep('"', bytes / rows - 8), sprintf("%08d", seq_len(rows)))
    expect_equal(sum(nchar(batch$text, type = "bytes")), bytes)
    expect_lte(as.numeric(object.size(batch)), relm:::stream_batch_size_bound(rows, bytes))
    escaped <- lapply(batch, function(x) if (is.character(x)) relm:::stream_quote(x) else
      ifelse(is.na(x), "", as.character(x)))
    records <- do.call(paste, c(escaped, sep = ","))
    joined <- paste0(paste(records, collapse = "\n"), "\n")
    materialized <- list(escaped = escaped, records = records, joined = joined,
      raw = relm:::stream_csv_bytes(batch))
    expect_lte(as.numeric(object.size(materialized)), relm:::stream_csv_size_bound(rows, bytes))
  }
  estimate <- relm:::stream_transport_peak_bound()
  expect_identical(estimate$total_bytes, sum(estimate$components))
  expect_gt(estimate$components[["decoder_scratch"]], relm:::relm_async_max_output_bytes)
  expect_gt(estimate$total_bytes, relm:::relm_stream_queue_bytes)
})
