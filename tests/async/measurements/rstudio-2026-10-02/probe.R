# Execute this through the responsive RStudio console while generation is pending.
a <- .relm_wp9_acceptance
was_running <- identical(a$status, 'running')
started <- proc.time()[['elapsed']]
value <- 1 + 1
elapsed <- proc.time()[['elapsed']] - started
a$probe <- list(value = value, elapsed = elapsed, was_running = was_running,
  at = as.numeric(Sys.time()))
print(value)
a$receipt()
