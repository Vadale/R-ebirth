a<-commandArgs(TRUE);stopifnot(length(a)==5L)
out<-a[[1]];backend<-a[[2]];interval<-as.numeric(a[[3]]);model<-a[[4]];logger<-a[[5]]
library(relm);clock<-function()proc.time()[['elapsed']];cpu<-function()sum(proc.time()[c('user.self','sys.self')])
mark<-function(x)write.csv(data.frame(stage=x,epoch=as.numeric(Sys.time())),file.path(out,'current-operation.csv'),row.names=FALSE)
main<-function(){
 stopifnot(backend%in%c('cpu','cuda'),interval%in%c(.005,.001),relm:::relm_live_poll_interval==.005)
 if(interval!=.005){stopifnot(backend=='cuda');assignInNamespace('relm_live_poll_interval',interval,ns='relm')}
 shim<-dyn.load(logger);stopifnot(.C('f6e_log_start',getLoadedDLLs()[['relm']][['path']],file.path(out,'native.log'),status=integer(1),PACKAGE=shim[['name']])$status==0L)
 m<-projected<-NULL
 on.exit({if(!is.null(projected))close(projected);if(!is.null(m))close(m);stopifnot(.C('f6e_log_stop',status=integer(1),PACKAGE=shim[['name']])$status==0L)},add=TRUE)
 prompt<-paste('Write an operating checklist for a fictional neighbourhood repair cafe.',
  'The cafe has eight volunteers, three work tables, and two evening sessions each week.',
  'Visitors bring small household objects with a short description of the fault.',
  'Plan the intake record, label uncertain diagnoses, and explain how to keep parts with their objects.',
  'Describe a queue that treats visitors fairly, a simple handover between volunteers, and a closing routine.',
  'Include checks for missing labels, duplicate records, and objects waiting for parts.',
  'Use plain language, short headings, and actions that a new volunteer can follow.',
  'Do not invent statistics or cite organisations. Finish with a short procedure for reviewing the records each month.')
 writeBin(charToRaw(enc2utf8(prompt)),file.path(out,'prompt.txt'))
 saveRDS(list(backend=backend,live_interval=interval,context=512L,max_tokens=128L,seed=8002L,
  temperature=0,top_p=.95,chat=FALSE,mmap=TRUE,gpu_layers=NULL,stop=NULL,images=NULL,schema=NULL),file.path(out,'settings.rds'))
 counts<-c(load=0L,tokenize=0L,derive=0L,trace=0L,generate=0L)
 bump<-function(x){counts[[x]]<<-counts[[x]]+1L;saveRDS(counts,file.path(out,'attempts.rds'))}
 mark('load');bump('load');t<-clock();m<-llm(model,backend=backend,context_length=512L);load<-clock()-t
 bump('tokenize');tokens<-relm:::relm_check(relm:::rebirth_tokenize(m$ptr,prompt,TRUE,FALSE));saveRDS(tokens,file.path(out,'tokens.rds'))
 stopifnot(length(tokens$ids)>32L,length(tokens$ids)+128L<512L)
 mark('derive');d<-readRDS('/tmp/relm-phase8/installed-pic/workflow/directions.rds')$mlp_out
 bump('derive');t<-clock();projected<-llm_apply_direction(m,d,attr(d,'direction')$context$model,coef=1,operator='project');derive<-clock()-t
 saveRDS(list(load_seconds=load,derive_seconds=derive,metadata=m[c('architecture','backend','hidden_size','layers','context_length','quantization')]),file.path(out,'operations.rds'))
 results<-list()
 for(iteration in 0:3){
  for(mode in c('plain_sync','plain_stream','filtered_trace','projection_stream','live_stream')){
   name<-paste0('iteration',iteration,'-',mode);mark(name)
   events<-list();arrivals<-numeric();states<-list();value<-error<-NULL;done<-FALSE
   start<-clock();cpu0<-cpu();epoch<-as.numeric(Sys.time());submission<-NA_real_
   if(mode=='filtered_trace'){
    bump('trace');value<-tryCatch(llm_trace(m,prompt,layers=12L,positions='last',components=c('residual','mlp_out'),spill=FALSE),error=identity)
    if(inherits(value,'condition')){error<-value;value<-NULL};done<-TRUE
   }else{
    bump('generate');args<-list(m=if(mode=='projection_stream')projected else m,prompt=prompt,
      max_tokens=128L,temperature=0,top_p=.95,seed=8002L,chat=FALSE)
    if(mode=='plain_sync'){
     value<-tryCatch(do.call(llm_generate,args),error=identity)
     if(inherits(value,'condition')){error<-value;value<-NULL};done<-TRUE
    }else{
     args<-c(args,list(async=TRUE,on_token=function(batch){events[[length(events)+1L]]<<-batch;arrivals<<-c(arrivals,clock()-start)}))
     if(mode=='live_stream')args<-c(args,list(on_state=function(s){states[[length(states)+1L]]<<-s;NULL},layers=12L,components='mlp_out',top=5L,spill=FALSE))
     pending<-tryCatch(do.call(llm_generate,args),error=identity);submission<-clock()-start
     if(inherits(pending,'condition')){error<-pending;done<-TRUE}else{
      observer<-promises::then(pending,onFulfilled=function(x){value<<-x;done<<-TRUE;NULL},onRejected=function(e){error<<-e;done<<-TRUE;NULL})
      deadline<-start+120;while(!done&&clock()<deadline)later::run_now(.01)
      if(!done){llm_cancel(args$m);deadline<-clock()+30;while(!done&&clock()<deadline)later::run_now(.01)}
     }
    }
   }
   x<-list(iteration=iteration,mode=mode,start_epoch=epoch,end_epoch=as.numeric(Sys.time()),wall=clock()-start,cpu_seconds=cpu()-cpu0,
    submission=submission,events=events,delivery_elapsed=arrivals,states=states,value=value,error=error,settled=done)
   saveRDS(x,file.path(out,paste0(name,'.rds')))
   if(!done)stop('Benchmark timeout: no replay');if(!is.null(error))stop(error)
   stopifnot(is.null(relm:::.relm_async$job))
   nt<-first<-last<-firstR<-NA_real_;reason<-''
   if(mode=='filtered_trace')stopifnot(nrow(value)==1792L,all(is.finite(value$value)))else stopifnot(attr(value,'seed')==8002L,length(value)==1L)
   if(length(events)){
    e<-do.call(rbind,events);tok<-e[e$event=='token',];en<-e[e$event=='prompt_end',]
    stopifnot(identical(names(e),relm:::stream_columns),identical(e$event_id,seq_len(nrow(e))),all(diff(e$elapsed)>=0),
     identical(paste0(e$text[e$event=='text'],collapse=''),unname(value[[1]])),nrow(tok)>1L,nrow(en)==1L)
    nt<-nrow(tok);first<-tok$elapsed[1];last<-tail(tok$elapsed,1);reason<-en$finish_reason
    firstR<-rep(arrivals,vapply(events,nrow,integer(1)))[which(e$event=='token')[1]]
   }
   results[[length(results)+1L]]<-data.frame(iteration=iteration,mode=mode,wall=x$wall,cpu_seconds=x$cpu_seconds,
    submission=submission,tokens=nt,first_native=first,first_R=firstR,decode_span=last-first,
    decode_tokens_per_second=(nt-1)/(last-first),delivery_callbacks=length(events),live_states=length(states),finish_reason=reason)
   write.csv(do.call(rbind,results),file.path(out,'summary.csv'),row.names=FALSE)
  }
 }
 mark('close');close(projected);projected<-NULL;close(m);m<-NULL
 stopifnot(is.null(relm:::.relm_async$job));cat('WP13_BENCHMARK_COMPLETE config=',backend,'/',interval,' attempts=',paste(counts,collapse=','),'\n',sep='')
}
main()
