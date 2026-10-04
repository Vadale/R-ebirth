# A separate real Console submission while the steering promise is active.
local({
  a <- get(".relm_f6b_acceptance", envir = .GlobalEnv, inherits = FALSE)
  started <- unname(proc.time()[["elapsed"]])
  was_running <- identical(a$status, "running")
  native <- relm:::rebirth_async_test_stats()
  value <- 1 + 1
  a$probe <- list(value = value, elapsed = unname(proc.time()[["elapsed"]]) - started,
    was_running = was_running, native_running = identical(native$active_jobs, 1L),
    states_delivered = a$states, applied_revision = a$expected_revision, pid = Sys.getpid())
  saveRDS(a$probe, file.path(a$root, "probe.rds"))
  stopifnot(a$probe$was_running, a$probe$native_running, a$probe$states_delivered > 0L,
    identical(a$probe$value, 2))
  print(value)
})
