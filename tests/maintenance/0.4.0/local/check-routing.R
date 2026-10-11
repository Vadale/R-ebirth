repo <- "/Users/alessandrovadala/DOCUDESK/R-ebirth"
root <- "/private/tmp/relm-maintenance-040"
scratch <- file.path(root, "config-routing")
dir.create(file.path(scratch, "tools"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(scratch, "src"), showWarnings = FALSE)
file.copy(file.path(repo, "rebirth/DESCRIPTION"), scratch, overwrite = TRUE)
file.copy(file.path(repo, "rebirth/tools", c("config.R", "msrv.R", "cmake.R")),
          file.path(scratch, "tools"), overwrite = TRUE)
file.copy(file.path(repo, "rebirth/src", c("Makevars.in", "Makevars.win.in")),
          file.path(scratch, "src"), overwrite = TRUE)
setwd(scratch)
for (flag in c("0", "1")) {
  Sys.setenv(RELM_ENABLE_SELFTESTS = flag)
  source("tools/config.R", local = new.env())
  output <- readLines("src/Makevars")
  stopifnot(sum(grepl("--features selftest", output, fixed = TRUE)) ==
              if (flag == "1") 2L else 0L,
            !any(grepl("@SELFTEST_FEATURE@", output, fixed = TRUE)))
  file.copy("src/Makevars", paste0("Makevars-", flag), overwrite = TRUE)
}
Sys.setenv(RELM_ENABLE_SELFTESTS = "invalid")
err <- tryCatch(source("tools/config.R", local = new.env()), error = identity)
stopifnot(inherits(err, "error"),
          identical(conditionMessage(err), "RELM_ENABLE_SELFTESTS must be 0 or 1"))
Sys.unsetenv("RELM_ENABLE_SELFTESTS")
read_workflow <- function(name) yaml::read_yaml(file.path(repo, ".github/workflows", name))
vision <- read_workflow("nightly-vision-golden.yaml")
stopifnot(identical(vision$jobs[["vision-golden"]]$env$RELM_ENABLE_SELFTESTS, "1"))
r <- read_workflow("R-CMD-check.yaml")
stopifnot(any(vapply(r$jobs, function(job)
  identical(job$env$RELM_ENABLE_SELFTESTS, "1"), logical(1))))
tolerance <- read_workflow("nightly-model-tolerance.yaml")
steps <- unlist(lapply(tolerance$jobs, `[[`, "steps"), recursive = FALSE)
stopifnot(sum(vapply(steps, function(step)
  identical(step$env$RELM_ENABLE_SELFTESTS, "1"), logical(1))) == 1L)
rust <- read_workflow("rust.yaml")
steps <- unlist(lapply(rust$jobs, `[[`, "steps"), recursive = FALSE)
diag <- Filter(function(s) identical(s$name, "Retain maintenance prefix diagnosis"), steps)
stopifnot(length(diag) == 1L,
  grepl("codex/maintenance-release-0.4.0", diag[[1]]$`if`, fixed = TRUE),
  grepl("--ignored --exact", diag[[1]]$run, fixed = TRUE))
cat("MAINTENANCE_ROUTING_OK config=default,selftest,invalid workflows=4 models=0 builds=0\n")
