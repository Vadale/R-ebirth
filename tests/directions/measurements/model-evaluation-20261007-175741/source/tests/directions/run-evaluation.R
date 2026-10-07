# F6d-v1. Frozen corpus/protocol precedes this implementation and all model runs.
# Run once in a fresh process/library. Output paths belong to the caller.
library(relm)
root <- normalizePath(Sys.getenv('RELM_REPO', unset = '.'))
out <- Sys.getenv('RELM_F6D_EVIDENCE'); stopifnot(nzchar(out), dir.exists(out))
stopifnot(normalizePath(find.package('relm')) == '/private/tmp/relm-f6d/library/relm')
prompts_path <- file.path(root,'tests/directions/evaluation/prompts.csv')
stopifnot(unname(tools::sha256sum(prompts_path)) == '115589f45ec0a945559df720bcc2c2996717faec78f18de09e61749df63113de')
prompts <- read.csv(prompts_path, colClasses='character', check.names=FALSE)
hash_text <- function(x) {
 p <- tempfile(); on.exit(unlink(p)); con<-file(p,'wb')
 tryCatch(writeBin(charToRaw(enc2utf8(x)),con),finally=close(con)); unname(tools::sha256sum(p))
}
stopifnot(nrow(prompts)==38L,!anyDuplicated(prompts$prompt_sha256),
 identical(vapply(prompts$prompt,hash_text,character(1),USE.NAMES=FALSE),prompts$prompt_sha256))
model_path <- '/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf'
model_sha <- 'ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'
stopifnot(unname(tools::sha256sum(model_path))==model_sha)
start_identity <- file.info(model_path)[,c('size','mtime','ctime'),drop=FALSE]
m <- llm(model_path,backend='cpu',context_length=512L)
main <- function() {
 on.exit(close(m),add=TRUE)
 stopifnot(m$backend=='cpu',m$context_length>=512L,m$layers==24L)
 model <- list(sha256=model_sha,architecture=m$architecture,quantization=m$quantization,
  hidden_size=as.integer(m$hidden_size),layers=as.integer(m$layers),engine_revision='b10828-patched-D039-D040')
 selected <- prompts[prompts$split=='construction' & prompts$role=='target',]
 controls <- prompts[prompts$split=='construction' & prompts$role=='control',]
 stopifnot(nrow(selected)==12L,identical(selected$item_id,controls$item_id))
 # Preflight two matrices before collecting any activation. Every trace is released.
 h<-m$hidden_size; stopifnot(2*12*h*8 + 4*h*64 + 2^20 < 64*1024^2)
 target<-control<-matrix(0,12L,h,dimnames=list(selected$item_id,as.character(seq_len(h))))
 positions<-matrix(0L,12L,2L)
 capture <- function(prompt) {
  tr<-llm_trace(m,prompt,layers=12L,positions='last',components='residual',spill=FALSE)
  stopifnot(!isTRUE(attr(tr,'spilled')),nrow(tr)==h,identical(tr$neuron,seq_len(h)),
   all(tr$layer==12L),all(tr$component=='residual'),length(unique(tr$token_pos))==1L,all(is.finite(tr$value)))
  list(value=tr$value,pos=unique(tr$token_pos),bytes=as.double(object.size(tr)))
 }
 capture_bytes<-matrix(0,12L,2L)
 for(i in 1:12) {
  a<-capture(selected$prompt[i]);target[i,]<-a$value;positions[i,1]<-a$pos;capture_bytes[i,1]<-a$bytes;rm(a)
  b<-capture(controls$prompt[i]);control[i,]<-b$value;positions[i,2]<-b$pos;capture_bytes[i,2]<-b$bytes;rm(b)
 }
 context<-list(model=model,capture=list(component='residual',positions='last',input_format='raw_text',
  tokenizer='gguf_embedded',add_special=TRUE,parse_special=FALSE,template_sha256=NULL,
  context_length=512L,backend='cpu',relm_version=as.character(packageVersion('relm'))),
  pairs=data.frame(pair_id=selected$item_id,target_sha256=selected$prompt_sha256,
   control_sha256=controls$prompt_sha256,target_pos=positions[,1],control_pos=positions[,2]),
  splits=prompts[,c('prompt_sha256','split')],seed=NULL)
 direction<-llm_direction(target,control,context,layer=12L)
 saveRDS(list(target=target,control=control,context=context,capture_bytes=capture_bytes),file.path(out,'construction.rds'))
 coords<-expand.grid(pair=seq_len(12L),neuron=seq_len(h))
 coords$target<-as.vector(target);coords$control<-as.vector(control)
 write.csv(coords,file.path(out,'construction-values.csv'),row.names=FALSE);rm(coords)
 saveRDS(direction,file.path(out,'direction.rds'));loaded<-readRDS(file.path(out,'direction.rds'))
 stopifnot(identical(loaded,direction));print(loaded)
 write.csv(direction,file.path(out,'direction-values.csv'),row.names=FALSE)
 saveRDS(attr(direction,'direction'),file.path(out,'direction-metadata.rds'))
 # Independent operation shape (matrix column means) only in this bounded test.
 expected<-colMeans(target-control);expected<-expected/sqrt(sum(expected^2))
 stopifnot(max(abs(expected-direction$value))<=1e-12)
 envelope<-sum(vapply(list(target,control,context),function(x)as.double(object.size(x)),numeric(1)))+
  4*as.double(object.size(context))+2^20+8*(40*h+16*12)+4*(12+h)
 stopifnot(as.double(object.size(direction))<=envelope,envelope<=64*1024^2)
 # Compare real native delegation with raw existing steering, one derived handle at a time.
 prompt<-selected$prompt[1]
 derived<-llm_apply_direction(m,loaded,model,coef=1)
 actual_logits<-tryCatch(llm_logits(derived,prompt,top=10L),finally=close(derived))
 raw<-llm_steer(m,12L,direction$value,coef=1)
 raw_logits<-tryCatch(llm_logits(raw,prompt,top=10L),finally=close(raw))
 stopifnot(identical(actual_logits,raw_logits),length(m$interventions)==0L)
 write.csv(actual_logits,file.path(out,'adapter-logits.csv'),row.names=FALSE)
 saveRDS(list(model=model,direction_bytes=as.double(object.size(direction)),estimate_bytes=envelope,
  arithmetic_max_error=max(abs(expected-direction$value)),adapter_exact=TRUE,session=sessionInfo()),file.path(out,'model-acceptance.rds'))
 cat('F6D_MODEL_ACCEPTANCE_PASSED 24 captures /',length(direction$value),'coordinates / exact native adapter\n')
 set.seed(1045);random<-rnorm(h);random<-random/sqrt(sum(random^2));saveRDS(random,file.path(out,'random-direction.rds'))
 write.csv(data.frame(neuron=seq_len(h),value=random),file.path(out,'random-direction.csv'),row.names=FALSE)
 runs<-list();run_count<-0L
 generate <- function(task,setting,coefficient,phase,observe=FALSE) {
  run_count<<-run_count+1L;id<-sprintf('%03d-%s-%s-%s',run_count,phase,task$item_id,setting)
  e<-new.env(parent=emptyenv());e$done<-FALSE;e$error<-NULL;e$text<-NULL;e$batches<-list();e$states<-list();e$history<-NULL
  handle<-NULL;t0<-proc.time()[['elapsed']]
  row<-tryCatch({
   handle<-if(setting=='baseline') m else if(setting=='random') llm_steer(m,12L,random,coef=1) else llm_apply_direction(m,loaded,model,coef=coefficient)
   observer<-if(observe) function(state) {
    if(length(e$states)<2L)e$states[[length(e$states)+1L]]<-state
    e$history<-llm_timeline(state,e$history,max_states=8L);NULL
   } else NULL
   p<-llm_generate(handle,task$prompt,chat=FALSE,max_tokens=if(observe)2L else 64L,temperature=0,top_p=.95,seed=101L,
    async=TRUE,on_token=function(batch){e$batches[[length(e$batches)+1L]]<-batch;NULL},
    on_state=observer,layers=if(observe)12L else integer(),top=if(observe)5L else 0L,spill=FALSE)
   promises::then(p,function(value){e$text<-value;e$done<-TRUE;NULL},function(error){e$error<-error;e$done<-TRUE;NULL})
   deadline<-proc.time()[['elapsed']]+120
   while(!e$done && proc.time()[['elapsed']]<deadline)later::run_now(.005,loop=later::global_loop())
   if(!e$done) {llm_cancel(p);stop('Evaluation generation exceeded its 120 second watchdog')}
   if(!is.null(e$error))stop(e$error)
   events<-do.call(rbind,e$batches)
   stopifnot(nrow(events)>0L,identical(events$event_id,seq_len(nrow(events))),
    identical(paste(events$text[events$event=='text'],collapse=''),unname(e$text)),
    sum(events$event=='prompt_end')==1L)
   text<-unname(e$text);finish<-events$finish_reason[events$event=='prompt_end']
   tokens<-tolower(strsplit(trimws(text),'[[:space:]]+')[[1]])
   repeated<-if(length(tokens)<2L)0L else sum(tokens[-1L]==tokens[-length(tokens)])
   pattern<-paste0('(^|[^[:alnum:]])(',task$required_pattern,')([^[:alnum:]]|$)')
   data.frame(run_id=id,phase=phase,item_id=task$item_id,setting=setting,coefficient=coefficient,
    success=TRUE,answer=if(observe)NA else grepl(pattern,text,ignore.case=TRUE,perl=TRUE),
    characters=nchar(text,type='chars'),sampled_tokens=sum(events$event=='token'),
    empty=!nzchar(trimws(text)),truncated=finish=='length',repetition=repeated,finish_reason=finish,
    seconds=proc.time()[['elapsed']]-t0,text=text,error='')
  },error=function(error) {
   e$error<-error
   data.frame(run_id=id,phase=phase,item_id=task$item_id,setting=setting,coefficient=coefficient,
    success=FALSE,answer=NA,characters=NA,sampled_tokens=NA,empty=NA,truncated=NA,repetition=NA,
    finish_reason='',seconds=proc.time()[['elapsed']]-t0,text=if(is.null(e$text))'' else unname(e$text),error=conditionMessage(error))
  },finally={if(!is.null(handle)&&!identical(handle,m))close(handle)})
  saveRDS(as.list(e),file.path(out,paste0(id,'.rds')))
  if(length(e$batches))write.csv(do.call(rbind,e$batches),file.path(out,paste0(id,'-events.csv')),row.names=FALSE)
  runs[[length(runs)+1L]]<<-row;write.csv(do.call(rbind,runs),file.path(out,'runs.csv'),row.names=FALSE)
  list(row=row,state=e$states,history=e$history)
 }
 selection<-prompts[prompts$split=='selection',]
 settings<-data.frame(name=c('baseline','zero','learned--2','learned--1','learned-1','learned-2','random'),coefficient=c(0,0,-2,-1,1,2,1))
 for(i in seq_len(nrow(selection)))for(j in seq_len(nrow(settings)))generate(selection[i,],settings$name[j],settings$coefficient[j],'selection')
 tab<-do.call(rbind,runs);base<-tab[tab$setting=='baseline',]
 stopifnot(nrow(base)==6L,all(base$success))
 scores<-do.call(rbind,lapply(3:6,function(j) {
  candidate<-tab[tab$setting==settings$name[j],]
  eligible<-all(candidate$success)&&all(candidate$answer>=base$answer)&&all(candidate$empty<=base$empty)&&
   all(candidate$truncated<=base$truncated)&&all(candidate$repetition<=base$repetition)&&mean(candidate$characters)<mean(base$characters)
  data.frame(coefficient=settings$coefficient[j],eligible=eligible,mean_characters=mean(candidate$characters))
 }))
 acceptable<-scores[scores$eligible,];chosen<-if(!nrow(acceptable))0 else acceptable$coefficient[order(acceptable$mean_characters,abs(acceptable$coefficient),acceptable$coefficient)][1]
 write.csv(scores,file.path(out,'selection-scores.csv'),row.names=FALSE)
 saveRDS(list(chosen=chosen,scores=scores,protocol='F6d-v1',frozen_before_holdout=Sys.time()),file.path(out,'selection-lock.rds'))
 writeLines(as.character(chosen),file.path(out,'chosen-coefficient.txt'))
 holdout<-prompts[prompts$split=='evaluation',]
 for(i in seq_len(nrow(holdout)))for(setting in c('baseline','zero','selected','random'))generate(holdout[i,],setting,if(setting=='selected')chosen else if(setting=='random')1 else 0,'evaluation')
 final<-do.call(rbind,runs);final<-final[final$phase=='evaluation',]
 stopifnot(nrow(final)==32L,all(final$success))
 base<-final[final$setting=='baseline',]
 set.seed(2045);indices<-replicate(2000L,sample.int(8L,8L,replace=TRUE))
 write.csv(t(indices),file.path(out,'bootstrap-indices.csv'),row.names=FALSE)
 measures<-c('answer','characters','sampled_tokens','empty','truncated','repetition')
 intervals<-list()
 for(setting in c('zero','selected','random'))for(metric in measures) {
  other<-final[final$setting==setting,];stopifnot(identical(other$item_id,base$item_id))
  delta<-as.numeric(other[[metric]])-as.numeric(base[[metric]])
  samples<-colMeans(matrix(delta[indices],8L,2000L))
  q<-quantile(samples,c(.025,.975),names=FALSE)
  intervals[[length(intervals)+1L]]<-data.frame(setting=setting,metric=metric,mean_difference=mean(delta),lower=q[1],upper=q[2])
 }
 intervals<-do.call(rbind,intervals);write.csv(intervals,file.path(out,'paired-intervals.csv'),row.names=FALSE)
 # Separate construction prompt, not a second held-out outcome.
 a<-generate(selected[1,],'baseline',0,'visualization',TRUE)
 b<-generate(selected[1,],'selected',chosen,'visualization',TRUE)
 stopifnot(a$row$success,b$row$success,length(a$state)==2L,length(b$state)==2L)
 settings_context<-list(seed=101L,chat=FALSE,temperature=0,top_p=.95,max_tokens=2L,stop=NULL,
  context_length=512L,backend='cpu',relm_version=as.character(packageVersion('relm')),engine_revision=model$engine_revision)
 record<-function(x,k)list(model_sha256=model_sha,settings=settings_context,generated_tokens=vapply(x$state[seq_len(k)],function(s)s$step$token_id,integer(1)))
 comparisons<-lapply(1:2,function(k)llm_compare(a$state[[k]],b$state[[k]],list(reference=record(a,k),intervention=record(b,k)),layer=12L))
 stopifnot(attr(comparisons[[1]],'alignment')$matched)
 for(x in c(comparisons,list(b$history)))stopifnot(as.double(object.size(x))<=attr(x,'estimate_bytes'))
 saveRDS(list(comparisons=comparisons,history=b$history,chosen=chosen,settings=settings_context),file.path(out,'graphics.rds'))
 write.csv(comparisons[[1]],file.path(out,'comparison-first-state.csv'),row.names=FALSE)
 write.csv(b$history,file.path(out,'timeline.csv'),row.names=FALSE)
 figures<-list(selection=function() {
  plot(scores$coefficient,scores$mean_characters,type='b',pch=19,xlab='Additive coefficient',ylab='Selection mean characters',main='Fixed selection grid; quality guards determine eligibility')
  abline(h=mean(tab$characters[tab$setting=='baseline']),lty=2)
  points(scores$coefficient[!scores$eligible],scores$mean_characters[!scores$eligible],pch=4,col='firebrick',cex=1.5)
 },holdout=function() {
  par(mfrow=c(1,2))
  for(metric in c('characters','answer')) {
   x<-intervals[intervals$metric==metric,];plot(seq_len(nrow(x)),x$mean_difference,ylim=range(c(0,x$lower,x$upper)),xaxt='n',pch=19,
    xlab='Setting versus baseline',ylab=paste('Paired change:',metric),main='8 fixed tasks; 95% paired bootstrap interval')
   axis(1,seq_len(nrow(x)),x$setting);segments(seq_len(nrow(x)),x$lower,seq_len(nrow(x)),x$upper);abline(h=0,lty=2)
  }
 },comparison=function()plot(comparisons[[1]]),timeline=function()plot(b$history))
 for(nm in names(figures)) {
  pdf(file.path(out,paste0(nm,'.pdf')),width=10,height=7);tryCatch(figures[[nm]](),finally=dev.off())
  png(file.path(out,paste0(nm,'.png')),width=1400,height=980,res=140,type='quartz');tryCatch(figures[[nm]](),finally=dev.off())
 }
 stopifnot(identical(start_identity,file.info(model_path)[,c('size','mtime','ctime'),drop=FALSE]))
 writeLines(c('Protocol F6d-v1 executed; raw text and failed runs are retained.',paste('Selected coefficient:',chosen),
  'Literal answer inclusion and eight hand-written tasks do not establish general quality or population coverage.',
  'Recorded provenance plus file-immutability assumptions, not authentication of loaded weights.'),file.path(out,'scope.txt'))
 cat('F6D_FIXED_EVALUATION_PASSED 24 captures / 42 selection / 32 held-out / 2 visualization runs\n')
}
main()
