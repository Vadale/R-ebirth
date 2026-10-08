# Inspect retained R values only; no package/model is loaded or called.
p<-'/private/tmp/relm-f6e/installed-public-budget-20261008-105355'
c<-readRDS(file.path(p,'carried-public-captures.rds'));d<-readRDS(file.path(p,'carried-public-direction.rds'));b<-readRDS(file.path(p,'public-budget.rds'))
read<-function(f)readRDS(file.path(p,f));assert<-function(x)stopifnot(isTRUE(x))
info<-attr(d,'direction');stopifnot(info$schema=='relm_direction/2',info$component=='mlp_out',info$layer==12L)
for(k in seq_len(4L)) {
 tr<-c$traces[[k]];stopifnot(nrow(tr)==896L,identical(tr$neuron,1:896),all(tr$component=='mlp_out'),all(tr$layer==12L),all(tr$token_pos==9L))
 row<-if(k<=2L)1L else 2L;expected<-if(k%%2L) c$target[row,] else c$control[row,]
 stopifnot(identical(unname(as.numeric(tr$value)),unname(as.numeric(expected))))
}
write.csv(d[,c('neuron','value')],file.path(p,'owner-direction.csv'),row.names=FALSE)
for(n in c('profile','inputs','terms')) {
 x<-if(n=='profile') b$profile else b$response[[n]]
 write.csv(data.frame(field=names(x),value=unlist(x,use.names=FALSE)),file.path(p,paste0('owner-',n,'.csv')),row.names=FALSE)
}
refusals<-c(minus_one_refused='relm_error_oom',duplicate_refused='relm_error_intervention',trace_refused='relm_error_trace',embed_refused='relm_error_embed',images_refused='relm_error_image')
for(n in names(refusals)) assert(refusals[[n]] %in% read(paste0('condition-',n,'.rds'))$class)
e<-read('condition-minus_one_refused.rds');stopifnot(e$fields$estimate_bytes==b$response$terms$total_bytes,e$fields$budget_bytes==b$response$terms$total_bytes-1)
summary<-read('public-summary.rds');assert(identical(summary$original,read('new-reset-baseline.rds')))
stream<-read('public-stream.rds');stopifnot(is.null(stream$error),identical(stream$value,summary$projected),sum(stream$events$event=='token')==4L,sum(stream$events$event=='prompt_end')==1L,identical(paste0(stream$events$text[stream$events$event=='text'],collapse=''),as.character(stream$value)))
stopifnot(identical(gsub('[[:space:]]','',as.character(read('public-structured.rds'))),'{"answer":"ok"}'))
stopifnot(identical(attr(read('public-chat.rds'),'seed'),1047),identical(attr(read('public-metal.rds'),'seed'),1047))
a<-read('live-original.rds')$states[[1]];z<-read('live-projected.rds')$states[[1]]
stopifnot(a$step$state_id==1L,z$step$state_id==1L,a$step$source_pos==z$step$source_pos,identical(attr(a$trace,'prompts'),attr(z$trace,'prompts')))
for(x in list(a,z))stopifnot(nrow(x$trace)==896L,identical(x$trace$neuron,1:896),all(x$trace$component=='mlp_out'),all(x$trace$layer==12L))
values<-read.csv(file.path(p,'public-projection-values.csv'));stopifnot(max(abs(values$before-a$trace$value))<1e-12,max(abs(values$after-z$trace$value))<1e-12,max(abs(values$direction-d$value))<1e-12)
live<-read('public-live-cancel.rds');stopifnot(length(live$states)==3L,live$tokens==2L,is.null(live$value),inherits(live$error,'relm_error_cancelled'),identical(vapply(live$states,function(x)x$step$steering_revision,integer(1)),c(0L,1L,1L)),identical(vapply(live$states,function(x)attr(x,'steering')$coef,double(1)),c(0,.25,.25)))
stopifnot(identical(summary$counts,list(load=2L,trace=0L,generate=18L,logits=1L,derive=6L)))
cat('F6E_PUBLIC_OWNER_RAW captures=4 width=896 pairs=2 schema=2 ledger_terms=14 structured=1 streamed_tokens=4 refusal_payloads=5 live_states=3 delivered_before_cancel=2 native_generated_tokens=',live$error$generated_tokens,' model_calls=0\n',sep='')
