local({
  a <- .relm_wp10_acceptance
  native <- relm:::rebirth_async_test_stats()
  was_running <- identical(a$status,"running")
  started <- proc.time()[["elapsed"]]
  value <- 1 + 1
  elapsed <- proc.time()[["elapsed"]] - started
  a$probe <- list(value=value, elapsed=elapsed, was_running=was_running,
    native_running=identical(native$worker_threads,1L),
    tokens_delivered=a$state$total_tokens, at=as.numeric(Sys.time()))
  print(value)
  a$receipt()
})
