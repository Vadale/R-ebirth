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
#' Before running, the in-memory size is estimated from the filters; if it exceeds
#' the budget (`min(2 GB, 20% of RAM)`, overridable with
#' `options(rebirth.trace_budget = <bytes>)`) the call raises `rebirth_error_oom`
#' *before* any allocation, its `estimate_bytes` field stating the estimate.
#' Streaming an over-budget capture to disk (`spill = TRUE`) is not yet available
#' and currently raises the same predictive `rebirth_error_oom`.
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
#' @param spill Single logical (default `TRUE`). Reserved for the disk-spill path;
#'   until it lands, an over-budget capture raises `rebirth_error_oom` regardless of
#'   this flag.
#' @param spill_dir `NULL` or a single directory path for spill files (reserved).
#' @return A `rebirth_trace`: a `data.frame` (class `c("rebirth_trace",
#'   "data.frame")`) with the seven columns above, carrying `model`, `spilled`,
#'   `spill_files`, and `prompts` attributes. See [as.matrix.rebirth_trace()] to
#'   extract one `(layer, component)` slice as a numeric matrix.
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

  # Predictive OOM, BEFORE any allocation or tokenization (the 16 GB rule): from
  # metadata + the resolved filters. `positions = "last"` is length-independent;
  # an explicit vector's length is known; `positions = "all"` needs per-prompt token
  # counts, so its precise estimate arrives with the Step-5 spill writer.
  check_trace_budget(m, prompts, layers, positions, components, spill)

  # Cross the boundary (1-based -> 0-based happens in rebirth-ffi): NULL layers is
  # the empty-vector "all" sentinel; positions is a mode + explicit values.
  layers_arg <- if (is.null(layers)) integer(0) else as.integer(layers)
  positions_mode <- if (is.character(positions)) positions else "explicit"
  positions_values <- if (is.character(positions)) integer(0) else as.integer(positions)

  payload <- rebirth_check(rebirth_trace(
    m$ptr, as.character(prompts), layers_arg,
    positions_mode, positions_values, as.character(components)
  ))

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

# Predictive OOM guard: estimate the capture's in-memory size from the resolved
# filters and raise rebirth_error_oom (with estimate_bytes) before any allocation
# when it exceeds the budget. `positions = "all"` is deferred to the Step-5 spill
# writer, which computes the per-prompt token counts.
check_trace_budget <- function(m, prompts, layers, positions, components, spill,
                               call = sys.call(-1L)) {
  n_positions <- if (is.character(positions)) {
    if (identical(positions, "last")) 1L else NA_integer_ # "all": needs token counts
  } else {
    length(positions)
  }
  if (is.na(n_positions)) {
    return(invisible(NULL)) # TODO(WP4 Step 5): estimate "all" from tokenized lengths.
  }

  n_layers <- if (is.null(layers)) m$layers else length(layers)
  estimate <- as.double(length(prompts)) * n_positions * n_layers *
    length(components) * m$hidden_size * 4
  budget <- trace_budget()
  if (estimate <= budget) {
    return(invisible(NULL))
  }

  # Over budget. The Arrow-IPC spill writer is WP4 Step 5; until it lands, an
  # over-budget capture aborts for BOTH spill = TRUE and spill = FALSE rather than
  # risk OOMing the session.
  # TODO(WP4 Step 5): when spill = TRUE, stream to Arrow IPC instead of aborting.
  rebirth_abort(
    "rebirth_error_oom",
    sprintf(
      paste0(
        "This trace would need about %s in memory, over the %s budget. ",
        "Capture less -- set positions = \"last\", narrow `layers` to a band, or ",
        "drop components -- or raise options(rebirth.trace_budget=)."
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

#' @param x A `rebirth_trace` (for `print`/`as.matrix`) or its `summary`.
#' @param ... Ignored.
#' @return `print` returns its argument invisibly.
#' @rdname llm_trace
#' @method print rebirth_trace
#' @export
print.rebirth_trace <- function(x, ...) {
  spilled <- isTRUE(attr(x, "spilled"))
  cat(sprintf("<rebirth_trace> %d activation rows\n", nrow(x)))
  cat(sprintf("  prompts:    %d\n", length(attr(x, "prompts"))))
  cat(sprintf("  layers:     %s\n", format_index_set(x$layer)))
  cat(sprintf("  positions:  %s\n", format_index_set(x$token_pos)))
  cat(sprintf("  components: %s\n", paste(unique(x$component), collapse = ", ")))
  cat(sprintf("  spilled:    %s\n", if (spilled) "TRUE" else "FALSE"))
  invisible(x)
}

#' @param object A `rebirth_trace`.
#' @return `summary` returns a `data.frame` (class `summary.rebirth_trace`) with one
#'   row per captured `(layer, component)` group: its `n` and mean `|value|`.
#' @rdname llm_trace
#' @method summary rebirth_trace
#' @export
summary.rebirth_trace <- function(object, ...) {
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
    spilled = isTRUE(attr(object, "spilled"))
  )
}

#' @rdname llm_trace
#' @method print summary.rebirth_trace
#' @export
print.summary.rebirth_trace <- function(x, ...) {
  cat(sprintf("<rebirth_trace summary> %d layer x component groups\n", nrow(x)))
  cat("  n and mean |value| per group:\n")
  print(as.data.frame(x), row.names = FALSE)
  cat(sprintf("  storage: %s\n", if (isTRUE(attr(x, "spilled"))) "spilled" else "in memory"))
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

  sub <- x[x$layer == layer & x$component == component, , drop = FALSE]
  if (nrow(sub) == 0L) {
    abort_argument(
      "layer",
      sprintf(
        "No captured activations for layer %s, component \"%s\". The trace holds layers %s and components %s.",
        layer, component,
        paste(sort(unique(x$layer)), collapse = ", "),
        paste(unique(x$component), collapse = ", ")
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
