#' Trace a model's activations
#'
#' Runs a forward pass over each prompt's tokens (no sampling) and captures the
#' internal activations selected by the filters, returning a long-format
#' `rebirth_trace` `data.frame` with one row per
#' `(prompt, token position, layer, component, neuron)`.
#'
#' @details
#' `llm_trace()` is the anatomy lab's core tool: it observes the residual stream
#' and the attention/MLP sub-layer outputs as the model processes text, so those
#' activations can be analysed with ordinary R (PCA, per-layer probes, and so on).
#' The tap adds no overhead to normal generation — it runs on a dedicated, transient
#' context created only for the trace.
#'
#' The captured columns are exactly (in order): `prompt_id` (1-based index into
#' `prompts`), `token_pos` (1-based position within that prompt), `token` (the token
#' piece), `layer` (1-based transformer block), `component` (`"residual"`,
#' `"attn_out"`, or `"mlp_out"`), `neuron` (1-based index within the component
#' vector), and `value` (the activation).
#'
#' **Memory (the 16 GB rule).** A full trace can be large, so the defaults capture
#' little (`positions = "last"`, `components = "residual"`); widen them deliberately.
#' Before running, the capture's size is estimated from the filters. If it fits the
#' budget (`min(2 GB, 20% of RAM)`, overridable with
#' `options(rebirth.trace_budget = <bytes>)`) it is held in memory. If it exceeds the
#' budget and `spill = TRUE` (the default), the capture is streamed to an Arrow-IPC
#' file under the session cache and the result is a *spilled* `rebirth_trace` that
#' loads lazily: `print()`/`summary()` never read the file, and
#' [as.matrix.rebirth_trace()] reads only the requested `(layer, component)` slice.
#' If it exceeds the budget and `spill = FALSE`, the call raises `rebirth_error_oom`
#' *before* any allocation, its `estimate_bytes` field stating the estimate. Spill
#' files are removed when the R session ends.
#'
#' The model must carry a tokenizer; a `no_vocab` model raises
#' `rebirth_error_tokenize`. As with the other text entry points, the runnable
#' example is guarded by the `REBIRTH_TEST_MODEL_QWEN` environment variable.
#'
#' @param m An `llm` handle from [llm()].
#' @param prompts A character vector of one or more non-empty prompts; `NA` and
#'   empty strings (`""`) are rejected. `names(prompts)` are retained on the
#'   `prompts` attribute.
#' @param layers `NULL` (default: every block) or a vector of 1-based block indices
#'   to capture (each in `1:m$layers`).
#' @param positions Which token positions to capture: `"last"` (default, the last
#'   token of each prompt), `"all"`, or a vector of 1-based positions.
#' @param components A subset of `c("residual", "attn_out", "mlp_out")`
#'   (default `"residual"`): the residual stream, the attention sub-layer output
#'   (after the output projection; TransformerLens `hook_attn_out`), and/or the MLP
#'   sub-layer output. `"attn_out"` is currently observable only on llama-family
#'   models; on architectures that do not name the post-projection output (e.g.
#'   qwen2, gemma3) requesting it raises `rebirth_error_trace` listing the available
#'   components rather than silently substituting a different tensor.
#' @param spill Single logical (default `TRUE`). When a capture exceeds the memory
#'   budget, `TRUE` streams it to a disk file (a lazily-loaded spilled trace) and
#'   `FALSE` raises `rebirth_error_oom` instead. A within-budget capture is always
#'   held in memory regardless of this flag.
#' @param spill_dir `NULL` (default: a managed per-session directory under the user
#'   cache, cleaned up when the session ends) or a single directory path in which to
#'   write spill files (left in place for you to manage).
#' @return A `rebirth_trace`: a `data.frame` (class `c("rebirth_trace",
#'   "data.frame")`) with the seven columns above, carrying `model`, `spilled`,
#'   `spill_files`, and `prompts` attributes. When `spilled` is `TRUE` the rows live
#'   in `spill_files` (read on demand by [as.matrix.rebirth_trace()]) rather than in
#'   the frame. See [as.matrix.rebirth_trace()] to extract one `(layer, component)`
#'   slice as a numeric matrix.
#' @seealso [llm()], [llm_embed()], [as.matrix.rebirth_trace()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' tr <- llm_trace(m, c("The cat sat.", "Quarks bind."), layers = 1:4)
#' tr
#' summary(tr)
#' x <- as.matrix(tr, layer = 1, component = "residual")
#' dim(x)
#' close(m)
#' @export
llm_trace <- function(m, prompts, layers = NULL, positions = "last",
                      components = "residual", spill = TRUE, spill_dir = NULL) {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)

  if (!is.character(prompts) || length(prompts) == 0L || anyNA(prompts)) {
    abort_argument("prompts", "`prompts` must be a non-empty character vector without NA.")
  }
  if (any(!nzchar(prompts))) {
    abort_argument(
      "prompts",
      "`prompts` must not contain empty strings (\"\"); every prompt needs text to trace."
    )
  }

  if (!is.null(layers)) {
    if (!is.numeric(layers) || length(layers) == 0L || anyNA(layers) ||
      any(!is.finite(layers)) || any(layers != round(layers)) ||
      any(layers < 1L) || any(layers > m$layers)) {
      abort_argument(
        "layers",
        sprintf("`layers` must be NULL (all blocks) or integers in 1:%d.", m$layers)
      )
    }
    layers <- as.integer(layers)
  }

  positions <- validate_positions(positions)

  if (!is.character(components) || length(components) == 0L || anyNA(components) ||
    !all(components %in% c("residual", "attn_out", "mlp_out"))) {
    abort_argument(
      "components",
      "`components` must be a non-empty subset of \"residual\", \"attn_out\", \"mlp_out\"."
    )
  }

  if (!is.logical(spill) || length(spill) != 1L || is.na(spill)) {
    abort_argument("spill", "`spill` must be a single logical value (TRUE or FALSE).")
  }
  if (!is.null(spill_dir) &&
    (!is.character(spill_dir) || length(spill_dir) != 1L || is.na(spill_dir))) {
    abort_argument("spill_dir", "`spill_dir` must be NULL or a single directory path.")
  }

  # Predictive OOM for spill = FALSE (the 16 GB rule): the length-known filters are
  # estimated here, BEFORE any allocation or tokenization, so an over-budget refusal
  # needs no engine (provable with a stub handle). spill = TRUE proceeds to the
  # engine, which streams the capture to disk; positions = "all" is estimated
  # authoritatively in the engine (it has the per-prompt token counts). See
  # check_trace_budget().
  budget <- trace_budget()
  check_trace_budget(m, prompts, layers, positions, components, spill, budget)

  # Cross the boundary (1-based -> 0-based happens in rebirth-ffi): NULL layers is
  # the empty-vector "all" sentinel; positions is a mode + explicit values. The
  # spill strings are authored here, since R owns the session spill directory: a
  # fresh per-session file path plus the model path, a per-trace id, and a canonical
  # capture-spec key for the file's integrity footer (the staleness fail-safe on
  # reopen). They are inert unless the engine decides to spill.
  layers_arg <- if (is.null(layers)) integer(0) else as.integer(layers)
  positions_mode <- if (is.character(positions)) positions else "explicit"
  positions_values <- if (is.character(positions)) integer(0) else as.integer(positions)

  spec_key <- trace_spec_key(m, layers, positions, components)
  spill_path <- if (isTRUE(spill)) next_spill_path(spill_dir) else ""
  trace_id <- if (nzchar(spill_path)) basename(spill_path) else ""

  payload <- rebirth_check(rebirth_trace(
    m$ptr, as.character(prompts), layers_arg,
    positions_mode, positions_values, as.character(components),
    spill, as.double(budget), spill_path, m$path, trace_id, spec_key
  ))

  if (isTRUE(payload$spilled)) {
    new_spilled_trace(payload, m, prompts, spec_key)
  } else {
    new_inmemory_trace(payload, m, prompts)
  }
}

# Assemble an in-memory `rebirth_trace` from the seven long-format columns the
# boundary returns (the in-budget path).
new_inmemory_trace <- function(payload, m, prompts) {
  df <- data.frame(
    prompt_id = payload$prompt_id,
    token_pos = payload$token_pos,
    token = payload$token,
    layer = payload$layer,
    component = payload$component,
    neuron = payload$neuron,
    value = payload$value,
    stringsAsFactors = FALSE
  )
  structure(
    df,
    class = c("rebirth_trace", "data.frame"),
    model = m$path,
    spilled = FALSE,
    spill_files = NULL,
    prompts = prompts
  )
}

# Assemble a spilled `rebirth_trace`: an empty (zero-row) data.frame with the exact
# seven columns, carrying the spill file path plus the capture's dimensions in
# attributes so print()/summary() report the trace without loading it. as.matrix()
# reads the requested slice lazily from `spill_files`. `spec_key` is stored for the
# staleness check performed against the file's footer on read.
new_spilled_trace <- function(payload, m, prompts, spec_key) {
  empty <- data.frame(
    prompt_id = integer(0),
    token_pos = integer(0),
    token = character(0),
    layer = integer(0),
    component = character(0),
    neuron = integer(0),
    value = double(0),
    stringsAsFactors = FALSE
  )
  structure(
    empty,
    class = c("rebirth_trace", "data.frame"),
    model = m$path,
    spilled = TRUE,
    spill_files = as.character(payload$spill_path),
    prompts = prompts,
    spill_layers = as.integer(payload$layers),
    spill_positions = as.integer(payload$positions),
    spill_components = as.character(payload$components),
    spill_n_rows = as.double(payload$n_rows),
    spill_n_positions = as.double(payload$n_positions),
    spill_n_embd = as.integer(payload$n_embd),
    spill_trace_id = as.character(payload$trace_id),
    spill_spec = as.character(spec_key)
  )
}

# A canonical capture-spec string identifying this trace, written into the spill
# file's integrity footer and stored on the object. On reopen, a file whose footer
# spec differs from the object's (a stale or replaced file) is rejected. Built to
# be reproducible from the object's own attributes so the two always agree.
trace_spec_key <- function(m, layers, positions, components) {
  layers_str <- if (is.null(layers)) {
    "all"
  } else {
    paste(sort(unique(as.integer(layers))), collapse = ",")
  }
  positions_str <- if (is.character(positions)) {
    positions
  } else {
    paste(sort(unique(as.integer(positions))), collapse = ",")
  }
  components_str <- paste(sort(unique(components)), collapse = ",")
  sprintf(
    "model=%s|layers=%s|positions=%s|components=%s",
    m$path, layers_str, positions_str, components_str
  )
}

# Validate the `positions` argument and return it unchanged ("last"/"all" or a
# numeric vector of 1-based positions). Raises rebirth_error_argument otherwise.
validate_positions <- function(positions, call = sys.call(-1L)) {
  if (is.character(positions)) {
    if (length(positions) != 1L || is.na(positions) ||
      !(positions %in% c("last", "all"))) {
      abort_argument(
        "positions",
        "`positions` must be \"last\", \"all\", or a vector of positive integer positions.",
        call = call
      )
    }
  } else if (is.numeric(positions)) {
    if (length(positions) == 0L || anyNA(positions) || any(!is.finite(positions)) ||
      any(positions != round(positions)) || any(positions < 1L)) {
      abort_argument(
        "positions",
        "`positions` positions must be positive whole numbers (1-based).",
        call = call
      )
    }
  } else {
    abort_argument(
      "positions",
      "`positions` must be \"last\", \"all\", or a vector of positive integer positions.",
      call = call
    )
  }
  positions
}

# The in-memory capture budget in bytes: an explicit option wins; otherwise
# min(2 GB, 20% of system RAM), falling back to the 2 GB cap when RAM is unknown.
trace_budget <- function() {
  opt <- getOption("rebirth.trace_budget")
  if (!is.null(opt) && is.numeric(opt) && length(opt) == 1L && !is.na(opt) && opt > 0) {
    return(as.double(opt))
  }
  cap <- 2 * 1024^3
  ram <- system_ram_bytes()
  if (is.na(ram)) cap else min(cap, 0.2 * ram)
}

# Best-effort total system RAM in bytes, or NA when it cannot be determined
# (never errors -- the caller then uses the 2 GB cap). Only consulted when the
# rebirth.trace_budget option is unset.
system_ram_bytes <- function() {
  ram <- tryCatch(
    {
      sysname <- Sys.info()[["sysname"]]
      if (identical(sysname, "Darwin")) {
        as.double(system2("sysctl", c("-n", "hw.memsize"), stdout = TRUE, stderr = FALSE))
      } else if (identical(sysname, "Linux") && file.exists("/proc/meminfo")) {
        line <- grep("^MemTotal:", readLines("/proc/meminfo", warn = FALSE), value = TRUE)
        as.double(gsub("[^0-9]", "", line[1])) * 1024 # kB -> bytes
      } else {
        NA_real_
      }
    },
    error = function(e) NA_real_,
    warning = function(e) NA_real_
  )
  if (length(ram) != 1L || is.na(ram) || !is.finite(ram) || ram <= 0) NA_real_ else ram
}

# Predictive OOM guard for spill = FALSE: estimate the capture's in-memory size
# from the resolved filters and raise rebirth_error_oom (with estimate_bytes)
# before any allocation when it exceeds the budget. spill = TRUE proceeds to the
# engine, which streams to disk instead. `positions = "all"` is deferred to the
# engine (it has the per-prompt token counts), which raises the same class before
# allocating when spill = FALSE.
check_trace_budget <- function(m, prompts, layers, positions, components, spill, budget,
                               call = sys.call(-1L)) {
  if (isTRUE(spill)) {
    return(invisible(NULL)) # spill: the engine decides memory-vs-disk (never OOM).
  }
  n_positions <- if (is.character(positions)) {
    if (identical(positions, "last")) 1L else NA_integer_ # "all": needs token counts
  } else {
    length(positions)
  }
  if (is.na(n_positions)) {
    return(invisible(NULL)) # "all" + spill = FALSE: the engine estimates and refuses.
  }

  n_layers <- if (is.null(layers)) m$layers else length(layers)
  estimate <- as.double(length(prompts)) * n_positions * n_layers *
    length(components) * m$hidden_size * 4
  if (estimate <= budget) {
    return(invisible(NULL))
  }

  rebirth_abort(
    "rebirth_error_oom",
    sprintf(
      paste0(
        "This trace would need about %s in memory, over the %s budget. ",
        "Capture less -- set positions = \"last\", narrow `layers` to a band, or ",
        "drop components -- set spill = TRUE to stream it to disk, or raise ",
        "options(rebirth.trace_budget=)."
      ),
      format_bytes(estimate), format_bytes(budget)
    ),
    list(estimate_bytes = estimate, budget_bytes = budget),
    call = call
  )
}

# Compact index-set display for print(): a single value, a contiguous "a-b" range,
# a short comma list, or a count with the range for large sets. Never the data.
format_index_set <- function(v) {
  if (length(v) == 0L) {
    return("none")
  }
  v <- sort(unique(v))
  if (length(v) == 1L) {
    return(as.character(v))
  }
  if (identical(as.integer(v), seq.int(v[1], v[length(v)]))) {
    sprintf("%d-%d", v[1], v[length(v)])
  } else if (length(v) <= 8L) {
    paste(v, collapse = ", ")
  } else {
    sprintf("%d values in %d-%d", length(v), v[1], v[length(v)])
  }
}

# The trace's dimensions for print()/summary(): drawn from the columns for an
# in-memory trace, or from the attributes for a spilled one — so neither method
# ever loads a spilled file. `n_rows` is a double (a full trace can exceed 2^31).
trace_dims <- function(x) {
  if (isTRUE(attr(x, "spilled"))) {
    list(
      n_rows = as.double(attr(x, "spill_n_rows")),
      layers = as.integer(attr(x, "spill_layers")),
      positions = as.integer(attr(x, "spill_positions")),
      components = as.character(attr(x, "spill_components"))
    )
  } else {
    list(
      n_rows = as.double(nrow(x)),
      layers = x$layer,
      positions = x$token_pos,
      components = unique(x$component)
    )
  }
}

#' @param x A `rebirth_trace` (for `print`/`as.matrix`) or its `summary`.
#' @param ... Ignored.
#' @return `print` returns its argument invisibly.
#' @rdname llm_trace
#' @method print rebirth_trace
#' @export
print.rebirth_trace <- function(x, ...) {
  spilled <- isTRUE(attr(x, "spilled"))
  d <- trace_dims(x)
  cat(sprintf(
    "<rebirth_trace> %s activation rows\n",
    format(d$n_rows, scientific = FALSE, big.mark = "")
  ))
  cat(sprintf("  prompts:    %d\n", length(attr(x, "prompts"))))
  cat(sprintf("  layers:     %s\n", format_index_set(d$layers)))
  cat(sprintf("  positions:  %s\n", format_index_set(d$positions)))
  cat(sprintf("  components: %s\n", paste(unique(d$components), collapse = ", ")))
  if (spilled) {
    cat(sprintf("  spilled:    TRUE -> %s\n", attr(x, "spill_files")))
  } else {
    cat("  spilled:    FALSE\n")
  }
  invisible(x)
}

#' @param object A `rebirth_trace`.
#' @return `summary` returns a `data.frame` (class `summary.rebirth_trace`) with one
#'   row per captured `(layer, component)` group: its `n` and mean `|value|`. For a
#'   spilled trace, `mean_abs` is `NA` (reporting it would force a data load); use
#'   [as.matrix.rebirth_trace()] to read a slice.
#' @rdname llm_trace
#' @method summary rebirth_trace
#' @export
summary.rebirth_trace <- function(object, ...) {
  if (isTRUE(attr(object, "spilled"))) {
    return(summary_spilled_trace(object))
  }
  groups <- unique(object[c("layer", "component")])
  groups <- groups[order(groups$layer, groups$component), , drop = FALSE]
  n <- integer(nrow(groups))
  mean_abs <- numeric(nrow(groups))
  for (i in seq_len(nrow(groups))) {
    sel <- object$layer == groups$layer[i] & object$component == groups$component[i]
    n[i] <- sum(sel)
    mean_abs[i] <- mean(abs(object$value[sel]))
  }
  out <- data.frame(
    layer = as.integer(groups$layer),
    component = as.character(groups$component),
    n = n,
    mean_abs = mean_abs,
    stringsAsFactors = FALSE
  )
  structure(
    out,
    class = c("summary.rebirth_trace", "data.frame"),
    spilled = FALSE
  )
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

#' @rdname llm_trace
#' @method print summary.rebirth_trace
#' @export
print.summary.rebirth_trace <- function(x, ...) {
  spilled <- isTRUE(attr(x, "spilled"))
  cat(sprintf("<rebirth_trace summary> %d layer x component groups\n", nrow(x)))
  cat("  n and mean |value| per group:\n")
  print(as.data.frame(x), row.names = FALSE)
  cat(sprintf("  storage: %s\n", if (spilled) "spilled (mean |value| via as.matrix())" else "in memory"))
  invisible(x)
}

#' Extract one activation slice as a matrix
#'
#' Pulls a single `(layer, component)` slice out of a [llm_trace()] result as a
#' base numeric `matrix`: one row per captured `(prompt_id, token_pos)` and one
#' column per neuron (`hidden_size` wide). Row names are `"<prompt_id>.<token_pos>"`.
#' This is the bridge from the long-format trace to matrix tools such as
#' [stats::prcomp()].
#'
#' @param x A `rebirth_trace` from [llm_trace()].
#' @param layer Required single 1-based layer index; it must be present in the trace.
#' @param component Single component name (default `"residual"`); it must be present
#'   in the trace.
#' @param ... Ignored.
#' @return A numeric `matrix`, rows = captured `(prompt_id, token_pos)` (row names
#'   `"<prompt_id>.<token_pos>"`), columns = neurons.
#' @seealso [llm_trace()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' tr <- llm_trace(m, "The cat sat.", layers = 1:2)
#' as.matrix(tr, layer = 1, component = "residual")
#' close(m)
#' @method as.matrix rebirth_trace
#' @export
as.matrix.rebirth_trace <- function(x, layer, component = "residual", ...) {
  if (missing(layer)) {
    abort_argument(
      "layer",
      "`layer` is required: as.matrix() extracts one (layer, component) slice of a trace."
    )
  }
  if (!is.numeric(layer) || length(layer) != 1L || is.na(layer)) {
    abort_argument("layer", "`layer` must be a single layer index.")
  }
  if (!is.character(component) || length(component) != 1L || is.na(component)) {
    abort_argument("component", "`component` must be a single component name.")
  }

  # The slice's (prompt_id, token_pos, neuron, value) rows, from memory or — for a
  # spilled trace — read lazily from the file's matching (prompt, layer) batches.
  if (isTRUE(attr(x, "spilled"))) {
    sub <- read_spill_slice(x, layer, component)
  } else {
    keep <- x[x$layer == layer & x$component == component, , drop = FALSE]
    sub <- data.frame(
      prompt_id = keep$prompt_id, token_pos = keep$token_pos,
      neuron = keep$neuron, value = keep$value, stringsAsFactors = FALSE
    )
  }
  if (nrow(sub) == 0L) {
    d <- trace_dims(x)
    abort_argument(
      "layer",
      sprintf(
        "No captured activations for layer %s, component \"%s\". The trace holds layers %s and components %s.",
        layer, component,
        paste(sort(unique(d$layers)), collapse = ", "),
        paste(unique(d$components), collapse = ", ")
      )
    )
  }

  sub <- sub[order(sub$prompt_id, sub$token_pos, sub$neuron), , drop = FALSE]
  pts <- unique(sub[c("prompt_id", "token_pos")])
  pts <- pts[order(pts$prompt_id, pts$token_pos), , drop = FALSE]
  n_neuron <- length(unique(sub$neuron))
  mat <- matrix(sub$value, nrow = nrow(pts), ncol = n_neuron, byrow = TRUE)
  rownames(mat) <- sprintf("%d.%d", pts$prompt_id, pts$token_pos)
  mat
}

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
  stream <- nanoarrow::read_nanoarrow(path, lazy = TRUE)
  parts <- list()
  repeat {
    batch <- stream$get_next()
    if (is.null(batch)) break
    df <- as.data.frame(batch)
    sel <- df$layer == engine_layer & df$component == component
    if (any(sel)) {
      parts[[length(parts) + 1L]] <- df[sel, c("prompt_id", "token_pos", "neuron", "value")]
    }
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
# confirm its integrity footer (schema metadata) matches the trace object. A file
# from a different rebirth version (format), or one overwritten by a later trace or
# belonging to another session (spec), is rejected rather than silently misread.
verify_spill_integrity <- function(x, path) {
  md <- tryCatch(
    nanoarrow::read_nanoarrow(path, lazy = TRUE)$get_schema()$metadata,
    error = function(e) NULL
  )
  fmt <- if (is.null(md)) NULL else md[["rebirth.spill_format"]]
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
  if (is.null(spec) || !identical(as.character(spec), as.character(attr(x, "spill_spec")))) {
    rebirth_abort(
      "rebirth_error_trace",
      sprintf(
        paste0(
          "The spill file '%s' does not match this trace object: its capture spec ",
          "differs, so it was likely overwritten by a later trace or belongs to a ",
          "different session. Re-run llm_trace()."
        ),
        path
      )
    )
  }
  invisible(TRUE)
}
