args <- commandArgs(TRUE)
x <- readRDS(args[[1L]])
stopifnot(length(x$functions) == 250L, length(x$profile) == 27L,
          x$load_attempts == 1L, x$generation_attempts == 1L,
          x$successful_generations == 0L, x$model_closed,
          inherits(x$result, "relm_error_tokenize"),
          !any(grepl("selftest", x$registered, fixed=TRUE)))
original <- as.list(read.dcf(args[[2L]])[1L,])
packaged <- as.list(read.dcf(args[[3L]])[1L,])
normalize <- function(x) gsub("[[:space:]]+", " ", trimws(x))
stopifnot(all(vapply(names(original), function(n) identical(normalize(original[[n]]), normalize(packaged[[n]])), logical(1))))
cat("OWNER_RDS_PASS functions=250 profile=27 expected_refusal=relm_error_tokenize closed=true\n")
cat("DESCRIPTION original_fields=", length(original), " added=", paste(setdiff(names(packaged),names(original)),collapse=","),"\n",sep="")
write.csv(data.frame(field=names(x$profile), value=unlist(x$profile,use.names=FALSE)), args[[4L]], row.names=FALSE)
