library(relm)
out <- Sys.getenv('RELM_F6C_EVIDENCE'); stopifnot(nzchar(out))
stopifnot(normalizePath(find.package('relm'))=='/private/tmp/relm-f6c/library/relm')
model_path <- '/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf'
sha <- sub(' .*','',system2('shasum',c('-a','256',shQuote(model_path)),stdout=TRUE))
stopifnot(sha=='ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e')
settings <- list(seed=17,chat=FALSE,temperature=0,top_p=0.95,max_tokens=8L,stop=NULL,
 context_length=512L,backend='cpu',relm_version=as.character(packageVersion('relm')),
 engine_revision='b10828-patched-D039-D040')
m <- llm(model_path,backend='cpu',context_length=512L)
changed <- llm_steer(m,2L,rep(0.1,m$hidden_size),coef=0.5)
old <- options(relm.trace_budget=128*1024)
run <- function(model,spill) {
 options(relm.trace_budget=if(spill) 64*1024 else 128*1024)
 e <- new.env(parent=emptyenv()); e$history<-NULL;e$ids<-integer();e$states<-list();e$done<-FALSE;e$error<-NULL
 promise <- llm_generate(model,'1, 2, 3, 4, 5, 6, 7, 8, 9, 10,',chat=FALSE,max_tokens=8L,
  seed=17,temperature=0,top_p=0.95,async=TRUE,layers=if(spill) NULL else 2L,top=5L,spill=spill,
  on_state=function(state) {
   e$ids<-c(e$ids,state$step$token_id)
   e$history<-llm_timeline(state,e$history,max_states=6L)
   if(state$step$state_id<=2L) e$states[[length(e$states)+1L]]<-state
   NULL
  })
 promises::then(promise,function(value){e$value<-value;e$done<-TRUE;NULL},
  function(error){e$error<-error;e$done<-TRUE;NULL})
 deadline <- unname(proc.time()[['elapsed']])+60
 while(!e$done && unname(proc.time()[['elapsed']])<deadline) later::run_now(0.001,loop=later::global_loop())
 saveRDS(list(ids=e$ids,states=e$states,history=e$history,value=e$value,error=e$error,done=e$done),
  file.path(out,paste0('run-',if(spill)'spill' else if(length(model$interventions))'intervention' else 'reference','.rds')))
 stopifnot(e$done,is.null(e$error),length(e$ids)==8L,length(e$states)==2L,
  attr(e$history,'dropped_states')==2L)
 e
}
tryCatch({
 baseline <- run(m,FALSE); treated <- run(changed,FALSE); spilled <- run(m,TRUE)
 context <- function(a,b,k) {
  record<-function(e)list(model_sha256=sha,settings=settings,generated_tokens=e$ids[seq_len(k)])
  list(reference=record(a),intervention=record(b))
 }
 paired<-llm_compare(baseline$states[[1]],treated$states[[1]],context(baseline,treated,1),2)
 disk<-llm_compare(baseline$states[[1]],spilled$states[[1]],context(baseline,spilled,1),2)
 later_pair<-llm_compare(baseline$states[[2]],treated$states[[2]],context(baseline,treated,2),2)
 stopifnot(attr(paired,'alignment')$matched,nrow(paired)==m$hidden_size,
   identical(paired$difference,paired$intervention-paired$reference),
   identical(disk$reference,disk$intervention),all(disk$difference==0),
   isTRUE(attr(spilled$states[[1]]$trace,'spilled')),
   attr(later_pair,'alignment')$matched==identical(baseline$ids[1],treated$ids[1]))
 if(!attr(later_pair,'alignment')$matched)stopifnot(all(is.na(later_pair$difference)))
 for(x in list(paired,disk,later_pair,treated$history))stopifnot(as.double(object.size(x))<=attr(x,'estimate_bytes'),attr(x,'estimate_bytes')<=attr(x,'max_bytes'))
 saveRDS(list(comparison=paired,spill=disk,later_comparison=later_pair,timeline=treated$history,
   model_sha256=sha,settings=settings,session=sessionInfo()),file.path(out,'model-graphics.rds'))
 write.csv(paired,file.path(out,'paired.csv'),row.names=FALSE)
 write.csv(treated$history,file.path(out,'timeline.csv'),row.names=FALSE)
 figures<-list(map=function()plot(changed,layers=c(1:4,12L,24L)),
  comparison=function()plot(paired),timeline=function()plot(treated$history))
 for(nm in names(figures)) {
  pdf(file.path(out,paste0('actual-',nm,'.pdf')),width=10,height=7)
  tryCatch(figures[[nm]](),finally=dev.off())
  png(file.path(out,paste0('actual-',nm,'.png')),width=1400,height=980,res=140,type='quartz')
  tryCatch(figures[[nm]](),finally=dev.off())
 }
 cat('F6C_MODEL_COMPOSITION_PASSED 3runs 24states 2paired 1spill\n')
},finally={options(old);close(changed);close(m)})
