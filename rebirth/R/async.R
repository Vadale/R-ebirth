# D-037 async admission limits. The native boundary twin-pins these literals.
relm_async_max_prompts <- 128
relm_async_max_prompt_bytes <- 1048576
relm_async_max_input_bytes <- 16777216
relm_async_max_tokens <- 8192
relm_async_max_output_bytes <- 8388608
relm_async_max_descriptor_bytes <- 16777216
relm_async_string_descriptor_bytes <- 64
relm_async_image_row_bytes <- 32
relm_async_poll_interval <- 0.05

# R-only roots. Never send this environment, callbacks, or an llm wrapper to
# the worker. Native terminal collection returns ownership before settlement.
.relm_async <- new.env(parent = emptyenv())
.relm_async$job <- NULL
.relm_async$stopping <- FALSE

async_check_dependencies <- function() {
  versions <- c(later = "1.4.8", promises = "1.5.0")
  for (package in names(versions)) {
    required <- versions[[package]]
    installed <- async_package_version(package)
    if (is.na(installed) || utils::compareVersion(installed, required) < 0L) {
      relm_abort("relm_error_generation",
        sprintf("Async generation requires %s >= %s. Install it with install.packages('%s').",
          package, required, package),
        list(reason = "async_dependency", package = package,
          required_version = required, installed_version = installed))
    }
  }
  invisible(NULL)
}

async_package_version <- function(package) {
  if (requireNamespace(package, quietly = TRUE)) {
    as.character(utils::packageVersion(package))
  } else NA_character_
}

async_validate_inputs <- function(prompt, stop, schema, images, max_tokens,
                                  temperature, seed, live_strings = character()) {
  # The literal text-byte cap does not bound millions of empty strings. Bound
  # retained vector/string descriptors separately before encoding/path copies.
  strings <- length(prompt) + length(names(prompt)) + length(stop) +
    length(schema) + sum(lengths(images)) + length(live_strings)
  descriptor_bytes <- strings * relm_async_string_descriptor_bytes +
    length(prompt) * relm_async_image_row_bytes
  if (descriptor_bytes > relm_async_max_descriptor_bytes) {
    relm_abort("relm_error_argument",
      "Async input collections exceed the 16 MiB retained-descriptor budget.",
      list(argument = "prompt", reason = "async_input_storage",
        estimate_bytes = descriptor_bytes, limit_bytes = relm_async_max_descriptor_bytes))
  }
  if (length(prompt) > relm_async_max_prompts) {
    abort_argument("prompt", "Async generation accepts at most 128 prompts per call.")
  }
  if (max_tokens > relm_async_max_tokens) {
    abort_argument("max_tokens", "Async generation requires `max_tokens <= 8192`.")
  }
  if (!is.finite(temperature) || temperature > relm_structured_max_temperature) {
    abort_argument("temperature", "Async generation requires a finite temperature that fits a 32-bit float.")
  }
  if (!is.null(seed) && (!is.numeric(seed) || length(seed) != 1L ||
    is.na(seed) || !is.finite(seed) || seed < 0 || seed != round(seed) ||
    seed >= relm_structured_seed_limit)) {
    abort_argument("seed", "Async generation requires a finite non-negative whole-number seed less than 2^64.")
  }
  # Check the supplied representation before conversion/copy, then bound UTF-8
  # and expanded paths too. NA names retain base-R semantics and cost two bytes.
  budget <- function(values, argument, used) {
    sizes <- nchar(values, type = "bytes", keepNA = FALSE)
    if (identical(argument, "prompt") && any(sizes > relm_async_max_prompt_bytes)) {
      abort_argument("prompt", "Async prompts are limited to 1 MiB of UTF-8 text each.")
    }
    used <- used + sum(sizes)
    if (used > relm_async_max_input_bytes) {
      abort_argument(argument, "Async copied text arguments are limited to 16 MiB in aggregate.")
    }
    used
  }
  arguments <- list(prompt = prompt, names = names(prompt), stop = stop,
    schema = schema, on_state = live_strings)
  check <- function(arguments, images) {
    used <- 0
    for (argument in names(arguments)) {
      used <- budget(arguments[[argument]], argument, used)
    }
    for (paths in images) used <- budget(paths, "images", used)
    invisible(used)
  }
  check(arguments, images)
  utf8 <- function(values, argument) {
    if (is.null(values)) return(NULL)
    if (any(Encoding(values) == "bytes")) {
      abort_argument(argument, "Async text arguments must contain valid UTF-8 text.")
    }
    values <- enc2utf8(values)
    if (!all(validUTF8(values[!is.na(values)]))) {
      abort_argument(argument, "Async text arguments must contain valid UTF-8 text.")
    }
    values
  }
  for (argument in names(arguments)) {
    arguments[argument] <- list(utf8(arguments[[argument]], argument))
  }
  images <- if (is.null(images)) NULL else lapply(images,
    function(paths) utf8(path.expand(paths), "images"))
  check(arguments, images)
  names(arguments$prompt) <- arguments$names
  list(prompt = arguments$prompt, stop = arguments$stop,
    schema = arguments$schema, images = images)
}

async_condition <- function(class, message, fields = list()) {
  structure(c(list(message = message, call = NULL), fields),
    class = c(class, "relm_error", "error", "condition"))
}

async_payload_condition <- function(payload) {
  valid_text <- function(x) is.character(x) && length(x) == 1L && !is.na(x)
  malformed <- !is.list(payload) || !valid_text(payload$class) ||
    !valid_text(payload$message) || !startsWith(payload$class, "relm_error_") ||
    (!is.null(payload$fields) && !is.list(payload$fields))
  if (!malformed && identical(payload$class, "relm_error_cancelled")) {
    fields <- payload$fields
    malformed <- !all(c("reason", "seed", "prompt_id", "generated_tokens") %in% names(fields))
  }
  if (malformed) {
    return(async_condition("relm_error_internal",
      "The native async failure payload was incomplete.", list(reason = "async_protocol")))
  }
  async_condition(payload$class, payload$message,
    if (is.null(payload$fields)) list() else payload$fields)
}

async_generate <- function(m, prompt, chat, max_tokens, temperature, top_p,
                           seed, stop, images, image_max_bytes, schema,
                           on_progress, stream = NULL, live = NULL) {
  job <- new.env(parent = emptyenv())
  job$model <- m
  job$names <- names(prompt)
  job$seed <- seed
  job$callback <- on_progress
  job$last_progress <- NULL
  job$callback_error <- NULL
  job$timer <- NULL
  job$settled <- FALSE
  job$id <- NULL
  job$stream <- stream
  job$live <- live
  job$live_state_id <- 0L
  job$live_elapsed <- 0
  job$live_prompt_count <- NULL
  job$structured <- !is.null(schema)
  job$prompts_total <- length(prompt)
  job$stream_event_id <- 0L
  job$stream_elapsed <- 0
  job$stream_prompt_id <- 1L
  job$stream_token_pos <- 0L
  job$polling <- FALSE
  promise <- promises::promise(function(resolve, reject) {
    job$resolve <- resolve
    job$reject <- reject
  })
  # No callback has run yet. Submit only fully owned native inputs; keep names,
  # the submitting handle and all promise closures rooted on the R side.
  submit_args <- list(m$ptr, unname(prompt), chat, max_tokens, temperature,
    top_p, seed, stop,
    if (is.null(images)) character() else as.character(unlist(images, use.names = FALSE)),
    if (is.null(images)) rep.int(0L, length(prompt)) else as.integer(lengths(images)),
    image_max_bytes, schema, !is.null(stream))
  submit <- if (is.null(live)) rebirth_async_submit else rebirth_live_submit
  if (!is.null(live)) submit_args <- c(submit_args, list(live$native_config))
  payload <- tryCatch(do.call(submit, submit_args), error = identity, interrupt = identity)
  if (inherits(payload, "condition")) {
    async_transport_failure(job, payload)
    return(promise)
  }
  if (isFALSE(payload$ok)) {
    async_settle(job, error = async_payload_condition(payload))
    return(promise)
  }
  job$id <- payload$job_id
  .relm_async$job <- job
  if (!is.null(stream) && identical(stream$kind, "file")) stream_file_delivery(job)
  async_schedule(job)
  promise
}

async_schedule <- function(job) {
  if (job$settled || .relm_async$stopping) return(invisible(NULL))
  tryCatch({
    job$timer <- later::later(function() {
      tryCatch(async_poll(job), error = function(error) async_transport_failure(job, error))
    }, delay = if (is.null(job$live)) relm_async_poll_interval else relm_live_poll_interval,
      loop = later::global_loop())
  }, error = function(error) async_transport_failure(job, error))
  invisible(NULL)
}

# A failed R/native transport cannot safely abandon its worker. This is a
# controlled emergency shutdown, the only non-unload path that joins a worker.
async_transport_failure <- function(job, error) {
  if (job$settled) return(invisible(NULL))
  .relm_async$stopping <- TRUE
  if (is.function(job$timer)) job$timer()
  rebirth_async_shutdown()
  job$model$state$closed <- TRUE
  async_settle(job, error = async_condition("relm_error_internal",
    "Async result delivery failed; the native worker was shut down safely.",
    list(parent = error)))
  .relm_async$stopping <- FALSE
  invisible(NULL)
}

async_progress <- function(job, progress, terminal = FALSE) {
  if (is.null(job$callback) || !is.null(job$callback_error) || is.null(progress)) {
    return(invisible(NULL))
  }
  # A complete snapshot is delivered only at successful terminal collection.
  if (!terminal && identical(progress$phase, "complete")) return(invisible(NULL))
  if (!terminal && identical(progress, job$last_progress)) return(invisible(NULL))
  job$last_progress <- progress
  state <- data.frame(prompt_id = as.integer(progress$prompt_id),
    prompts_completed = as.integer(progress$prompts_completed),
    prompts_total = as.integer(progress$prompts_total),
    generated_tokens = as.integer(progress$generated_tokens),
    max_tokens = as.integer(progress$max_tokens), phase = as.character(progress$phase),
    stringsAsFactors = FALSE)
  fail <- function(error) {
    async_consumer_failure(job, async_condition("relm_error_callback",
      "The async progress callback failed; no generation result was returned.",
      list(callback = "on_progress", parent = error)), terminal)
  }
  tryCatch(job$callback(state), error = fail, interrupt = fail)
  invisible(NULL)
}

async_consumer_failure <- function(job, error, terminal = FALSE) {
  if (!is.null(job$callback_error)) return(invisible(NULL))
  job$callback_error <- error
  job$callback <- NULL
  # No join here: wake/discard and keep scheduled nonblocking polls until native
  # ownership is returned. Bypass the public check if a callback closed m.
  if (!terminal && !is.null(job$id)) {
    if (is.null(job$stream) && is.null(job$live)) rebirth_async_cancel(job$model$ptr) else
      relm_check(rebirth_async_discard(job$model$ptr, job$id))
  }
  invisible(NULL)
}

async_poll <- function(job) {
  if (job$settled || .relm_async$stopping || isTRUE(job$polling)) return(invisible(NULL))
  job$polling <- TRUE
  on.exit(job$polling <- FALSE, add = TRUE)
  job$timer <- NULL
  if (!is.null(job$stream) && identical(job$stream$kind, "file") &&
    is.null(job$callback_error) && !job$model$state$closed) {
    # Closure is observed even during prefill, before the first event exists.
    tryCatch(stream_check_connection(job$stream),
      error = function(error) async_consumer_failure(job, error))
  }
  payload <- tryCatch(relm_check(rebirth_async_poll(job$model$ptr, job$id)),
    relm_error_stream = function(error) {
      async_consumer_failure(job, error)
      NULL
    })
  if (is.null(payload)) {
    async_schedule(job)
    return(invisible(NULL))
  }
  if (isTRUE(payload$closed)) job$model$state$closed <- TRUE
  if (!is.null(job$stream) && payload$state %in% c("running", "draining")) {
    stream_deliver(job, payload$batch)
    if (isTRUE(payload$delivery_ready) && is.null(job$callback_error) &&
      !job$model$state$closed) {
      if (job$stream_prompt_id != job$prompts_total + 1L) {
        async_consumer_failure(job, stream_condition("invariant",
          "The token stream completed without ending every prompt."))
      } else if (identical(job$stream$kind, "file")) {
        stream_file_delivery(job, flush_only = TRUE)
      }
      if (is.null(job$callback_error)) {
        # Even the last on_token runs while busy; only this acknowledgement
        # restores ownership. Final progress below therefore preserves WP9.
        payload <- relm_check(rebirth_async_ack(job$model$ptr, job$id))
        if (isTRUE(payload$closed)) job$model$state$closed <- TRUE
      }
    }
  }
  if (!is.null(job$live) && payload$state %in% c("running", "draining")) {
    # stream_deliver above handles all earlier events before the one live state.
    # A recursive later pump sees job$polling and cannot re-enter this callback.
    live_deliver(job, payload$live_state)
  }
  terminal <- payload$state %in% c("completed", "failed", "cancelled")
  if (!terminal) {
    if (is.null(job$stream) || !job$model$state$closed) async_progress(job, payload$progress)
    async_schedule(job)
    return(invisible(NULL))
  }
  if (identical(payload$state, "completed")) {
    async_progress(job, payload$progress, terminal = TRUE)
    if (job$settled) return(invisible(NULL))
    if (is.null(job$callback_error)) {
      result <- payload$text
      names(result) <- job$names
      attr(result, "seed") <- job$seed
      async_settle(job, value = result)
    } else {
      async_settle(job, error = job$callback_error)
    }
  } else {
    error <- if (!is.null(job$callback_error)) job$callback_error else
      async_payload_condition(payload$error)
    async_settle(job, error = error)
  }
  invisible(NULL)
}

async_settle <- function(job, value = NULL, error = NULL) {
  if (job$settled) return(invisible(NULL))
  # Callers can pass job$callback_error lazily. Capture values before clearing
  # that environment, or a final-callback failure would become a NULL success.
  force(value)
  force(error)
  job$settled <- TRUE
  if (is.function(job$timer)) job$timer()
  resolve <- job$resolve
  reject <- job$reject
  if (identical(.relm_async$job, job)) .relm_async$job <- NULL
  # Remove roots before invoking promise continuations; callbacks can create a
  # subsequent job after native terminal collection without losing its roots.
  job$timer <- job$callback <- job$model <- job$resolve <- job$reject <- job$stream <- job$live <- NULL
  job$last_progress <- job$callback_error <- job$names <- NULL
  if (is.null(error)) resolve(value) else reject(error)
  invisible(NULL)
}

# Used by the exit sentinel and .onUnload after cancelling timers. Namespace
# shutdown joins the worker but deliberately leaves the DLL mapped for retained
# external-pointer finalizers. Forced dyn.unload with live pointers is unsupported.
async_shutdown <- function() {
  if (isTRUE(.relm_async$unloaded)) return(invisible(NULL))
  .relm_async$stopping <- TRUE
  job <- .relm_async$job
  if (!is.null(job) && is.function(job$timer)) job$timer()
  payload <- relm_check(rebirth_async_shutdown())
  if (!is.null(job)) {
    job$model$state$closed <- TRUE
    async_settle(job, error = async_condition("relm_error_cancelled",
      "Async generation stopped because relm is shutting down.",
      list(reason = "shutdown", seed = job$seed, prompt_id = 1L,
        generated_tokens = 0L)))
  }
  invisible(payload)
}

# Conservative materialized-R bound: vector/attribute headers, pointer slots,
# separately allocated text/name CHARSXPs and worst-case alignment. This is not
# the native retained-memory estimate and does not include model/context memory.
async_result_size_bound <- function(n, output_bytes, names_bytes = 0) {
  1024 + 256 * n + output_bytes + names_bytes
}

# Conservative accounting for bounded async transport buffers at their maxima.
# I=input UTF-8 limit, D=descriptor limit, O=output UTF-8 limit, C=loaded context
# length, N=prompt count, T=requested tokens. Native-owned slots contribute
# 2*(I+D) + 7*I + 4*C + 3*O + 4*N*T + 64*N. Two native input slots cover flat-image
# splitting alongside owned strings. Two further I+D slots cover R input/normalization
# copies; the materialized result includes names and CHARSXP/vector overhead.
# Sum slots even when their lifetimes do not overlap. This is neither an RSS
# ceiling nor a bound on existing model/context state, logits/sampler/grammar
# engine allocations, vision bitmap/tensor buffers, allocator overhead or thread
# stacks. Caller attributes, callbacks and their environments are also excluded.
# Native capacities/formula are twin-pinned in the native async tests.
async_transport_peak_bound <- function(context_length,
                                       n = relm_async_max_prompts,
                                       max_tokens = relm_async_max_tokens,
                                       names_bytes = relm_async_max_input_bytes) {
  input <- relm_async_max_input_bytes
  descriptors <- relm_async_max_descriptor_bytes
  output <- relm_async_max_output_bytes
  components <- c(
    native_input = 2 * (input + descriptors),
    r_input_copies = 2 * (input + descriptors),
    template_scratch = 7 * input,
    prompt_token_buffer = 4 * context_length,
    native_output_text = 3 * output,
    generated_token_ids = 4 * n * max_tokens,
    generation_descriptors = 64 * n,
    r_result = async_result_size_bound(n, output, names_bytes)
  )
  list(total_bytes = sum(components), components = components)
}

#' Cancel background generation
#'
#' Requests cooperative cancellation of the async generation submitted through
#' exactly this handle. The promise rejects with `relm_error_cancelled`; it never
#' resolves to partial text. An in-flight native decode or image encoder call may
#' need to finish before cancellation takes effect. The handle becomes reusable
#' after completion is collected on R's event loop.
#'
#' @param m An open `llm` handle from [llm()].
#' @return An invisible logical: `TRUE` only for the first accepted cancellation
#'   before native terminal publication; `FALSE` when idle, already cancelling,
#'   native-terminal, or when another handle submitted the active job.
#' @seealso [llm_generate()], [close.llm()]
#' @export
llm_cancel <- function(m) {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)
  payload <- relm_check(rebirth_async_cancel(m$ptr))
  invisible(isTRUE(payload$cancelled))
}
