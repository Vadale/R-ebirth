# D-038 limits, twin-pinned at the native boundary. These are payload limits;
# stream_transport_peak_bound() also accounts for materialized R/CSV storage.
relm_stream_queue_rows <- 256
relm_stream_queue_bytes <- 262144
relm_stream_chunk_bytes <- 16384
relm_stream_batch_rows <- 64
relm_stream_batch_bytes <- 65536

stream_columns <- c("event_id", "event", "prompt_id", "token_pos", "token_id",
  "text", "elapsed", "finish_reason", "validated")
stream_types <- c("integer", "character", "integer", "integer", "integer",
  "character", "double", "character", "logical")

# Admission is read-only: never open, close, seek to a new position, or write.
stream_validate_sink <- function(on_token, async) {
  if (is.null(on_token)) return(NULL)
  reject <- function() abort_argument("on_token", paste0(
    "`on_token` requires `async = TRUE` and must be a function or an already-open, ",
    "writable binary file() connection to an empty regular file at position zero."))
  if (!async) reject()
  if (is.function(on_token)) return(list(kind = "callback", consumer = on_token))
  if (!identical(class(on_token), c("file", "connection"))) reject()
  checked <- tryCatch({
    info <- summary(on_token)
    id <- attr(on_token, "conn_id", exact = TRUE)
    current <- getConnection(as.integer(on_token))
    path <- info$description
    valid <- identical(info$class, "file") && identical(info$text, "binary") &&
      identical(info$opened, "opened") && identical(info[["can write"]], "yes") &&
      !grepl("a", info$mode, fixed = TRUE) && isSeekable(on_token) &&
      typeof(id) == "externalptr" && identical(id, attr(current, "conn_id", exact = TRUE)) &&
      isTRUE(relm_check(rebirth_stream_regular_file(path.expand(path)))$regular) &&
      isTRUE(file.info(path)$size == 0) &&
      identical(seek(on_token, where = NA, rw = "write"), 0)
    if (valid) list(kind = "file", consumer = on_token, conn_id = id) else NULL
  }, error = function(e) NULL, warning = function(w) NULL)
  if (is.null(checked)) reject()
  checked
}

stream_condition <- function(reason, message, parent = NULL,
                             prompt_id = NA_integer_, event_id = NA_integer_) {
  async_condition("relm_error_stream", message,
    list(reason = reason, prompt_id = as.integer(prompt_id),
      event_id = as.integer(event_id), parent = parent))
}

stream_check_connection <- function(sink) {
  parent <- tryCatch({
    current <- getConnection(as.integer(sink$consumer))
    if (!identical(attr(current, "conn_id", exact = TRUE), sink$conn_id) ||
      !isOpen(sink$consumer, "write")) {
      stop("The supplied file connection is closed or its descriptor was reused.")
    }
    NULL
  }, error = identity, warning = identity)
  if (!is.null(parent)) stop(stream_condition("closed",
    "The token stream connection closed before delivery completed.", parent))
  invisible(NULL)
}

stream_quote <- function(x) paste0('"', gsub('"', '""', enc2utf8(x), fixed = TRUE), '"')

# Explicit per-column formatting avoids locale/print options and preserves the
# difference between character "NA" and a missing numeric/logical field.
stream_csv_bytes <- function(batch = NULL) {
  if (is.null(batch)) return(charToRaw(paste0(paste(stream_quote(stream_columns),
    collapse = ","), "\n")))
  columns <- lapply(batch, function(x) {
    if (is.character(x)) return(stream_quote(x))
    if (is.double(x)) return(ifelse(is.na(x), "",
      trimws(formatC(x, digits = 17L, format = "g", decimal.mark = ".", flag = ""))))
    ifelse(is.na(x), "", as.character(x))
  })
  records <- do.call(paste, c(columns, sep = ","))
  charToRaw(enc2utf8(paste0(paste(records, collapse = "\n"), "\n")))
}

# Kept separate so tests can inject an actual write/flush failure condition.
stream_write_bytes <- function(bytes, con) writeBin(bytes, con)
stream_flush <- function(con) flush(con)

stream_file_delivery <- function(job, batch = NULL, flush_only = FALSE) {
  sink <- job$stream
  tryCatch({
    stream_check_connection(sink)
    if (!flush_only) stream_write_bytes(stream_csv_bytes(batch), sink$consumer)
    stream_flush(sink$consumer)
  }, error = function(error) stream_file_failure(job, error, batch),
    interrupt = function(error) stream_file_failure(job, error, batch),
    warning = function(error) stream_file_failure(job, error, batch))
  invisible(NULL)
}

stream_file_failure <- function(job, error, batch = NULL) {
  if (!inherits(error, "relm_error_stream")) {
    error <- stream_condition("write", "Writing or flushing the token stream failed.",
      error, if (is.null(batch)) NA_integer_ else batch$prompt_id[[1L]],
      if (is.null(batch)) NA_integer_ else batch$event_id[[1L]])
  }
  async_consumer_failure(job, error)
}

stream_validate_batch <- function(job, batch) {
  fail <- function(reason = "invariant") stop(stream_condition(reason,
    "The native token stream batch violated its delivery contract."))
  if (!identical(class(batch), "data.frame") || !identical(names(batch), stream_columns) ||
    !identical(unname(vapply(batch, typeof, character(1))), stream_types) ||
    nrow(batch) < 1L || nrow(batch) > relm_stream_batch_rows) fail()
  for (column in c("event", "text", "finish_reason")) {
    values <- batch[[column]]
    if (anyNA(values)) fail()
    if (any(Encoding(values) == "bytes") || !all(validUTF8(values))) fail("encoding")
  }
  bytes <- nchar(batch$text, type = "bytes")
  if (sum(bytes) > relm_stream_batch_bytes || any(bytes > relm_stream_chunk_bytes) ||
    anyNA(batch$event_id) || anyNA(batch$prompt_id) || anyNA(batch$elapsed) ||
    any(!is.finite(batch$elapsed)) || any(diff(c(job$stream_elapsed, batch$elapsed)) < 0) ||
    !identical(batch$event_id, as.integer(job$stream_event_id + seq_len(nrow(batch))))) fail()
  prompt <- job$stream_prompt_id
  token <- job$stream_token_pos
  for (i in seq_len(nrow(batch))) {
    event <- batch$event[[i]]
    if (batch$prompt_id[[i]] != prompt || prompt > job$prompts_total) fail()
    if (!event %in% c("token", "text", "prompt_end")) fail()
    if (event == "token") {
      if (is.na(batch$token_pos[[i]]) || batch$token_pos[[i]] != token + 1L ||
        is.na(batch$token_id[[i]]) || batch$token_id[[i]] < 1L) fail()
      token <- token + 1L
    } else if (!is.na(batch$token_pos[[i]]) || !is.na(batch$token_id[[i]])) fail()
    if ((event == "text" && bytes[[i]] == 0) ||
      (event != "text" && bytes[[i]] != 0)) fail()
    if (event == "prompt_end") {
      if (!batch$finish_reason[[i]] %in% c("length", "stop", "stop_string", "context_full")) fail()
      prompt <- prompt + 1L
      token <- 0L
    } else if (nzchar(batch$finish_reason[[i]])) fail()
    expected <- if (job$structured) event == "prompt_end" else NA
    if (!identical(batch$validated[[i]], expected)) fail()
  }
  job$stream_event_id <- utils::tail(batch$event_id, 1L)
  job$stream_elapsed <- utils::tail(batch$elapsed, 1L)
  job$stream_prompt_id <- prompt
  job$stream_token_pos <- token
  invisible(NULL)
}

stream_deliver <- function(job, batch) {
  if (is.null(batch) || !is.null(job$callback_error) || job$model$state$closed) {
    return(invisible(NULL))
  }
  valid <- tryCatch({ stream_validate_batch(job, batch); TRUE },
    error = function(error) { async_consumer_failure(job, error); FALSE },
    interrupt = function(error) { async_consumer_failure(job,
      stream_condition("invariant", "Token stream representation was interrupted.", error)); FALSE })
  if (!valid) return(invisible(NULL))
  if (identical(job$stream$kind, "file")) return(stream_file_delivery(job, batch))
  fail <- function(error) async_consumer_failure(job,
    async_condition("relm_error_callback", "The token stream callback failed; no generation result was returned.",
      list(callback = "on_token", parent = error)))
  tryCatch(job$stream$consumer(batch), error = fail, interrupt = fail)
  invisible(NULL)
}

# Sum distinct columns/CHARSXPs and alignment at the maximum legal dispatch.
# CSV uses escaped columns, row strings, a combined string and a raw byte vector.
# This deliberately sums overlapping/transient copies, excluding caller retention.
stream_batch_size_bound <- function(rows = relm_stream_batch_rows,
                                    text_bytes = relm_stream_batch_bytes) {
  8192 + 1024 * rows + text_bytes
}

stream_csv_size_bound <- function(rows = relm_stream_batch_rows,
                                  text_bytes = relm_stream_batch_bytes) {
  8192 + 2048 * rows + 12 * text_bytes
}

stream_transport_peak_bound <- function() {
  # Native fixed-size event descriptors are conservatively charged at 128 bytes.
  # Full ordinary snapshots, stable-prefix/stop work and final verification can
  # coexist: reserve eight output-cap copies even though most jobs use fewer.
  components <- c(queue = 128 * relm_stream_queue_rows + relm_stream_queue_bytes,
    producer = 128 + relm_stream_chunk_bytes,
    native_batch = 128 * relm_stream_batch_rows + relm_stream_batch_bytes,
    decoder_scratch = 8 * relm_async_max_output_bytes,
    r_batch = stream_batch_size_bound(), r_csv = stream_csv_size_bound())
  list(total_bytes = sum(components), components = components)
}
