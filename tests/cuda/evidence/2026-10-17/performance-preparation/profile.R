# One diagnostic profiling pass. No efficacy tuning or reference generation.
a <- commandArgs(TRUE); stopifnot(length(a)==3L)
out <- a[[1L]]; model_path <- a[[2L]]; logger <- a[[3L]]
library(relm)
stopifnot(identical(sort(relm:::rebirth_available_backends()), c('cpu','cuda')))
clock <- function() proc.time()[['elapsed']]
mark <- function(stage) write.csv(data.frame(stage=stage,epoch=as.numeric(Sys.time())),file.path(out,'current-operation.csv'),row.names=FALSE)
profile <- function() {
  shim <- dyn.load(logger); logpath <- file.path(out,'native.log')
  stopifnot(.C('f6e_log_start',getLoadedDLLs()[['relm']][['path']],logpath,status=integer(1),PACKAGE=shim[['name']])$status==0L)
  # on.exit runs in registration order: all owners close before restoring logger.
  m <- projected <- NULL
  on.exit({if(!is.null(projected))close(projected);if(!is.null(m))close(m)
    stopifnot(.C('f6e_log_stop',status=integer(1),PACKAGE=shim[['name']])$status==0L)}, add=TRUE)
  prompt <- paste(
    'Draft a practical checklist for a fictional community seed library.',
    'There are twelve volunteers, four labelled storage cupboards, and three weekly opening sessions.',
    'Packets arrive from local gardeners with a plant name, collection date, and approximate seed count.',
    'The library needs a simple intake record, a way to mark uncertain labels, a dry storage routine,',
    'and a fair lending procedure that a new volunteer can follow.',
    'Explain the steps in their working order. Include checks for duplicate records, damaged packets,',
    'and returns. Use plain language, short headings, and specific actions. Do not invent statistics',
    'or cite organisations. Finish by describing how the volunteers can review the records each month.'
  )
  writeBin(charToRaw(enc2utf8(prompt)),file.path(out,'prompt.txt'))
  settings<-list(context_length=512L,max_tokens=128L,temperature=0,top_p=.95,seed=8001L,chat=FALSE,
    backend='cuda',gpu_layers=NULL,mmap=TRUE,stop=NULL,images=NULL,schema=NULL,
    fixed_order=c('plain_stream','filtered_trace','projection_stream','live_stream'),
    timing_scope='one diagnostic pass, no warmups or performance acceptance; native event timestamps include submission/prompt processing/sampling')
  saveRDS(settings,file.path(out,'settings.rds'));mark('load');t<-clock()
  m<-llm(model_path,backend='cuda',context_length=512L);load_seconds<-clock()-t
  mark('tokenize');tokens<-relm:::relm_check(relm:::rebirth_tokenize(m$ptr,prompt,TRUE,FALSE))
  stopifnot(length(tokens$ids)>32L,length(tokens$ids)+128L<512L)
  saveRDS(tokens,file.path(out,'prompt-tokenization.rds'))
  run_generation <- function(handle,name,live=FALSE) {
    events<-list();deliveries<-numeric();states<-list();value<-failure<-NULL;done<-FALSE
    mark(name); start<-clock(); epoch<-as.numeric(Sys.time())
    args<-list(m=handle,prompt=prompt,max_tokens=128L,temperature=0,top_p=.95,seed=8001L,chat=FALSE,async=TRUE,
      on_token=function(batch){events[[length(events)+1L]]<<-batch;deliveries<<-c(deliveries,clock()-start)})
    if(live)args<-c(args,list(on_state=function(x){states[[length(states)+1L]]<<-x;NULL},layers=12L,components='mlp_out',top=5L,spill=FALSE))
    pending<-do.call(llm_generate,args);submit<-clock()-start
    observer<-promises::then(pending,onFulfilled=function(x){value<<-x;done<<-TRUE;NULL},
      onRejected=function(e){failure<<-e;done<<-TRUE;NULL})
    deadline<-start+120
    while(!done && clock()<deadline)later::run_now(.01)
    if(!done){llm_cancel(handle);deadline<-clock()+30;while(!done && clock()<deadline)later::run_now(.01)}
    result<-list(name=name,start_epoch=epoch,end_epoch=as.numeric(Sys.time()),wall=clock()-start,submission=submit,
      events=events,delivery_elapsed=deliveries,states=states,value=value,error=failure,settled=done)
    saveRDS(result,file.path(out,paste0(name,'.rds')))
    if(!done)stop('Profiling timeout; raw partial observations retained')
    if(!is.null(failure))stop(failure)
    e<-do.call(rbind,events);expected<-relm:::stream_columns
    stopifnot(identical(names(e),expected),identical(e$event_id,seq_len(nrow(e))),all(diff(e$elapsed)>=0),
      identical(paste0(e$text[e$event=='text'],collapse=''),unname(value[[1L]])),attr(value,'seed')==8001)
    te<-e[e$event=='token',];end<-e[e$event=='prompt_end',];stopifnot(nrow(te)>1,nrow(end)==1)
    delivery<-rep(deliveries,vapply(events,nrow,integer(1)))
    data.frame(mode=name,wall=result$wall,submission=submit,tokens=nrow(te),
      first_native=te$elapsed[1L],first_R=delivery[which(e$event=='token')[1L]],
      decode_span=tail(te$elapsed,1L)-te$elapsed[1L],
      decode_tokens_per_second=(nrow(te)-1)/(tail(te$elapsed,1L)-te$elapsed[1L]),
      delivery_callbacks=length(events),live_states=length(states),finish_reason=end$finish_reason)
  }
  summaries<-run_generation(m,'plain_stream')
  mark('filtered_trace');t<-clock();tr<-llm_trace(m,prompt,layers=12L,positions='last',components=c('residual','mlp_out'),spill=FALSE)
  trace_seconds<-clock()-t;saveRDS(list(trace=tr,wall=trace_seconds),file.path(out,'filtered_trace.rds'))
  stopifnot(nrow(tr)==1792L,all(is.finite(tr$value)))
  mark('derive');d<-readRDS('/tmp/relm-phase8/installed-pic/workflow/directions.rds')$mlp_out
  record<-attr(d,'direction')$context$model;t<-clock()
  projected<-llm_apply_direction(m,d,record,coef=1,operator='project');derive_seconds<-clock()-t
  summaries<-rbind(summaries,run_generation(projected,'projection_stream'))
  close(projected);projected<-NULL
  summaries<-rbind(summaries,run_generation(m,'live_stream',TRUE))
  plain_live_text_identity<-identical(readRDS(file.path(out,'plain_stream.rds'))$value,readRDS(file.path(out,'live_stream.rds'))$value)
  write.csv(summaries,file.path(out,'summary.csv'),row.names=FALSE)
  saveRDS(list(load_seconds=load_seconds,trace_seconds=trace_seconds,derive_seconds=derive_seconds,
    model_metadata=m[c('architecture','backend','hidden_size','layers','context_length','quantization')],
    plain_live_text_identity=plain_live_text_identity,valid_loads=1L,traces=1L,generations=3L,derives=1L,tokenize=1L),file.path(out,'operations.rds'))
  mark('close');close(m);m<-NULL;stopifnot(is.null(relm:::.relm_async$job))
  cat('WP13_PROFILE_COMPLETE loads=1 traces=1 generations=3 derives=1 tokenize=1\n')
}
profile()
