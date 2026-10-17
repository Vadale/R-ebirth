root<-'/tmp/relm-phase8/performance-benchmark';nameset<-c('cpu_baseline','cuda_baseline','cuda_live_1ms')
columns<-c('event_id','event','prompt_id','token_pos','token_id','text','elapsed','finish_reason','validated')
report<-all<-list();counts<-integer(5);prompt_ids<-NULL;frames<-list()
for(config in nameset){
 p<-file.path(root,config);s<-readRDS(file.path(p,'settings.rds'));toks<-readRDS(file.path(p,'tokens.rds'))
 stopifnot(s$seed==8002L,s$max_tokens==128L,s$context==512L,s$temperature==0,s$top_p==.95,
  isFALSE(s$chat),identical(s$backend,if(config=='cpu_baseline')'cpu'else'cuda'),s$live_interval==if(config=='cuda_live_1ms').001 else .005)
 if(is.null(prompt_ids))prompt_ids<-toks$ids else stopifnot(identical(prompt_ids,toks$ids))
 at<-readRDS(file.path(p,'attempts.rds'));stopifnot(identical(at,c(load=1L,tokenize=1L,derive=1L,trace=4L,generate=16L)));counts<-counts+at
 saved<-read.csv(file.path(p,'summary.csv'));stopifnot(nrow(saved)==20L)
 outcomes<-list();r<-list();repeat_values<-0L
 for(iter in 0:3){
  for(mode in c('plain_sync','plain_stream','filtered_trace','projection_stream','live_stream')){
   key<-paste0('iteration',iter,'-',mode);x<-readRDS(file.path(p,paste0(key,'.rds')));outcomes[[key]]<-x
   stopifnot(isTRUE(x$settled),is.null(x$error),x$mode==mode,x$iteration==iter,is.finite(x$wall),x$wall>0,
    is.finite(x$cpu_seconds),x$cpu_seconds>=0)
   row<-saved[saved$mode==mode & saved$iteration==iter,];stopifnot(nrow(row)==1)
   stopifnot(max(abs(c(x$wall,x$cpu_seconds)-c(row$wall,row$cpu_seconds)))<1e-10)
   if(mode=='filtered_trace'){
    stopifnot(nrow(x$value)==1792L,all(is.finite(x$value$value)),all(x$value$layer==12L))
   }else{
    stopifnot(attr(x$value,'seed')==8002L,length(x$value)==1L)
    if(mode!='plain_sync'){
     e<-do.call(rbind,x$events);tok<-e[e$event=='token',];end<-e[e$event=='prompt_end',]
     stopifnot(identical(names(e),columns),identical(e$event_id,seq_len(nrow(e))),all(diff(e$elapsed)>=0),
      identical(tok$token_pos,seq_len(nrow(tok))),nrow(tok)==128L,nrow(end)==1L,end$finish_reason=='length',
      identical(paste0(e$text[e$event=='text'],collapse=''),unname(x$value[[1]])),
      length(x$delivery_elapsed)==length(x$events),all(diff(x$delivery_elapsed)>=0))
     arrival<-rep(x$delivery_elapsed,vapply(x$events,nrow,integer(1)))
     calc<-c(submission=x$submission,tokens=nrow(tok),first_native=tok$elapsed[1],
      first_R=arrival[which(e$event=='token')[1]],decode_span=diff(range(tok$elapsed)),
      decode_tokens_per_second=(nrow(tok)-1)/diff(range(tok$elapsed)),delivery_callbacks=length(x$events),live_states=length(x$states))
     stopifnot(max(abs(unlist(row[names(calc)])-calc))<1e-10)
     if(mode=='live_stream'){
      stopifnot(length(x$states)==128L)
      for(i in seq_along(x$states)){
       st<-x$states[[i]];stopifnot(st$step$state_id==i,st$step$token_pos==i,st$step$token_id==tok$token_id[i],
        st$step$source_pos==length(toks$ids)+i-1L,nrow(st$trace)==896L,all(is.finite(st$trace$value)),
        all(st$trace$layer==12L),all(st$trace$component=='mlp_out'),nrow(st$logits)==5L,all(is.finite(st$logits$logit)))
      }
     }
    }
   }
   if(iter>0){
    prev<-outcomes[[paste0('iteration0-',mode)]]
    stopifnot(identical(prev$value,x$value))
    if(length(x$events)){
     pe<-do.call(rbind,prev$events);ce<-do.call(rbind,x$events);stopifnot(identical(pe[names(pe)!='elapsed'],ce[names(ce)!='elapsed']))
    }
    if(length(x$states))for(i in seq_along(x$states)){
     a<-prev$states[[i]];b<-x$states[[i]];a$step$elapsed<-b$step$elapsed<-NULL;stopifnot(identical(a,b));repeat_values<-repeat_values+nrow(a$trace)
    }
   }
   frames[[length(frames)+1L]]<-cbind(config=config,row)
  }
  sync<-outcomes[[paste0('iteration',iter,'-plain_sync')]];stream<-outcomes[[paste0('iteration',iter,'-plain_stream')]];live<-outcomes[[paste0('iteration',iter,'-live_stream')]]
  stopifnot(identical(sync$value,stream$value),identical(stream$value,live$value))
  a<-do.call(rbind,stream$events);b<-do.call(rbind,live$events);stopifnot(identical(a[names(a)!='elapsed'],b[names(b)!='elapsed']))
 }
 all[[config]]<-outcomes;report[[config]]<-list(attempts=at,operations=readRDS(file.path(p,'operations.rds')),live_repeat_coordinates=repeat_values)
}
# Candidate uses same CUDA trajectories: compare all values/events/states without timing.
for(key in names(all$cuda_baseline)){
 a<-all$cuda_baseline[[key]];b<-all$cuda_live_1ms[[key]];stopifnot(identical(a$value,b$value))
 if(length(a$events)){
  ae<-do.call(rbind,a$events);be<-do.call(rbind,b$events);stopifnot(identical(ae[names(ae)!='elapsed'],be[names(be)!='elapsed']))
 }
 if(length(a$states))for(i in seq_along(a$states)){
  aa<-a$states[[i]];bb<-b$states[[i]];aa$step$elapsed<-bb$step$elapsed<-NULL;stopifnot(identical(aa,bb))
 }
}
write.csv(do.call(rbind,frames),file.path(root,'owner-timings.csv'),row.names=FALSE)
saveRDS(list(status='passed',counts=counts,prompt_tokens=length(prompt_ids),configs=report,
 same_backend_repeats=TRUE,sync_stream_live_identity=TRUE,cuda_candidate_identity=TRUE,
 owner_model_calls=0L),file.path(root,'owner-results.rds'))
cat('BENCHMARK_RAW_OWNER_PASS 3configs 60operationrecords 48generations 12traces 1536livestates; no model execution\n')
