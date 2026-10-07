# Frozen cross-language stream: tests/llm-golden/directions/ENCODING.md.
# All callers validate and canonicalize fixed schemas before reaching this file.
direction_encode <- function(x, emit, vector = FALSE) {
  tag <- function(s) emit(charToRaw(s))
  u32 <- function(n) emit(writeBin(as.integer(n), raw(), size = 4L, endian = "little"))
  string <- function(s) {
    bytes <- charToRaw(enc2utf8(s)); u32(length(bytes)); emit(bytes)
  }
  numeric_bytes <- function(x, size) {
    width <- 4096L %/% size
    if (length(x)) for (first in seq.int(1L, length(x), by = width)) {
      last <- min(length(x), first + width - 1L)
      emit(writeBin(unname(x[first:last]), raw(), size = size, endian = "little"))
    }
  }
  if (is.null(x)) { tag("N"); return(invisible(NULL)) }
  if (is.matrix(x)) {
    tag("M"); u32(nrow(x)); u32(ncol(x))
    direction_encode(rownames(x), emit, TRUE)
    direction_encode(colnames(x), emit, TRUE)
    tag("d"); u32(as.double(nrow(x)) * ncol(x))
    for (i in seq_len(nrow(x))) numeric_bytes(x[i, ], 8L)
  } else if (is.data.frame(x)) {
    tag("F"); u32(nrow(x)); u32(ncol(x))
    for (key in names(x)) {
      tag("S"); string(key); direction_encode(x[[key]], emit, TRUE)
    }
  } else if (is.list(x)) {
    tag("R"); u32(length(x))
    for (key in names(x)) {
      tag("S"); string(key)
      direction_encode(x[[key]], emit, key %in% c("neuron", "value"))
    }
  } else {
    type <- typeof(x)
    scalar <- !vector && length(x) == 1L
    code <- switch(type, logical = "L", integer = "I", double = "D", character = "S",
      stop("Unsupported internal direction encoding type"))
    tag(if (scalar) code else tolower(code))
    if (!scalar) u32(length(x))
    if (type == "character") {
      for (value in x) string(value)
    } else if (type == "logical") {
      if (length(x)) for (first in seq.int(1L, length(x), by = 4096L)) {
        emit(as.raw(x[first:min(length(x), first + 4095L)]))
      }
    } else numeric_bytes(x, if (type == "integer") 4L else 8L)
  }
  invisible(NULL)
}

direction_stream <- function(domain, x, emit, vector = FALSE) {
  emit(c(charToRaw("relm_direction/1"), as.raw(0)))
  direction_encode(domain, emit)
  direction_encode(x, emit, vector)
  invisible(NULL)
}

direction_write_bytes <- function(bytes, con) writeBin(bytes, con)

direction_hash <- function(domain, x, limit, vector = FALSE) {
  path <- tempfile("relm-direction-", fileext = ".bin")
  con <- NULL
  on.exit({
    if (!is.null(con)) try(close(con), silent = TRUE)
    unlink(path)
  }, add = TRUE)
  tryCatch(withCallingHandlers({
    con <- file(path, open = "wb")
    count <- 0
    emit <- function(bytes) {
      if (length(bytes) > 4096L || count + length(bytes) > limit) {
        relm_abort("relm_error_internal", "Direction checksum stream exceeded its admitted byte bound; report this invariant failure.",
          list(reason = "direction_canonical_size", bytes = count + length(bytes), limit = limit))
      }
      direction_write_bytes(bytes, con)
      count <<- count + length(bytes)
    }
    direction_stream(domain, x, emit, vector)
    close(con); con <- NULL
    size <- file.info(path)$size
    if (length(size) != 1L || is.na(size) || size != count) {
      stop("Temporary canonical file has an incomplete byte count")
    }
    value <- unname(tools::sha256sum(path))
    if (!direction_digest(value)) stop("SHA-256 calculation did not produce a digest")
    value
  }, warning = function(w) {
    direction_fail("direction_checksum_io", "A temporary direction write or checksum reported an I/O warning. Check temporary storage and retry the operation.", parent = w)
  }), error = function(e) {
    if (inherits(e, "relm_error")) stop(e)
    direction_fail("direction_checksum_io", "Could not write or checksum temporary direction bytes. Check temporary storage and retry the operation.", parent = e)
  })
}

direction_payload <- function(x) {
  meta <- attr(x, "direction", exact = TRUE)
  meta$digests$payload <- NULL
  list(neuron = x$neuron, value = x$value, direction = meta)
}
