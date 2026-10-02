# Short, model-free subprocess checks for the external skill, not relm tests.
root <- normalizePath(commandArgs(trailingOnly = TRUE)[[1L]], mustWork = TRUE)
runner <- file.path(root, "integrations/skills/r-statistical-analysis/scripts/run-analysis.R")
work <- tempfile("r-skill-contract-"); dir.create(work)
input <- file.path(work, "measurements with spaces.csv")
utils::write.csv(data.frame(x = c(2, 4, 6, 8)), input, row.names = FALSE)
script <- file.path(work, "analysis source.R")
body <- c(
  'd <- read.csv(input_paths[[1L]])',
  'fit <- t.test(d$x)',
  'warning("retained diagnostic warning")',
  'list(summary = "A descriptive mean, not a causal estimate.",',
  'estimates = data.frame(result_id="mean", term="x", estimate=mean(d$x),',
  'conf_low=unname(fit$conf.int[1]), conf_high=unname(fit$conf.int[2]),',
  'conf_level=0.95, scale="mean", units="points", n=nrow(d),',
  'method="Student t interval", status="exploratory"),',
  'diagnostics=data.frame(check="independence",status="assumed",detail="Design assumption"),',
  'limitations="Four observations only.")'
)
run <- function(lines, label, expected = 0L) {
  writeLines(lines, script)
  output <- file.path(work, label)
  status <- system2(file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(runner), shQuote(script), shQuote(output), shQuote(input)),
    stdout = file.path(work, paste0(label, ".log")), stderr = file.path(work, paste0(label, ".log")))
  stopifnot(identical(as.integer(status), expected))
  output
}
valid <- run(body, "valid output")
est <- read.csv(file.path(valid, "estimates.csv"))
# Independent closed-form checks of the fixture, not a second runner invocation.
margin <- qt(0.975, 3) * sqrt(20 / 3) / 2
stopifnot(est$estimate == 5, abs(est$conf_low - (5-margin)) < 1e-12,
          abs(est$conf_high - (5+margin)) < 1e-12,
          read.dcf(file.path(valid, "status.dcf"))[1,"State"] == "complete")
conditions <- read.csv(file.path(valid, "conditions.csv"))
stopifnot(nrow(conditions) == 1, conditions$type == "warning",
          conditions$message == "retained diagnostic warning")
manifest <- read.csv(file.path(valid, "manifest.csv"))
stopifnot(identical(manifest$md5_before, manifest$md5_after), nrow(manifest) == 2)
# Existing output must not be overwritten.
old_hash <- tools::md5sum(file.path(valid, "estimates.csv"))
invisible(run(body, "valid output", 1L))
stopifnot(identical(old_hash, tools::md5sum(file.path(valid, "estimates.csv"))))
failed <- run('stop("intentional fit failure")', "fit failure", 1L)
stopifnot(read.dcf(file.path(failed,"status.dcf"))[1,"State"] == "failed",
          read.csv(file.path(failed,"conditions.csv"))$message == "intentional fit failure")
invalid <- run(sub('conf_level=0.95', 'conf_level=2', body, fixed=TRUE), "invalid interval", 1L)
stopifnot(!file.exists(file.path(invalid,"estimates.csv")))
utils::write.csv(data.frame(x=c(2,4,6,8)), input, row.names=FALSE)
mutated <- run(c(body[1], 'writeLines("changed", input_paths[[1]])', body[-1]),
               "detected mutation", 1L)
stopifnot(grepl("changed during execution", read.csv(file.path(mutated,"conditions.csv"))$message[2]))
cat("PASS: numerical fixture, warning retention, spaced paths, overwrite rejection, fit failure, invalid interval, input mutation\n")
cat("Evidence:", work, "\n")
