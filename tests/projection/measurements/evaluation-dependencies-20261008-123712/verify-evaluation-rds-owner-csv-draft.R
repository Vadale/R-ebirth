# Independent retained-data audit. No relm load, model, inference or RNG draws.
args <- commandArgs(TRUE); stopifnot(length(args)==1L)
root <- args[[1L]]; setwd(root)
report <- jsonlite::read_json('complete-report.json')
prompts <- read.csv('/Users/alessandrovadala/DOCUDESK/R-ebirth/tests/projection/evaluation/prompts.csv',stringsAsFactors=FALSE)
rows <- rbind(read.csv('selection.csv'),read.csv('evaluation.csv'),read.csv('views.csv'))
reported <- c(report$selection,report$evaluation,report$view_runs)
metrics <- list(); raw <- list(); event_rows <- 0L; tokens <- 0L
for(i in seq_len(nrow(rows))) {
  z <- rows[i,]; r <- readRDS(paste0('raw/',z$run_id,'.rds')); raw[[z$run_id]] <- r
  stopifnot(identical(r$done,TRUE),identical(r$settlements,1L),identical(r$timed_out,FALSE))
  ev <- read.csv(z$events_file,colClasses='character',na.strings=character(),check.names=FALSE)
  stopifnot(identical(names(ev),names(r$events)),nrow(ev)==nrow(r$events))
  for(k in names(ev)) {
    a <- r$events[[k]]; b <- ev[[k]]
    if(is.numeric(a)) {b[b==''] <- NA_character_; b <- as.double(b); stopifnot(isTRUE(all.equal(as.double(a),b,tolerance=1e-12)))
    } else if(is.logical(a)) {b[b==''] <- NA_character_; stopifnot(identical(a,as.logical(b)))
    } else {a[is.na(a)] <- ''; stopifnot(identical(a,b))}
  }
  n <- sum(r$events$event=='token'); event_rows <- event_rows+nrow(ev); tokens <- tokens+n
  if(z$status=='ok') {
    stopifnot(is.null(r$error),length(r$value)==1L,identical(attr(r$value,'seed'),1046))
    bytes <- readBin(z$text_file,'raw',n=file.info(z$text_file)$size)
    stopifnot(identical(charToRaw(enc2utf8(as.character(r$value))),bytes))
    txt <- as.character(r$value); lowered <- tolower(txt)
    patterns <- strsplit(prompts$required_pattern[match(z$item_id,prompts$item_id)],'|',fixed=TRUE)[[1L]]
    present <- any(vapply(patterns,function(literal) grepl(paste0('(?<![[:alnum:]])',tolower(literal),'(?![[:alnum:]])'),lowered,perl=TRUE),logical(1)))
    words <- strsplit(trimws(lowered),'[[:space:]]+',perl=TRUE)[[1L]]
    ending <- r$events$finish_reason[r$events$event=='prompt_end']
    stopifnot(length(ending)==1L)
    m <- list(required=as.integer(present),characters=nchar(txt,type='chars'),tokens=n,
      empty=as.integer(!nzchar(trimws(txt))),truncated=as.integer(ending=='length'),
      repeated=if(length(words)>1L) sum(head(words,-1L)==tail(words,-1L)) else 0L)
    stopifnot(isTRUE(all.equal(m,reported[[i]]$metrics,check.attributes=TRUE,tolerance=0)))
    metrics[[z$run_id]] <- m
  } else {
    stopifnot(z$phase=='view',z$status=='cancelled',is.null(r$value),
      inherits(r$error,'relm_error_cancelled'),r$error$reason=='requested',
      identical(r$error$seed,1046),r$error$generated_tokens==2L,n==1L,
      !any(r$events$event=='prompt_end'))
  }
}
zero_pairs <- 0L
for(task in unique(rows$item_id[rows$phase!='view'])) {
  a <- rows[rows$item_id==task & rows$setting=='baseline' & rows$phase!='view',]
  for(setting in c('zero_add','zero_project')) {
    b <- rows[rows$item_id==task & rows$setting==setting & rows$phase!='view',]
    x <- raw[[a$run_id]]; y <- raw[[b$run_id]]
    stopifnot(identical(x$value,y$value))
    # Callback batching may split text rows differently; compare actual token IDs,
    # concatenated delivered text and terminal semantics independently of elapsed.
    signature <- function(r) list(tokens=r$events$token_id[r$events$event=='token'],
      text=paste0(r$events$text[r$events$event=='text'],collapse=''),
      terminal=r$events$finish_reason[r$events$event=='prompt_end'])
    stopifnot(identical(signature(x),signature(y)));zero_pairs <- zero_pairs+1L
  }
}
indices <- as.matrix(read.csv('bootstrap.csv')[,-1L]); stopifnot(identical(dim(indices),c(2000L,8L)))
interval_errors <- numeric(length(report$intervals))
for(i in seq_along(report$intervals)) {
  c <- report$intervals[[i]]
  a <- rows[rows$phase=='evaluation' & rows$setting==c$setting,]
  b <- rows[rows$phase=='evaluation' & rows$setting==c$reference,]
  stopifnot(identical(a$item_id,b$item_id),nrow(a)==8L)
  d <- vapply(a$run_id,function(id) metrics[[id]][[c$metric]],numeric(1))-vapply(b$run_id,function(id) metrics[[id]][[c$metric]],numeric(1))
  draw_means <- rowMeans(matrix(d[indices],nrow=2000L,ncol=8L))
  expected <- c(mean(d),unname(quantile(draw_means,c(.025,.975),type=7)))
  observed <- c(c$estimate,c$conf_low,c$conf_high)
  stopifnot(identical(unname(d),as.double(unlist(c$differences))))
  interval_errors[i] <- max(abs(expected-observed));stopifnot(interval_errors[i]<=1e-10)
}
tokenization <- readRDS('view-prompt-tokenization.rds')
stopifnot(identical(tokenization$add_special,TRUE),identical(tokenization$parse_special,FALSE))
ledger <- read.csv('view-states.csv',na.strings=character()); states <- list()
for(i in seq_len(nrow(ledger))) {
  row <- ledger[i,]; s <- readRDS(row$state_file); t <- s$trace; step <- s$step
  stopifnot(step$state_id==row$state_id,step$source_pos==row$source_pos,
    nrow(t)==896L,all(t$layer==12L),all(t$component=='mlp_out'),identical(t$neuron,seq_len(896L)),
    all(is.finite(t$value)),all(t$token_pos==row$source_pos),
    attr(t,'prompt_token_count')==row$prompt_token_count,nrow(s$logits)==3L,
    all(is.finite(s$logits$logit)),all(is.finite(s$logits$prob)),
    step$token_id==s$logits$token_id[1L],step$steering_revision==0L,nrow(attr(s,'steering'))==0L)
  r <- raw[[row$run_id]]; delivered <- r$events$token_id[r$events$event=='token']
  if(row$state_id==1L) stopifnot(row$source_token_id==tail(tokenization$result$ids,1L),
    length(tokenization$result$ids)==row$prompt_token_count,all(t$token==tail(tokenization$result$pieces,1L)),
    step$token_id==delivered[1L],row$generated_prefix_ids=='') else stopifnot(
      row$source_token_id==delivered[1L],as.integer(row$generated_prefix_ids)==delivered[1L])
  states[[row$state_file]] <- s
}
summary <- do.call(rbind,lapply(unique(rows$setting[rows$phase=='evaluation']),function(k) {
  ids <- rows$run_id[rows$phase=='evaluation' & rows$setting==k]
  data.frame(setting=k,tasks=length(ids),required=sum(vapply(ids,function(id) metrics[[id]]$required,numeric(1))),
    mean_characters=mean(vapply(ids,function(id) metrics[[id]]$characters,numeric(1))),
    mean_tokens=mean(vapply(ids,function(id) metrics[[id]]$tokens,numeric(1))),
    truncated=sum(vapply(ids,function(id) metrics[[id]]$truncated,numeric(1))))
}))
write.csv(summary,'owner-summary.csv',row.names=FALSE)
jsonlite::write_json(list(status='PASS',successful_generation_RDS=120L,cancelled_view_RDS=2L,
  retained_states=4L,state_values=3584L,raw_event_rows=event_rows,delivered_token_events=tokens,
  metric_values=720L,zero_identity_pairs=zero_pairs,bootstrap_intervals=36L,
  maximum_interval_rounding_difference=max(interval_errors),models=0,inference=0,RNG_draws=0,
  cancellation=list(states_per_view=2L,delivered_tokens_per_view=1L,error_generated_tokens=2L),
  scope='Independent RDS/text/event/metric/bootstrap/state audit; no general efficacy claim or same-row projection formula assertion across changed histories'),
  'owner-rds-verification.json',auto_unbox=TRUE,pretty=TRUE,digits=NA)
cat('F6E_EVALUATION_RDS_OWNER successes=120 cancellations=2 metrics=720 intervals=36 zero_pairs=28 states=4 models=0 inference=0\n')
