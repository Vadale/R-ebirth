# Spill read/integrity layer for `rebirth_trace` (D-013).
#
# When a trace exceeds the materialized-bytes budget (D-017) it is streamed to an
# Arrow-IPC file rather than held in memory; the `rebirth_trace` object then carries
# only its `spill_*` attributes and reads slices lazily. This file holds that read
# side: the lazy slice reader (`read_spill_slice`), the staleness/integrity fail-safe
# (`verify_spill_integrity` + `spill_schema_ok`, ARCHITECTURE section 6), and the
# data-load-free summary (`summary_spilled_trace`). The trace object's lifecycle,
# budget pre-check, and S3 presentation live in `trace.R`, which calls into here.

# Read one (layer, component) slice from a spilled trace's Arrow-IPC file, lazily:
# pull record batches from the nanoarrow stream, keep only rows matching the
# requested layer and component, and shift the on-disk 0-based indices to the
# 1-based R API. Only the matching batches' rows are retained, so peak memory is
# one batch plus the slice (which fits — it is one in-memory as.matrix slice).
# Returns a (prompt_id, token_pos, neuron, value) data.frame (1-based indices).
read_spill_slice <- function(x, layer, component) {
  path <- attr(x, "spill_files")[1]
  if (is.null(path) || is.na(path) || !nzchar(path) || !file.exists(path)) {
    rebirth_abort(
      "rebirth_error_trace",
      sprintf(
        paste0(
          "The spill file for this trace is missing (%s). Spilled traces are ",
          "temporary and are removed when the R session ends; re-run llm_trace() ",
          "to recreate it."
        ),
        if (is.null(path) || is.na(path)) "<none>" else path
      )
    )
  }
  verify_spill_integrity(x, path)

  engine_layer <- as.integer(layer) - 1L # disk indices are 0-based (engine-native)

  # Pull every record batch, keeping only the requested (layer, component) rows. A
  # readable header/schema does NOT guarantee readable batch bodies: a truncated or
  # corrupt file raises a raw nanoarrow error while pulling batches, so catch any
  # read failure and re-raise it as a classed rebirth_error_trace carrying the same
  # re-run guidance as the missing-file / stale-footer branches (never a bare
  # nanoarrow error to the user). The condition is captured and re-raised at this
  # frame so its recorded `call` matches the other branches.
  parts <- tryCatch(
    {
      stream <- nanoarrow::read_nanoarrow(path, lazy = TRUE)
      acc <- list()
      repeat {
        batch <- stream$get_next()
        if (is.null(batch)) break
        df <- as.data.frame(batch)
        sel <- df$layer == engine_layer & df$component == component
        if (any(sel)) {
          acc[[length(acc) + 1L]] <- df[sel, c("prompt_id", "token_pos", "neuron", "value")]
        }
      }
      acc
    },
    error = function(e) e
  )
  if (inherits(parts, "condition")) {
    rebirth_abort(
      "rebirth_error_trace",
      sprintf(
        paste0(
          "The spill file '%s' could not be read: its record batches are truncated ",
          "or corrupt (%s). Spilled traces are temporary and are removed when the R ",
          "session ends; re-run llm_trace() to recreate it."
        ),
        path, conditionMessage(parts)
      )
    )
  }
  if (length(parts) == 0L) {
    return(data.frame(
      prompt_id = integer(0), token_pos = integer(0),
      neuron = integer(0), value = double(0), stringsAsFactors = FALSE
    ))
  }
  sub <- do.call(rbind, parts)
  data.frame(
    prompt_id = as.integer(sub$prompt_id) + 1L,
    token_pos = as.integer(sub$token_pos) + 1L,
    neuron = as.integer(sub$neuron) + 1L,
    value = as.double(sub$value),
    stringsAsFactors = FALSE
  )
}

# The staleness fail-safe (ARCHITECTURE section 6): before reading a spilled file,
# confirm its integrity footer (schema metadata) AND its on-disk schema match the
# trace object. A file from a different rebirth version (format), one overwritten by
# a later trace or belonging to another session (trace id / spec), or one whose
# column names or types have been altered (schema), is rejected rather than silently
# misread. The schema check matters because matching metadata strings alone do not
# guarantee the columns still decode: an altered column type would coerce to
# NA/garbage on read.
verify_spill_integrity <- function(x, path) {
  schema <- tryCatch(
    nanoarrow::read_nanoarrow(path, lazy = TRUE)$get_schema(),
    error = function(e) NULL
  )
  md <- if (is.null(schema)) NULL else schema$metadata
  fmt <- if (is.null(md)) NULL else md[["rebirth.spill_format"]]
  trace_id <- if (is.null(md)) NULL else md[["rebirth.trace_id"]]
  spec <- if (is.null(md)) NULL else md[["rebirth.spec"]]
  if (is.null(fmt) || !identical(as.character(fmt), "1")) {
    rebirth_abort(
      "rebirth_error_trace",
      sprintf(
        paste0(
          "The spill file '%s' is not a readable rebirth trace (format %s). It may ",
          "be from a different rebirth version or a different file; re-run llm_trace()."
        ),
        path, if (is.null(fmt)) "<none>" else as.character(fmt)
      )
    )
  }
  # The on-disk schema must still be the rebirth_trace schema (right column names and
  # types), or the read would coerce to NA/garbage despite matching metadata strings.
  if (!spill_schema_ok(schema)) {
    rebirth_abort(
      "rebirth_error_trace",
      sprintf(
        paste0(
          "The spill file '%s' does not have the expected rebirth_trace columns or ",
          "column types. It may be from a different rebirth version or a corrupted ",
          "file; re-run llm_trace()."
        ),
        path
      )
    )
  }
  if (is.null(trace_id) ||
    !identical(as.character(trace_id), as.character(attr(x, "spill_trace_id"))) ||
    is.null(spec) || !identical(as.character(spec), as.character(attr(x, "spill_spec")))) {
    rebirth_abort(
      "rebirth_error_trace",
      sprintf(
        paste0(
          "The spill file '%s' does not match this trace object: its capture spec or ",
          "trace id differs, so it was likely overwritten by a later trace or belongs ",
          "to a different session. Re-run llm_trace()."
        ),
        path
      )
    )
  }
  invisible(TRUE)
}

# Whether a spilled file's Arrow schema is the rebirth_trace schema: the seven
# columns in order, each of the expected kind. Types are checked by kind, not exact
# Arrow type, so the on-disk encoding (D-013: uint32 indices, float32 `value`, utf8
# strings) can evolve without breaking the guard — but an altered column type (e.g.
# `value` turned into a string, which would read back as NA) is rejected. Operates
# on the nanoarrow schema object, so it is identical whether that schema came from a
# real file or a constructed fixture. `NULL` (an unreadable schema) is not ok.
spill_schema_ok <- function(schema) {
  if (is.null(schema)) {
    return(FALSE)
  }
  fields <- schema$children
  if (length(fields) != 7L) {
    return(FALSE)
  }
  # `unname()`: nanoarrow's `$children` is a named list, so vapply would carry those
  # names, breaking the `identical()` compare against the unnamed expected vector.
  field_names <- unname(vapply(fields, function(f) f$name, character(1)))
  field_formats <- unname(vapply(fields, function(f) f$format, character(1)))
  expected_names <- c(
    "prompt_id", "token_pos", "token", "layer", "component", "neuron", "value"
  )
  if (!identical(field_names, expected_names)) {
    return(FALSE)
  }
  # Arrow C-data-interface format strings, grouped by the kind each column must be.
  is_int <- function(fmt) fmt %in% c("c", "C", "s", "S", "i", "I", "l", "L")
  is_chr <- function(fmt) fmt %in% c("u", "U", "vu")
  is_num <- function(fmt) fmt %in% c("e", "f", "g")
  kind <- list(
    prompt_id = is_int, token_pos = is_int, token = is_chr, layer = is_int,
    component = is_chr, neuron = is_int, value = is_num
  )
  all(mapply(function(nm, fmt) kind[[nm]](fmt), field_names, field_formats))
}

# Summarize a spilled trace from its attributes alone (never loads the file): each
# (layer, component) group holds `n_positions * n_embd` rows; the mean |value|
# would need a data load, so it is NA (use as.matrix() to read a slice).
summary_spilled_trace <- function(object) {
  layers <- as.integer(attr(object, "spill_layers"))
  components <- as.character(attr(object, "spill_components"))
  n_per_group <- as.double(attr(object, "spill_n_positions")) *
    as.integer(attr(object, "spill_n_embd"))
  groups <- expand.grid(
    component = components, layer = layers,
    stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE
  )
  groups <- groups[order(groups$layer, groups$component), , drop = FALSE]
  out <- data.frame(
    layer = as.integer(groups$layer),
    component = as.character(groups$component),
    n = rep(n_per_group, nrow(groups)),
    mean_abs = rep(NA_real_, nrow(groups)),
    stringsAsFactors = FALSE
  )
  structure(
    out,
    class = c("summary.rebirth_trace", "data.frame"),
    spilled = TRUE
  )
}
