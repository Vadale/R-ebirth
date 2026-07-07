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
#' Before running, the size of the `data.frame` you would receive is estimated from
#' the filters (the materialized-object cost, D-017). If it fits the budget
#' (`min(2 GB, 20% of RAM)`, overridable with
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
#' Tracing an **intervened** handle (from [llm_steer()]/[llm_ablate()]) raises
#' `rebirth_error_trace`: interventions currently apply to generation and logits
#' only, and the trace context does not inherit them, so tracing would capture the
#' base (un-intervened) forward pass while labeling it intervened. Trace the
#' original handle.
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
  guard_not_intervened(
    m, "rebirth_error_trace",
    "Tracing an intervened handle is not yet supported"
  )

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
  # De-duplicate components (M-1): a repeated component (e.g. c("residual",
  # "residual")) would otherwise double-count its (layer, component) groups in the
  # capture and the spilled summary. First-occurrence order is preserved.
  components <- unique(components)

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

  spec_key <- trace_spec_key(m, prompts, layers, positions, components)
  spill_path <- if (isTRUE(spill)) next_spill_path(spill_dir) else ""
  trace_id <- if (nzchar(spill_path)) next_trace_id() else ""

  payload <- rebirth_check(rebirth_trace(
    m$ptr, as.character(prompts), layers_arg,
    positions_mode, positions_values, as.character(components),
    spill, as.double(budget), spill_path, m$path, trace_id, spec_key
  ))

  # API-GRAMMAR section 4: an explicit `positions` vector is recycled per prompt,
  # with a warning if lengths differ. The engine -- which knows each prompt's token
  # count -- reports whether any explicit position fell out of range for some prompt;
  # warn once when it did. Keyword positions ("last"/"all") never warn: they are not
  # numeric here, and the engine reports FALSE for them.
  if (!is.character(positions) && isTRUE(payload$positions_recycled)) {
    warning(
      "An explicit `positions` vector was recycled across prompts of differing ",
      "lengths; some positions were out of range for the shorter prompts and were ",
      "dropped (no rows for those prompt/position pairs). Pass positions within the ",
      "shortest prompt's length, or use positions = \"all\".",
      call. = FALSE
    )
  }

  if (isTRUE(payload$spilled)) {
    new_spilled_trace(payload, m, prompts, spec_key)
  } else {
    new_inmemory_trace(payload, m, prompts)
  }
}

# Assemble an in-memory `rebirth_trace` from the boundary payload (the in-budget
# path). The numeric columns arrive fully expanded; `token`/`component` arrive
# INTERNED (D-017) -- each distinct label once (a levels table) plus a per-row
# 1-based code and per-row neuron count -- and are re-expanded here to the exact
# per-neuron character columns via rep.int(). rep.int()/`[` reuse R's CHARSXPs, so
# the columns are byte-identical to a per-neuron Rust expansion while the boundary
# no longer clones a String per neuron (the audit's ~30x transient peak, H-1).
new_inmemory_trace <- function(payload, m, prompts) {
  times <- payload$row_nneuron
  token <- payload$token_levels[rep.int(payload$token_codes, times)]
  component <- payload$component_levels[rep.int(payload$component_codes, times)]
  df <- data.frame(
    prompt_id = payload$prompt_id,
    token_pos = payload$token_pos,
    token = token,
    layer = payload$layer,
    component = component,
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

# A content digest of the exact prompts traced, so a spill file's spec key changes
# with the prompts, not just the filters (M-2). serialize() gives an unambiguous
# byte image of the character vector (no delimiter collisions between prompts, and
# NA/encoding-faithful); tools::md5sum() over it -- the only base-R md5 entry, so no
# added dependency -- yields a compact, low-collision, deterministic fingerprint.
prompts_digest <- function(prompts) {
  tf <- tempfile("rebirth-prompts-")
  on.exit(unlink(tf), add = TRUE)
  writeBin(serialize(as.character(prompts), connection = NULL), tf)
  unname(tools::md5sum(tf))
}

# A canonical capture-spec string identifying this trace, written into the spill
# file's integrity footer and stored on the object. On reopen, a file whose footer
# spec differs from the object's (a stale or replaced file) is rejected. Built to
# be reproducible from the object's own inputs so the two always agree. Includes a
# digest of the prompts and the model file's size (M-2): two traces that share
# filters but differ in prompts -- or run against a different model file swapped in
# at the same path -- get different keys, so one cannot be misread as the other.
trace_spec_key <- function(m, prompts, layers, positions, components) {
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
  # Model file size distinguishes a different model swapped in at the same path; NA
  # (file unreadable) degrades to a literal "NA" rather than erroring.
  model_size <- tryCatch(file.size(m$path), error = function(e) NA_real_)
  size_str <- if (length(model_size) != 1L || is.na(model_size)) {
    "NA"
  } else {
    format(model_size, scientific = FALSE, trim = TRUE)
  }
  sprintf(
    "model=%s|size=%s|layers=%s|positions=%s|components=%s|prompts=%s",
    m$path, size_str, layers_str, positions_str, components_str, prompts_digest(prompts)
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
    # De-duplicate explicit positions (M-1): a repeated position would otherwise
    # emit duplicate capture rows, which as.matrix() then mis-assembles into a
    # wrong matrix under correct labels. Sorting is harmless -- capture is
    # per-position and the matrix is re-sorted by (prompt_id, token_pos). This also
    # keeps the predictive-OOM `length(positions)` and the spec_key exact.
    return(sort(unique(as.integer(positions))))
  } else {
    abort_argument(
      "positions",
      "`positions` must be \"last\", \"all\", or a vector of positive integer positions.",
      call = call
    )
  }
  positions
}

# The expansion factor from an f32 activation's engine bytes to its peak resident
# cost in the returned long-format data.frame (D-017). Each captured value becomes
# one 40-byte row -- four i32 columns (prompt_id/token_pos/layer/neuron), one f64
# `value`, and two character-pointer columns (token/component into R's shared CHARSXP
# pool) -- i.e. 10x the 4-byte f32; 11 upper-bounds the measured ratio (10.40x on a
# small trace, asymptote 10.0x) with headroom for R's fixed per-vector + data.frame
# overhead. The engine pins the identical value in TRACE_MATERIALIZED_EXPANSION
# (trace.rs), each side unit-tested, so the R pre-check and the engine spill decision
# stay symmetric (audit P-5); the object.size test (test-llm-trace-spill.R) pins it
# against a real materialized trace.
TRACE_MATERIALIZED_EXPANSION <- 11L

# The default in-memory budget cap: 2 GB of materialized data.frame (D-017). Via the
# expansion factor above that is ~180 MB of f32 activations resident -- a full
# small-model trace stays in memory while a genuinely large capture spills, all
# within the 16 GB target. This restores an accurate, usable in-memory budget,
# superseding the interim 256 MB stopgap (which gated the pre-D-017 f32-basis
# estimate that under-counted the real object ~10x).
TRACE_BUDGET_DEFAULT_CAP <- 2 * 1024^3

# The in-memory capture budget in bytes of the materialized data.frame: an explicit
# option wins; otherwise min(2 GB, 20% of system RAM), falling back to the 2 GB cap
# when RAM is unknown.
trace_budget <- function() {
  opt <- getOption("rebirth.trace_budget")
  if (!is.null(opt) && is.numeric(opt) && length(opt) == 1L && !is.na(opt) && opt > 0) {
    return(as.double(opt))
  }
  # D-017: the estimate this budget gates is the materialized data.frame cost
  # (TRACE_MATERIALIZED_EXPANSION x the f32 activation bytes), so this cap is a real
  # materialized-memory ceiling, not the f32-buffer under-count that let an
  # "in-budget" capture OOM the 16 GB session (audit H-1).
  cap <- TRACE_BUDGET_DEFAULT_CAP
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
  # D-017: budget on the materialized data.frame cost (K x the f32 activation bytes),
  # not the f32 bytes alone (the H-1 under-count). The engine's estimate_capture_bytes
  # applies the identical factor, so this R pre-check and the engine's spill decision
  # agree on whether a capture fits.
  f32_bytes <- as.double(length(prompts)) * n_positions * n_layers *
    length(components) * m$hidden_size * 4
  estimate <- f32_bytes * TRACE_MATERIALIZED_EXPANSION
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
  # Structural invariant: the slice must be a full (prompt_id, token_pos) x neuron
  # grid, i.e. exactly one value per cell. If it is not, matrix(byrow = TRUE) would
  # silently recycle/mis-assemble the values under correct row/column labels (the
  # M-1 duplicate-row failure). Positions and components are de-duplicated upstream,
  # so a mismatch here means an unexpected duplicate reached the frame -- fail loud
  # rather than return a wrong matrix.
  if (nrow(sub) != nrow(pts) * n_neuron) {
    rebirth_abort(
      "rebirth_error_trace",
      sprintf(
        paste0(
          "This trace slice (layer %s, component \"%s\") holds %d rows, not the ",
          "expected %d (%d position(s) x %d neurons): it has duplicate or missing ",
          "(position, neuron) entries and cannot be reshaped to a matrix. Re-run ",
          "llm_trace()."
        ),
        layer, component, nrow(sub), nrow(pts) * n_neuron, nrow(pts), n_neuron
      )
    )
  }
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
