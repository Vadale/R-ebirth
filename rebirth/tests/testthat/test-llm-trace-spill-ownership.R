# Per-PR R checks on macOS/Linux: actual installed R processes and synthetic
# Arrow writes. Preparation has its own budget; no large model or download.
lease_wait <- function(predicate, seconds) {
  deadline <- proc.time()[["elapsed"]] + seconds
  repeat {
    if (isTRUE(predicate())) return(TRUE)
    if (proc.time()[["elapsed"]] >= deadline) return(FALSE)
    Sys.sleep(0.02)
  }
}

lease_child <- function(mode) {
  root <- normalizePath(tempdir())
  work <- tempfile("relm-owner-", tmpdir = root)
  dir.create(work)
  script <- file.path(work, "child.R")
  config <- list(
    lib = .libPaths(),
    model = normalizePath(testthat::test_path("fixtures", "synthetic-llama-2l.gguf")),
    dir = file.path(work, "spill", "session"),
    ready = file.path(work, "ready.rds"), release = file.path(work, "release"),
    pid = file.path(work, "pid.rds")
  )
  saveRDS(config, file.path(work, "config.rds"))
  writeLines(c(
    "cfg <- readRDS(commandArgs(TRUE)[[1L]])",
    ".libPaths(cfg$lib); library(relm)",
    "saveRDS(Sys.getpid(), cfg$pid)",
    "ns <- asNamespace('relm'); state <- get('.relm_state', ns)",
    "state$session_dir <- cfg$dir",
    "inside <- function(name, ...) get(name, ns)(...)",
    "m <- llm(cfg$model, backend='cpu')",
    "path <- inside('next_spill_path')",
    "tokens <- as.integer(c(1,7,13,22,5,31,44,2)+1L)",
    "key <- inside('trace_spec_key',m,'tokens',NULL,'all',c('residual','attn_out','mlp_out'))",
    "run <- function(budget) inside('relm_check',inside('rebirth_selftest_trace_tokens_spill',m$ptr,tokens,TRUE,as.double(budget),path,m$path,inside('next_trace_id'),key))",
    "mem <- inside('new_inmemory_trace',run(Inf),m,'tokens')",
    "stopifnot(!dir.exists(cfg$dir))",
    "sp <- inside('new_spilled_trace',run(1024),m,'tokens',key)",
    "saveRDS(list(trace=sp,matrix=as.matrix(mem,layer=1)),cfg$ready)",
    "close(m)",
    "until <- proc.time()[['elapsed']] + 20",
    "while (!file.exists(cfg$release) && proc.time()[['elapsed']] < until) Sys.sleep(0.02)",
    "quit(save='no',status=0)"
  ), script)
  system2(file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(script), shQuote(file.path(work, "config.rds"))),
    stdout = file.path(work, "stdout.log"), stderr = file.path(work, "stderr.log"),
    wait = FALSE)
  ready <- lease_wait(function() file.exists(config$ready), 90)
  expect_true(ready, info = paste(readLines(file.path(work, "stderr.log"), warn = FALSE), collapse = "\n"))
  if (!ready) stop("Spill child failed during bounded model preparation; logs: ", work)
  config$work <- work
  config$mode <- mode
  config
}

test_that("a real live R owner keeps an aged spill readable and cleans on exit", {
  skip_if_not(Sys.info()[["sysname"]] %in% c("Darwin", "Linux"))
  cfg <- lease_child("normal")
  on.exit(file.create(cfg$release), add = TRUE)
  data <- readRDS(cfg$ready)
  Sys.setFileTime(cfg$dir, Sys.time() - 9 * 86400)
  removed <- relm_check(rebirth_spill_sweep(cfg$dir, as.double(Sys.time() - 7 * 86400)))
  expect_false(removed$removed)
  expect_true(file.exists(attr(data$trace, "spill_files")))
  expect_identical(as.matrix(data$trace, layer = 1), data$matrix)
  file.create(cfg$release)
  expect_true(lease_wait(function() !dir.exists(cfg$dir), 10))
})

test_that("only an aged verifiably orphaned R spill is reclaimed after a crash", {
  skip_if_not(Sys.info()[["sysname"]] %in% c("Darwin", "Linux"))
  cfg <- lease_child("crash")
  on.exit(file.create(cfg$release), add = TRUE)
  Sys.setFileTime(cfg$dir, Sys.time() - 9 * 86400)
  expect_false(relm_check(rebirth_spill_sweep(cfg$dir, as.double(Sys.time())))$removed)
  tools::pskill(readRDS(cfg$pid), signal = 9L)
  expect_true(lease_wait(function() {
    isTRUE(relm_check(rebirth_spill_sweep(cfg$dir, as.double(Sys.time() - 7 * 86400)))$removed)
  }, 10))
  expect_false(dir.exists(cfg$dir))
})

test_that("R sweep retains unknown aged directories and caller-owned files", {
  root <- tempfile("relm-legacy-", tmpdir = normalizePath(tempdir()))
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines("caller-owned", file.path(root, "trace-legacy.arrow"))
  Sys.setFileTime(root, Sys.time() - 9 * 86400)
  expect_false(relm_check(rebirth_spill_sweep(root, as.double(Sys.time())))$removed)
  expect_identical(readLines(file.path(root, "trace-legacy.arrow")), "caller-owned")
  expect_false(relm_check(rebirth_spill_cleanup(root))$removed)
})
