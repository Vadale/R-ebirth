# D-041 bounded live observation demo. Use a direction from your own analysis;
# this script supplies a measurement mechanism, not a validated detector.
# Source after installing the development package. No model is downloaded.

observe_direction <- function(m, prompt, direction, layer, threshold = Inf,
                              max_tokens = 256L, seed = 6241L, plot = interactive()) {
  stopifnot(inherits(m, "llm"), is.numeric(direction), !is.complex(direction),
    length(direction) == m$hidden_size, all(is.finite(direction)),
    length(layer) == 1L, layer >= 1L, layer <= m$layers,
    is.numeric(threshold), length(threshold) == 1L, !is.na(threshold))
  # The caller owns this fixed 64-state window. No activation history is retained.
  window <- new.env(parent = emptyenv())
  window$position <- rep(NA_integer_, 64L)
  window$score <- rep(NA_real_, 64L)
  window$count <- 0L
  window$cancel_state <- NULL
  window$finished <- FALSE
  window$result <- NULL
  window$error <- NULL
  observe <- function(state) {
    activation <- as.matrix(state$trace, layer = layer, component = "residual")
    score <- sum(as.numeric(activation[1L, ]) * direction)
    index <- (window$count %% 64L) + 1L
    window$position[index] <- state$step$source_pos
    window$score[index] <- score
    window$count <- window$count + 1L
    if (plot && window$count %% 8L == 0L) {
      used <- which(!is.na(window$position))
      used <- used[order(window$position[used])]
      graphics::plot(window$position[used], window$score[used], type = "l",
        xlab = "Model-context source position", ylab = "Direction score",
        main = "Most recent 64 observed states")
      if (is.finite(threshold)) graphics::abline(h = threshold, lty = 2L)
    }
    if (is.finite(threshold) && score >= threshold) {
      window$cancel_state <- state$step
      relm::llm_cancel(m)
    }
    invisible(NULL)
  }
  promise <- relm::llm_generate(m, prompt, async = TRUE, on_state = observe,
    layers = as.integer(layer), components = "residual", top = 0L,
    max_tokens = max_tokens, seed = seed, spill = TRUE)
  completion <- promises::then(promise, function(text) {
    window$result <- text
    window$finished <- TRUE
    invisible(NULL)
  }, onRejected = function(error) {
    window$error <- error
    window$finished <- TRUE
    invisible(NULL)
  })
  list(promise = promise, completion = completion, window = window)
}

# Example with a caller-supplied, scientifically justified direction:
# m <- relm::llm(Sys.getenv("RELM_TEST_MODEL_QWEN"))
# run <- observe_direction(m, "Explain confidence intervals.", direction,
#   layer = 12L, threshold = calibrated_threshold, seed = 6241L)
# In an interactive console/RStudio, return to the prompt for event delivery.
# In a script, pump later::run_now() until run$window$finished.
# Cancellation is a rejected promise, not successful partial text. Its reported
# generated count includes the just-observed token; no following token is sampled.
# Calibrate a threshold independently; this demo makes no accuracy/safety claim.
# Retained windows use only 64 scores/positions, even for long generations.
