# Draft F6b public R acceptance. Run in a fresh background R process only after
# the focused functional gates pass; this file has not executed a model.
library_path <- normalizePath(Sys.getenv("RELM_F6B_LIBRARY"), mustWork = TRUE)
evidence <- normalizePath(Sys.getenv("RELM_F6B_EVIDENCE"), mustWork = TRUE)
model_path <- normalizePath(Sys.getenv("RELM_TEST_MODEL_QWEN"), mustWork = TRUE)
stopifnot(nzchar(Sys.getenv("RELM_F6B_LIBRARY")), nzchar(Sys.getenv("RELM_F6B_EVIDENCE")),
  nzchar(Sys.getenv("RELM_TEST_MODEL_QWEN")), dir.exists(evidence), file.exists(model_path))
.libPaths(c(library_path, .libPaths()))
library(relm)
stopifnot(normalizePath(find.package("relm")) == file.path(library_path, "relm"),
  "interventions" %in% names(formals(relm:::live_reply)))
clock <- function() unname(proc.time()[["elapsed"]])
sha256 <- function(path) sub(" .*", "", system2("shasum",
  c("-a", "256", shQuote(path)), stdout = TRUE))
saveRDS(list(model = model_path, model_sha256 = sha256(model_path),
  package = find.package("relm"), package_version = packageVersion("relm"),
  session = sessionInfo(), script_sha256 = sha256("/private/tmp/relm-f6b/public-update-latency.R")),
  file.path(evidence, "preflight.rds"))
prompt <- "1, 2, 3, 4, 5, 6, 7, 8, 9, 10,"
receipts <- list()
old <- options(relm.trace_budget = 128 * 1024)
run_one <- function(m, mode, round) {
  done <- FALSE
  value <- error <- estimate <- NULL
  states <- tokens <- 0L
  events <- vector("list", 128L)
  started <- clock()
  promise <- llm_generate(m, prompt, chat = FALSE, max_tokens = 128L,
    temperature = 0, seed = 6261, async = TRUE, layers = 2L, top = 5L, spill = FALSE,
    on_state = function(state) {
      entered <- clock()
      states <<- states + 1L
      k <- states
      p <- attr(state$trace, "prompt_token_count")
      changed <- mode == "changing"
      revision <- if (changed) k - 1L else 0L
      coefficient <- if (changed && k %% 2L == 0L) 0.5 else 0
      next_coefficient <- if (changed && k %% 2L == 1L) 0.5 else 0
      audit <- attr(state, "steering", exact = TRUE)
      stopifnot(identical(state$step$state_id, k), tokens == k - 1L,
        identical(state$step$steering_revision, revision),
        identical(state$step$applied_after_state, revision),
        identical(state$step$effective_source_pos, if (revision) p + revision else 1L),
        identical(audit, data.frame(intervention = 1L, layer = 2L, coef = coefficient)))
      if (is.null(estimate)) estimate <<- relm:::.relm_async$job$live$estimate
      bytes <- as.numeric(object.size(state))
      stopifnot(bytes <= 128 * 1024, bytes <= estimate$materialized_bytes)
      reply <- list(steer = data.frame(intervention = 1L, coef = next_coefficient))
      leaving <- clock()
      events[[k]] <<- data.frame(state_id = k, entered = entered - started,
        leaving = leaving - started, callback_seconds = leaving - entered,
        applied_coef = coefficient, requested_coef = next_coefficient,
        revision = revision, source_pos = state$step$source_pos, object_bytes = bytes)
      reply
    }, on_token = function(batch) {
      tokens <<- tokens + sum(batch$event == "token")
      invisible(NULL)
    })
  submitted <- clock() - started
  promises::then(promise, function(x) { value <<- x; done <<- TRUE; NULL },
    function(e) { error <<- e; done <<- TRUE; NULL })
  deadline <- started + 180
  while (!done && clock() < deadline) later::run_now(0.001, loop = later::global_loop())
  elapsed <- clock() - started
  rows <- if (states) do.call(rbind, events[seq_len(states)]) else data.frame()
  # This interval includes validation, ack, adapter update/re-reservation,
  # decode, publication and R polling. It is NOT an isolated native setter time.
  intervals <- if (states > 1L) rows$entered[-1L] - head(rows$leaving, -1L) else numeric()
  receipt <- list(backend = m$backend, mode = mode, round = round, completed = done,
    submission_seconds = submitted, elapsed_seconds = elapsed, states = states, tokens = tokens,
    callback_to_next_state_seconds = intervals, events = rows, estimate = estimate,
    value = value, error = error)
  receipts[[length(receipts) + 1L]] <<- receipt
  saveRDS(receipts, file.path(evidence, "public-update-latency-receipts.rds"))
  stopifnot(done, is.null(error), states == 128L, tokens == states,
    is.null(relm:::.relm_async$job))
  receipt
}
tryCatch({
  for (backend in c("cpu", "metal")) {
    base <- llm(model_path, backend = backend, context_length = 1024)
    derived <- NULL
    tryCatch({
      derived <- llm_steer(base, 2L, rep(0.01, base$hidden_size), coef = 0)
      metadata <- serialize(derived$interventions, NULL, version = 2)
      baseline <- llm_generate(derived, prompt, chat = FALSE, max_tokens = 3L,
        temperature = 0.7, seed = 6263)
      pairs <- list()
      for (round in 0:3) {
        modes <- if (round %% 2L) c("changing", "unchanged") else c("unchanged", "changing")
        pair <- setNames(lapply(modes, function(mode) {
          result <- run_one(derived, mode, round)
          stopifnot(identical(serialize(derived$interventions, NULL, version = 2), metadata),
            identical(llm_generate(derived, prompt, chat = FALSE, max_tokens = 3L,
              temperature = 0.7, seed = 6263), baseline))
          result
        }), modes)
        if (round) pairs[[length(pairs) + 1L]] <- pair
      }
      median_interval <- function(mode) median(unlist(lapply(pairs,
        function(pair) pair[[mode]]$callback_to_next_state_seconds)))
      ordinary <- median_interval("unchanged")
      updated <- median_interval("changing")
      summary <- data.frame(backend = backend, measured_pairs = length(pairs),
        unchanged_interval_seconds = ordinary, changing_interval_seconds = updated,
        update_interval_difference_seconds = updated - ordinary,
        update_interval_ratio = updated / ordinary)
      write.csv(summary, file.path(evidence, paste0("public-update-latency-", backend, ".csv")),
        row.names = FALSE)
      # The approved F6b contract requires measured cost, not a newly invented
      # latency threshold. Functional audit, bounds and reset assertions gate it.
    }, finally = { if (!is.null(derived)) close(derived); close(base) })
  }
  cat("F6B_PUBLIC_UPDATE_MEASUREMENT_COMPLETE\n")
}, finally = options(old))
