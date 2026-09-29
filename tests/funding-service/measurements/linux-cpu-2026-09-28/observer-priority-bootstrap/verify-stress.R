args <- commandArgs(TRUE)
x <- read.csv(file.path(args[1], 'stress', 'native-stress', 'native.csv'), stringsAsFactors=FALSE)
stopifnot(nrow(x)==1000L, identical(x$index, seq_len(1000L)), length(unique(x$id))==1000L,
          length(unique(x$worker_pid))==1L, length(unique(x$epoch))==1L,
          all(x$state %in% c('success','invalid')), all(x$elapsed_seconds <= 120))
post <- x[x$index > 100L, ]
slope <- unname(coef(lm(idle_rss_bytes ~ index, data=post))['index'])
growth <- median(tail(x$idle_rss_bytes,100)) - median(head(x$idle_rss_bytes,100))
stopifnot(growth <= 256 * 1024^2, slope <= 256 * 1024)
.libPaths(c('/private/tmp/relm-service/library', .libPaths()))
report <- jsonlite::fromJSON(file.path(args[1], 'stress', 'acceptance.json'))
stopifnot(abs(slope-report$stress$slope_bytes_per_request)<1e-6,
          identical(as.numeric(growth),as.numeric(report$stress$growth_bytes)))
result <- list(method='Independent base-R CSV checks and lm slope; no harness imports',
               requests=nrow(x), unique_ids=length(unique(x$id)), worker_pid=unique(x$worker_pid),
               epoch=unique(x$epoch), states=as.list(table(x$state)),
               growth_bytes=growth,slope_bytes_per_request=slope,
               max_request_seconds=max(x$elapsed_seconds))
writeLines(jsonlite::toJSON(result,auto_unbox=TRUE,pretty=TRUE,digits=16), args[2])
print(result)
