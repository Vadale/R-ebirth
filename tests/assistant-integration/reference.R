#!/usr/bin/env Rscript
# Independent arithmetic checks for the fixed synthetic acceptance inputs.
# These do not fit the assistant's models or certify nlme's implementation.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 2L,
          args[[1L]] %in% c("simple", "longitudinal", "longitudinal-slopes"))
d <- read.csv(args[[2L]], stringsAsFactors = FALSE)
interval <- function(a, b) {
  na <- length(a); nb <- length(b)
  va <- sum((a - sum(a) / na)^2) / (na - 1L)
  vb <- sum((b - sum(b) / nb)^2) / (nb - 1L)
  se2 <- va / na + vb / nb
  df <- se2^2 / ((va / na)^2 / (na - 1L) + (vb / nb)^2 / (nb - 1L))
  estimate <- sum(b) / nb - sum(a) / na
  margin <- stats::qt(0.975, df) * sqrt(se2)
  data.frame(estimate, conf_low = estimate - margin, conf_high = estimate + margin,
             df, n = na + nb)
}
if (args[[1L]] == "simple") {
  stopifnot(!anyNA(d), !anyDuplicated(d$id), setequal(d$group, c("A", "B")))
  result <- interval(d$outcome[d$group == "A"], d$outcome[d$group == "B"])
} else {
  stopifnot(!anyNA(d), !anyDuplicated(d[c("person", "visit")]),
            all(table(d$person) == 5L))
  if (args[[1L]] == "longitudinal-slopes") {
    persons <- split(d, d$person)
    slope <- vapply(persons, function(z) {
      centered <- z$visit - sum(z$visit) / nrow(z)
      sum(centered * z$score) / sum(centered^2)
    }, numeric(1))
    group <- vapply(persons, function(z) unique(z$group), character(1))
    result <- interval(slope[group == "comparison"], slope[group == "programme"])
  } else {
    start <- d[d$visit == 0, ]; end <- d[d$visit == 4, ]
    change <- end$score[match(start$person, end$person)] - start$score
    result <- interval(change[start$group == "comparison"],
                       change[start$group == "programme"])
  }
}
write.csv(result, stdout(), row.names = FALSE)
