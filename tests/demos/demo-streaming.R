# WP10 foreground demo. Sourcing defines functions; it never loads/downloads a
# model or starts work. Requires the WP10 development build, later and promises.

start_streaming_demo <- function(m, prompts = rep(
    "Count integers from 1 to 1000, separated by commas. Do not explain.", 4),
    max_tokens = 512L, seed = 17, draw = interactive()) {
  stopifnot(requireNamespace("relm", quietly = TRUE),
    requireNamespace("later", quietly = TRUE),
    requireNamespace("promises", quietly = TRUE),
    "on_token" %in% names(formals(relm::llm_generate)))
  state <- new.env(parent = baseenv())
  state$status <- "running"
  state$batches <- list()
  state$events <- NULL
  state$window <- NULL
  state$statistics <- list()
  state$total_tokens <- 0L
  state$total_rows <- 0L
  state$text <- rep("", length(prompts))
  state$heartbeats <- 0L
  state$started <- unname(proc.time()[["elapsed"]])
  state$finished <- NA_real_
  state$first_batch <- NA_real_
  state$error <- NULL
  state$value <- NULL
  state$last_draw <- -Inf
  beat <- function() {
    if (identical(state$status, "running")) {
      state$heartbeats <- state$heartbeats + 1L
      later::later(beat, 0.05)
    }
  }
  consume <- function(batch) {
    received <- unname(proc.time()[["elapsed"]]) - state$started
    if (is.na(state$first_batch)) state$first_batch <- received
    # Full collection is a bounded demo choice, not relm's transport policy.
    if (state$total_rows + nrow(batch) > 100000L) {
      stop("Demo collector exceeded its 100000-row limit; use a file sink.")
    }
    state$total_rows <- state$total_rows + nrow(batch)
    state$batches[[length(state$batches) + 1L]] <- batch
    for (i in which(batch$event == "text")) {
      j <- batch$prompt_id[[i]]
      state$text[[j]] <- paste0(state$text[[j]], batch$text[[i]])
    }
    tokens <- batch[batch$event == "token", , drop = FALSE]
    if (nrow(tokens)) {
      state$total_tokens <- state$total_tokens + nrow(tokens)
      state$window <- tail(rbind(state$window, tokens), 128L)
      seconds <- diff(range(state$window$elapsed))
      rate <- if (nrow(state$window) > 1L && seconds > 0) {
        (nrow(state$window) - 1L) / seconds
      } else NA_real_
      state$statistics[[length(state$statistics) + 1L]] <- data.frame(
        delivered_at = received, produced_at = tail(tokens$elapsed, 1L),
        tokens = state$total_tokens, window_size = nrow(state$window),
        window_tokens_per_second = rate,
        delivery_lag = max(0, received - tail(tokens$elapsed, 1L)))
      if (draw && received - state$last_draw >= 0.25) {
        counts <- sort(table(state$window$token_id), decreasing = TRUE)
        counts <- head(counts, 8L)
        graphics::barplot(counts, las = 2, col = "steelblue",
          xlab = "Token ID (1-based vocabulary index)", ylab = "Count",
          main = sprintf("Last %d tokens; %d produced; %.1f tokens/s",
            nrow(state$window), state$total_tokens, rate))
        state$last_draw <- received
      }
    }
    invisible(NULL)
  }
  state$promise <- relm::llm_generate(m, prompts, max_tokens = max_tokens,
    temperature = 0, seed = seed, async = TRUE, on_token = consume)
  state$submission_seconds <- unname(proc.time()[["elapsed"]]) - state$started
  later::later(beat, 0.05)
  state$observed <- promises::then(state$promise, function(value) {
    state$finished <- unname(proc.time()[["elapsed"]]) - state$started
    state$value <- value
    state$events <- do.call(rbind, state$batches)
    state$batches <- NULL
    state$statistics <- do.call(rbind, state$statistics)
    if (!identical(unname(as.character(value)), state$text)) {
      state$status <- "failed"
      state$error <- "Streamed text does not reconstruct the returned vector."
    } else {
      state$status <- "completed"
    }
    invisible(NULL)
  }, function(error) {
    state$finished <- unname(proc.time()[["elapsed"]]) - state$started
    state$status <- "failed"
    state$error <- error
    invisible(NULL)
  })
  state
}

# Convenience reader, preserving literal "NA" output text. Base R normalizes
# embedded CRLF to LF; use callback text/serialized bytes for exact line endings.
read_streaming_events <- function(path) {
  utils::read.csv(path, fileEncoding = "UTF-8", check.names = FALSE,
    na.strings = character(),
    colClasses = c("integer", "character", "integer", "integer", "integer",
      "character", "numeric", "character", "logical"))
}
