p <- '/tmp/relm-phase8/performance-profile'
saved <- read.csv(file.path(p,'summary.csv'))
cols <- c('event_id','event','prompt_id','token_pos','token_id','text','elapsed','finish_reason','validated')
all <- list(); result <- list()
for (name in c('plain_stream','projection_stream','live_stream')) {
 x <- readRDS(file.path(p,paste0(name,'.rds'))); all[[name]] <- x
 stopifnot(isTRUE(x$settled),is.null(x$error),attr(x$value,'seed')==8001,length(x$value)==1L,
  length(x$events)==length(x$delivery_elapsed),all(diff(x$delivery_elapsed)>=0))
 e <- do.call(rbind,x$events); t <- e[e$event=='token',]; end<-e[e$event=='prompt_end',]
 stopifnot(identical(names(e),cols),identical(e$event_id,seq_len(nrow(e))),all(diff(e$elapsed)>=0),
  identical(t$token_pos,seq_len(nrow(t))),all(is.finite(t$elapsed)),all(t$token_id>=0),
  identical(paste0(e$text[e$event=='text'],collapse=''),unname(x$value[[1L]])),nrow(end)==1L,
  nrow(t)==128L,end$finish_reason=='length')
 s<-saved[saved$mode==name,]; delivery<-rep(x$delivery_elapsed,vapply(x$events,nrow,integer(1)))
 calc<-c(wall=x$wall,submission=x$submission,tokens=nrow(t),first_native=t$elapsed[1],
  first_R=delivery[which(e$event=='token')[1]],decode_span=diff(range(t$elapsed)),
  decode_tokens_per_second=(nrow(t)-1)/diff(range(t$elapsed)),delivery_callbacks=length(x$events),live_states=length(x$states))
 stopifnot(max(abs(unlist(s[names(calc)])-calc))<1e-10)
 result[[name]] <- data.frame(mode=name,as.list(calc),event_rows=nrow(e))
}
l<-all$live_stream;plain<-all$plain_stream
stopifnot(identical(plain$value,l$value),identical(do.call(rbind,plain$events)$token_id,do.call(rbind,l$events)$token_id))
for(i in seq_along(l$states)) {
 s<-l$states[[i]];stopifnot(s$step$state_id==i,s$step$token_pos==i,s$step$source_pos==131L+i,
  s$step$token_id==do.call(rbind,l$events)$token_id[do.call(rbind,l$events)$event=='token'][i],
  nrow(s$trace)==896L,all(is.finite(s$trace$value)),all(s$trace$layer==12L),
  all(s$trace$component=='mlp_out'),nrow(s$logits)==5L,all(is.finite(s$logits$logit)))
}
tr<-readRDS(file.path(p,'filtered_trace.rds'));stopifnot(nrow(tr$trace)==1792L,all(is.finite(tr$trace$value)))
tok<-readRDS(file.path(p,'prompt-tokenization.rds'));stopifnot(length(tok$ids)==132L,length(tok$pieces)==132L)
ops<-readRDS(file.path(p,'operations.rds'));stopifnot(identical(unlist(ops[c('valid_loads','traces','generations','derives','tokenize')]),c(valid_loads=1L,traces=1L,generations=3L,derives=1L,tokenize=1L)),tr$wall==ops$trace_seconds)
write.csv(do.call(rbind,result),file.path(p,'owner-recomputed.csv'),row.names=FALSE)
saveRDS(list(status='passed',results=result,operations=ops,prompt_tokens=132L,
 live_coordinates=128L*896L,plain_live_text_ids_identical=TRUE,models_executed_by_owner=0L),file.path(p,'owner-results.rds'))
cat('PROFILE_RAW_OWNER_PASS: 3 generations,384 sampled tokens,128 live states,114688 live coordinates; no model execution\n')
