#' Load a local large language model
#'
#' Loads a GGUF model file and returns an `llm` handle: an external pointer to
#' the native model plus its metadata. All arguments are validated in R before
#' the native boundary is crossed, so a bad request is reported as a classed
#' condition and never reaches the engine.
#'
#' @details
#' The handle owns native memory (potentially several gigabytes). Free it
#' deterministically with [close()][close.llm] when done; a garbage-collection
#' finalizer frees it as a safety net otherwise (see [close.llm()]).
#'
#' `backend = "auto"` resolves to the fastest backend this build supports
#' (Metal on Apple silicon, otherwise CPU). Requesting a backend the build was
#' not compiled with raises `rebirth_error_backend`.
#'
#' No model ships inside the package yet, so the runnable example is guarded by
#' the `REBIRTH_TEST_MODEL_QWEN` environment variable (point it at a local
#' Qwen2.5 GGUF to run it). A tiny in-repo model arrives in a later work
#' package.
#'
#' @param path Single string: path to a GGUF model file.
#' @param context_length Positive integer: the active context window in tokens
#'   (llama.cpp: `n_ctx`). Default 4096.
#' @param gpu_layers `NULL` (auto: offload every layer that fits) or a single
#'   non-negative integer count of layers to offload (llama.cpp:
#'   `n_gpu_layers`). Ignored on the CPU backend.
#' @param backend One of `"auto"`, `"metal"`, `"cuda"`, `"cpu"`.
#' @param mmap Logical: memory-map the model file (default `TRUE`).
#' @return An object of class `llm` (see the package's class documentation).
#' @seealso [close.llm()], [print.llm()], [summary.llm()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' print(m)
#' summary(m)
#' close(m)
#' @export
llm <- function(path,
                context_length = 4096,
                gpu_layers = NULL,
                backend = c("auto", "metal", "cuda", "cpu"),
                mmap = TRUE) {
  # --- path: a single, existing, readable, non-directory file ---
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    rebirth_abort(
      "rebirth_error_model_load",
      "`path` must be a single non-empty string naming a GGUF model file.",
      list(failing_check = "path_type")
    )
  }
  path <- path.expand(path)
  if (!file.exists(path)) {
    rebirth_abort(
      "rebirth_error_model_load",
      sprintf(
        "Model file not found at '%s'. Check the path, or download the model first.",
        path
      ),
      list(failing_check = "path_exists")
    )
  }
  if (dir.exists(path)) {
    rebirth_abort(
      "rebirth_error_model_load",
      sprintf("'%s' is a directory, not a GGUF file. Point `path` at the .gguf file.", path),
      list(failing_check = "path_is_directory")
    )
  }
  if (file.access(path, mode = 4L) != 0L) {
    rebirth_abort(
      "rebirth_error_model_load",
      sprintf("Model file '%s' is not readable. Check its file permissions.", path),
      list(failing_check = "path_readable")
    )
  }

  # --- context_length: a single positive integer ---
  if (!is_count(context_length) || context_length < 1L ||
    context_length > .Machine$integer.max) {
    rebirth_abort(
      "rebirth_error_argument",
      "`context_length` must be a single positive integer (the context window in tokens).",
      list(argument = "context_length")
    )
  }

  # --- gpu_layers: NULL, or a single non-negative integer ---
  if (!is.null(gpu_layers) &&
    (!is_count(gpu_layers) || gpu_layers < 0L || gpu_layers > .Machine$integer.max)) {
    rebirth_abort(
      "rebirth_error_argument",
      "`gpu_layers` must be NULL (auto) or a single non-negative integer.",
      list(argument = "gpu_layers")
    )
  }

  # --- mmap: a single non-NA logical ---
  if (!is.logical(mmap) || length(mmap) != 1L || is.na(mmap)) {
    rebirth_abort(
      "rebirth_error_argument",
      "`mmap` must be a single logical value (TRUE or FALSE).",
      list(argument = "mmap")
    )
  }

  # --- backend: a valid choice, resolved and checked against the build ---
  backend <- match.arg(backend)
  available <- rebirth_available_backends()
  if (identical(backend, "auto")) {
    backend <- if ("metal" %in% available) {
      "metal"
    } else if ("cuda" %in% available) {
      "cuda"
    } else {
      "cpu"
    }
  } else if (!(backend %in% available)) {
    available_str <- paste(available, collapse = ", ")
    rebirth_abort(
      "rebirth_error_backend",
      sprintf(
        paste0(
          "Backend '%s' is not available in this build (available: %s). ",
          "Re-run with backend = \"auto\" or one of the available backends."
        ),
        backend, available_str
      ),
      list(requested = backend, available = available_str)
    )
  }

  # --- cross the boundary: NULL gpu_layers is the -1 auto sentinel ---
  gpu_layers_arg <- if (is.null(gpu_layers)) -1L else as.integer(gpu_layers)
  payload <- rebirth_model_load(
    path, as.integer(context_length), gpu_layers_arg, backend, mmap
  )
  payload <- rebirth_check(payload)
  new_llm(payload, path)
}

# Build the `llm` S3 object from a successful load payload. The mutable closed
# tag lives in an environment (reference semantics) so `close()` on one binding
# is visible through every copy of the handle (ARCHITECTURE.md section 3).
# `interventions` is empty for a freshly loaded handle and carries the accumulated
# steering/ablation spec for a derived handle (llm_steer/llm_ablate, D-016); each
# handle gets its own `state` env + finalizer, so a derived handle frees its
# distinct native context independently of the source.
new_llm <- function(payload, path, interventions = list()) {
  state <- new.env(parent = emptyenv())
  state$closed <- FALSE
  state$ptr <- payload$ptr

  obj <- structure(
    list(
      ptr = payload$ptr,
      state = state,
      path = path,
      architecture = payload$architecture,
      parameters = payload$parameters,
      quantization = payload$quantization,
      layers = payload$layers,
      hidden_size = payload$hidden_size,
      context_length = payload$context_length,
      backend = payload$backend,
      interventions = interventions,
      # Extras surfaced by summary(), kept dot-prefixed to mark them as not part
      # of the API-GRAMMAR section 2 slot set.
      .context_train = payload$context_train,
      .size_bytes = payload$size_bytes,
      .vocab_size = payload$vocab_size,
      .description = payload$description
    ),
    class = "llm"
  )

  # GC / on-exit safety net (ARCHITECTURE.md section 3): free an un-close()d handle when
  # its state is collected or the session exits. Idempotent with both close()
  # and extendr's own external-pointer finalizer (the free is take-once and the
  # pointer is NULLed on finalize, so any order is safe).
  reg.finalizer(state, finalize_llm_state, onexit = TRUE)

  obj
}

finalize_llm_state <- function(state) {
  if (isFALSE(state$closed)) {
    try(rebirth_handle_close(state$ptr), silent = TRUE)
    state$closed <- TRUE
  }
  invisible(NULL)
}

# Raise `rebirth_error_closed` if the handle has been closed. The R-side flag is
# the authoritative closed tag every method consults first (ARCHITECTURE.md section 3).
ensure_open <- function(m, call = sys.call(-1L)) {
  if (isTRUE(m$state$closed)) {
    rebirth_abort(
      "rebirth_error_closed",
      "This model handle is closed. Load the model again with llm() to obtain a fresh handle.",
      call = call
    )
  }
  invisible(m)
}

#' Free a model handle
#'
#' Deterministically frees the native memory behind an `llm` handle. On a
#' memory-constrained machine this lets you release several gigabytes
#' immediately rather than waiting for garbage collection (the finalizer remains
#' the safety net). A double close is a no-op; any later use of the handle
#' raises `rebirth_error_closed`.
#'
#' @param con An `llm` handle.
#' @param ... Ignored (present for compatibility with the `close()` generic).
#' @return `invisible(NULL)`.
#' @method close llm
#' @seealso [llm()]
#' @export
close.llm <- function(con, ...) {
  if (isTRUE(con$state$closed)) {
    return(invisible(NULL))
  }
  rebirth_handle_close(con$ptr)
  con$state$closed <- TRUE
  invisible(NULL)
}

#' @param x An `llm` handle.
#' @param ... Ignored.
#' @return `x`, invisibly.
#' @rdname llm
#' @method print llm
#' @export
print.llm <- function(x, ...) {
  ensure_open(x)
  cat(sprintf("<llm> %s\n", basename(x$path)))
  cat(sprintf("  architecture:    %s\n", x$architecture))
  cat(sprintf("  parameters:      %s\n", format_params(x$parameters)))
  cat(sprintf("  quantization:    %s\n", x$quantization))
  cat(sprintf("  layers x hidden: %d x %d\n", x$layers, x$hidden_size))
  cat(sprintf("  context:         %d tokens\n", x$context_length))
  cat(sprintf("  backend:         %s\n", x$backend))
  cat(sprintf("  interventions:   %d active\n", length(x$interventions)))
  invisible(x)
}

#' Summarize a model handle
#'
#' Returns a classed list with the print-level metadata plus the model's memory
#' footprint, tokenizer (vocabulary) information, and the full list of active
#' interventions. Its own `print` method renders it.
#'
#' @param object An `llm` handle.
#' @param ... Ignored.
#' @return An object of class `summary.llm`.
#' @method summary llm
#' @export
summary.llm <- function(object, ...) {
  ensure_open(object)
  structure(
    list(
      path = object$path,
      architecture = object$architecture,
      parameters = object$parameters,
      quantization = object$quantization,
      layers = object$layers,
      hidden_size = object$hidden_size,
      context_length = object$context_length,
      context_train = object$.context_train,
      backend = object$backend,
      memory_footprint = object$.size_bytes,
      vocab_size = object$.vocab_size,
      description = object$.description,
      interventions = object$interventions
    ),
    class = "summary.llm"
  )
}

#' @param x A `summary.llm` object.
#' @param ... Ignored.
#' @return `x`, invisibly.
#' @rdname summary.llm
#' @method print summary.llm
#' @export
print.summary.llm <- function(x, ...) {
  cat(sprintf("<llm summary> %s\n", basename(x$path)))
  cat(sprintf("  architecture:    %s\n", x$architecture))
  cat(sprintf("  parameters:      %s\n", format_params(x$parameters)))
  cat(sprintf("  quantization:    %s\n", x$quantization))
  cat(sprintf("  layers x hidden: %d x %d\n", x$layers, x$hidden_size))
  cat(sprintf("  context:         %d tokens (trained: %d)\n", x$context_length, x$context_train))
  cat(sprintf("  backend:         %s\n", x$backend))
  cat(sprintf("  memory:          %s\n", format_bytes(x$memory_footprint)))
  cat(sprintf("  vocabulary:      %s tokens\n", format(x$vocab_size, big.mark = ",")))
  if (nzchar(x$description)) {
    cat(sprintf("  description:     %s\n", x$description))
  }
  n_iv <- length(x$interventions)
  cat(sprintf("  interventions:   %d active\n", n_iv))
  # The full intervention list (API-GRAMMAR section 2: summary adds it; print
  # shows only the count). One compact line per steer/ablate, no vector dumps.
  for (iv in x$interventions) {
    cat(sprintf("    - %s\n", format_intervention(iv)))
  }
  invisible(x)
}

# --- small internal helpers ------------------------------------------------

# A one-line human description of an intervention entry (llm_steer/llm_ablate),
# for summary(). Never dumps the direction vector -- only its length -- and uses
# the compact format_index_set() display for the ablated neuron set.
format_intervention <- function(iv) {
  if (identical(iv$kind, "steer")) {
    sprintf(
      "steer  layer %d  (coef %s, direction[%d], positions %s)",
      iv$layer, format(iv$coef), length(iv$direction), iv$positions
    )
  } else if (identical(iv$kind, "ablate")) {
    sprintf(
      "ablate layer %d  neurons %s -> %s  (%s)",
      iv$layer, format_index_set(iv$neurons), format(iv$value), iv$component
    )
  } else {
    sprintf("intervention (%s) at layer %s", as.character(iv$kind), as.character(iv$layer))
  }
}

# A single, whole, non-NA number (integer-valued, but stored as double or int).
is_count <- function(x) {
  is.numeric(x) && length(x) == 1L && !is.na(x) && x == round(x) && is.finite(x)
}

# Human-readable parameter count, e.g. 494 M, 1.5 B.
format_params <- function(n) {
  if (!is.finite(n)) {
    return("unknown")
  }
  if (n >= 1e9) {
    sprintf("%.1f B", n / 1e9)
  } else if (n >= 1e6) {
    sprintf("%.0f M", n / 1e6)
  } else if (n >= 1e3) {
    sprintf("%.0f K", n / 1e3)
  } else {
    sprintf("%d", as.integer(n))
  }
}

# Human-readable byte size, e.g. 531 MB, 4.4 GB.
format_bytes <- function(n) {
  if (!is.finite(n)) {
    return("unknown")
  }
  units <- c("B", "KB", "MB", "GB", "TB")
  i <- 1L
  while (n >= 1024 && i < length(units)) {
    n <- n / 1024
    i <- i + 1L
  }
  if (i == 1L) sprintf("%d %s", as.integer(n), units[i]) else sprintf("%.1f %s", n, units[i])
}
