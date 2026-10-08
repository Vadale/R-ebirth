# New F6e installed public-path gate. Operational prompts are independent of the
# frozen F6e selection/held-out corpus. No result is a behavioral quality claim.
library(relm)
stopifnot(normalizePath(find.package('relm'))==normalizePath(Sys.getenv('F6E_EXPECT_LIBRARY')))
args <- commandArgs(TRUE); stopifnot(length(args)==2L)
path <- args[[1L]]; out <- args[[2L]]
stopifnot(identical(unname(tools::sha256sum(path)),
  'ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'))
expected <- c('installed_signature','installed_wrappers','cpu_loaded','capture_coordinates',
 'schema2_real_captures','trusted_artifact_roundtrip','baseline_public_logits',
 'zero_public_logits','zero_seeded_text','exact_public_budget','minus_one_refused',
 'project_public_constructed','project_public_logits','duplicate_refused',
 'trace_refused','embed_refused','images_refused','static_sync_seeded_reset',
 'chat_text_route','structured_text_route','async_stream_text_route',
 'live_original_state','live_projected_state','public_same_row_projection',
 'mixed_inheritance','live_reply_applied','live_cancel_before_token',
 'mixed_seeded_restore','original_seeded_reset','child_survives_parent_close',
 'cpu_closed','metal_loaded','metal_public_constructed','metal_zero_identity',
 'metal_active_text_route','metal_original_reset','metal_closed')
expected <- expected[-seq_len(10L)]
writeLines(expected,file.path(out,'expected-cases.txt'))
rows <- data.frame(case=character(),status=character(),refusal=logical())
check <- function(name, ok, refusal=FALSE) {
 if(!identical(name,expected[[nrow(rows)+1L]])) stop('case order: ',name)
 if(!isTRUE(ok)) stop('F6e public gate failed: ',name)
 rows[nrow(rows)+1L,] <<- list(name,'passed',refusal)
 write.csv(rows,file.path(out,'public-cases.csv'),row.names=FALSE)
 cat('F6E_PUBLIC_CASE ',name,' refusal=',refusal,'\n',sep='');flush.console()
}
refuses <- function(expr, cls) {
 z<-tryCatch(force(expr),error=identity)
 id<-expected[[nrow(rows)+1L]]
 saveRDS(if(inherits(z,'error')) list(class=class(z),message=conditionMessage(z),fields=as.list(z)) else list(unexpected_class=class(z)),file.path(out,paste0('condition-',id,'.rds')))
 if(inherits(z,'llm')) close(z)
 inherits(z,cls)
}
hash_text <- function(x) { p<-tempfile('f6e-operational-prompt-');on.exit(unlink(p));writeBin(charToRaw(enc2utf8(x)),p);unname(tools::sha256sum(p)) }
count <- list(load=0L,trace=0L,generate=0L,logits=0L,derive=0L)
write_count <- function() dput(count,file=file.path(out,'public-call-counts.R'))
load <- function(backend) {count$load<<-count$load+1L;write_count();llm(path,backend=backend,context_length=512L)}
run <- function(m,prompt='11, 12, 13, 14, 15,',...) {
 count$generate<<-count$generate+1L;write_count();llm_generate(m,prompt,temperature=0,top_p=.95,seed=1047L,...)
}
logits <- function(m,prompt) {count$logits<<-count$logits+1L;write_count();llm_logits(m,prompt,top=12L)}
apply <- function(m,d,context,coef=1,max_bytes=64*1024^2) {count$derive<<-count$derive+1L;write_count();llm_apply_direction(m,d,context,coef=coef,max_bytes=max_bytes,operator='project')}
observe <- function(p) {
 x<-new.env(parent=emptyenv());x$done<-FALSE;x$error<-NULL;x$value<-NULL;x$settlements<-0L
 promises::then(p,function(v){x$value<-v;x$done<-TRUE;x$settlements<-x$settlements+1L;NULL},
 function(e){x$error<-e;x$done<-TRUE;x$settlements<-x$settlements+1L;NULL})
 deadline<-proc.time()[['elapsed']]+120
 while(!x$done && proc.time()[['elapsed']]<deadline) later::run_now(.05,loop=later::global_loop())
 if(!x$done) stop('F6e public promise timed out')
 x
}
main <- function() {
 parent<-Sys.getenv('F6E_PUBLIC_PARENT')
 stopifnot(nzchar(parent),file.exists(file.path(parent,'public-captures.rds')))
 captured<-readRDS(file.path(parent,'public-captures.rds'));record<-captured$context$model
 d<-readRDS(file.path(parent,'public-direction.rds'))
 m<-load('cpu');on.exit(close(m),add=TRUE)
 stopifnot(identical(m$backend,'cpu'),m$hidden_size==896,m$layers==24,
   identical(m$architecture,record$architecture),identical(m$quantization,record$quantization))
 # Previously completed four captures, construction and zero identity are carried
 # at their archived parent source. This new baseline is required to check reset
 # of the new live handle; it is not another zero-identity test.
 prompt<-'11, 12, 13, 14, 15,'
 original_logits<-readRDS(file.path(parent,'original-logits.rds'))
 baseline<-run(m,prompt,chat=FALSE,max_tokens=4L)
 saveRDS(baseline,file.path(out,'new-reset-baseline.rds'))
 entry<-list(kind='project',layer=12L,component='mlp_out',direction=d$value,coef=1)
 extra<-4*as.double(utils::object.size(record));val<-relm:::direction_validate(d,extra_bytes=extra)
 prep<-relm:::projection_prepare(m,entry,64*1024^2,val$estimate_bytes,direction_application=TRUE)
 exact<-prep$response$terms$total_bytes
 stopifnot(length(exact)==1L,is.finite(exact))
 saveRDS(prep[c('config','profile','response','workspace_bytes')],file.path(out,'public-budget.rds'))
 stopifnot(exact>=1024^2,exact<=64*1024^2,prep$response$inputs$production_armed==1)
 check('minus_one_refused',refuses(apply(m,d,record,max_bytes=exact-1),'relm_error_oom'),TRUE)
 p<-apply(m,d,record,max_bytes=exact);on.exit(close(p),add=TRUE)
 check('project_public_constructed',identical(p$interventions[[1L]]$kind,'project') && attr(p,'projection')$max_bytes==exact)
 changed_logits<-logits(p,prompt);saveRDS(changed_logits,file.path(out,'projected-logits.rds'))
 check('project_public_logits',is.data.frame(changed_logits) && nrow(changed_logits)==12L && !identical(changed_logits,original_logits))
 check('duplicate_refused',refuses(apply(p,d,record),'relm_error_intervention'),TRUE)
 check('trace_refused',refuses(llm_trace(p,'x',layers=12L),'relm_error_trace'),TRUE)
 check('embed_refused',refuses(llm_embed(p,'x'),'relm_error_embed'),TRUE)
 check('images_refused',refuses(run(p,'x',chat=FALSE,max_tokens=1L,images='/missing-no-open.png'),'relm_error_image'),TRUE)
 changed<-run(p,prompt,chat=FALSE,max_tokens=4L)
 check('static_sync_seeded_reset',identical(run(p,prompt,chat=FALSE,max_tokens=4L),changed))
 chat<-run(p,'Write the word red.',chat=TRUE,max_tokens=4L);saveRDS(chat,file.path(out,'public-chat.rds'))
 check('chat_text_route',is.character(chat) && length(chat)==1L && identical(attr(chat,'seed'),1047))
 schema<-'{"type":"object","properties":{"answer":{"type":"string","enum":["ok"]}},"required":["answer"],"additionalProperties":false}'
 structured<-run(p,'Return the object with answer ok.',chat=FALSE,max_tokens=32L,schema=schema)
 saveRDS(structured,file.path(out,'public-structured.rds'))
 check('structured_text_route',is.character(structured) && length(structured)==1L && identical(gsub('[[:space:]]','',as.character(structured)), '{"answer":"ok"}'))
 events<-list();obs<-observe(run(p,prompt,chat=FALSE,max_tokens=4L,async=TRUE,on_token=function(x){events[[length(events)+1L]]<<-x;NULL}))
 ev<-do.call(rbind,events);saveRDS(list(events=ev,value=obs$value,error=obs$error),file.path(out,'public-stream.rds'))
 check('async_stream_text_route',is.null(obs$error) && obs$settlements==1L && identical(obs$value,changed) && identical(paste0(ev$text[ev$event=='text'],collapse=''),as.character(changed)))
 first<-function(h,label){states<-list();o<-observe(run(h,prompt,chat=FALSE,max_tokens=1L,async=TRUE,layers=12L,components='mlp_out',top=3L,spill=FALSE,on_state=function(s){states[[length(states)+1L]]<<-s;NULL}));stopifnot(is.null(o$error),o$settlements==1L);saveRDS(list(states=states,value=o$value),file.path(out,paste0(label,'.rds')));stopifnot(length(states)==1L);states[[1L]]}
 a<-first(m,'live-original');check('live_original_state',nrow(a$step)==1L && a$step$state_id==1L)
 b<-first(p,'live-projected');check('live_projected_state',nrow(b$step)==1L && b$step$source_pos==a$step$source_pos && identical(attr(a$trace,'prompts'),attr(b$trace,'prompts')))
 av<-as.numeric(as.matrix(a$trace,12L,'mlp_out'));bv<-as.numeric(as.matrix(b$trace,12L,'mlp_out'));expected_v<-av-d$value*sum(d$value*av)
 write.csv(data.frame(neuron=seq_along(av),before=av,direction=d$value,after=bv,expected=expected_v),file.path(out,'public-projection-values.csv'),row.names=FALSE)
 check('public_same_row_projection',length(av)==896L && all(abs(bv-expected_v)<=2e-6*(1+abs(expected_v))))
 # Give the mixed handle its explicit independent application budget; it adds
 # a separately charged residual sentinel and cannot inherit the exact no-residual budget.
 roomy<-apply(m,d,record);on.exit(close(roomy),add=TRUE)
 mixed<-llm_steer(roomy,2L,rep(.01,896),coef=0);on.exit(close(mixed),add=TRUE);close(roomy)
 check('mixed_inheritance',identical(vapply(mixed$interventions,`[[`,character(1),'kind'),c('project','steer')))
 mixed_before<-run(mixed,prompt,chat=FALSE,max_tokens=4L);states<-list();tokens<-0L
 obs<-observe(run(mixed,prompt,chat=FALSE,max_tokens=6L,async=TRUE,layers=12L,components='mlp_out',top=3L,spill=FALSE,
  on_token=function(x){tokens<<-tokens+sum(x$event=='token');NULL},on_state=function(s){states[[length(states)+1L]]<<-s;if(length(states)==1L)return(list(steer=data.frame(intervention=2L,coef=.25)));if(length(states)==3L)llm_cancel(mixed);NULL}))
 saveRDS(list(states=states,error=obs$error,value=obs$value,tokens=tokens),file.path(out,'public-live-cancel.rds'))
 check('live_reply_applied',length(states)==3L && identical(vapply(states,function(x)x$step$steering_revision,integer(1)),c(0L,1L,1L)) && identical(vapply(states,function(x)attr(x,'steering')$intervention,integer(1)),rep(2L,3)) && identical(vapply(states,function(x)attr(x,'steering')$coef,double(1)),c(0,.25,.25)))
 check('live_cancel_before_token',inherits(obs$error,'relm_error_cancelled') && tokens==2L && obs$settlements==1L && is.null(relm:::.relm_async$job),TRUE)
 check('mixed_seeded_restore',identical(run(mixed,prompt,chat=FALSE,max_tokens=4L),mixed_before))
 check('original_seeded_reset',identical(run(m,prompt,chat=FALSE,max_tokens=4L),baseline) && identical(m$interventions,list()))
 close(p);close(m)
 check('child_survives_parent_close',identical(run(mixed,prompt,chat=FALSE,max_tokens=4L),mixed_before));close(mixed)
 check('cpu_closed',relm:::rebirth_handle_is_closed(m$ptr) && relm:::rebirth_handle_is_closed(p$ptr) && relm:::rebirth_handle_is_closed(mixed$ptr))
 metal<-load('metal');on.exit(close(metal),add=TRUE);check('metal_loaded',identical(metal$backend,'metal'))
 mz<-apply(metal,d,record,coef=0);on.exit(close(mz),add=TRUE);mp<-apply(metal,d,record);on.exit(close(mp),add=TRUE)
 check('metal_public_constructed',identical(mp$interventions[[1L]]$kind,'project') && identical(mp$backend,'metal'))
 mb<-run(metal,prompt,chat=FALSE,max_tokens=2L)
 check('metal_zero_identity',identical(run(mz,prompt,chat=FALSE,max_tokens=2L),mb));close(mz)
 mt<-run(mp,prompt,chat=FALSE,max_tokens=2L);saveRDS(mt,file.path(out,'public-metal.rds'))
 check('metal_active_text_route',is.character(mt) && length(mt)==1L && identical(attr(mt,'seed'),1047));close(mp)
 check('metal_original_reset',identical(run(metal,prompt,chat=FALSE,max_tokens=2L),mb));close(metal)
 check('metal_closed',relm:::rebirth_handle_is_closed(metal$ptr) && relm:::rebirth_handle_is_closed(mp$ptr))
 stopifnot(identical(rows$case,expected),nrow(rows)==27L,sum(rows$refusal)==6L)
 saveRDS(list(original=baseline,projected=changed,mixed=mixed_before,counts=count),file.path(out,'public-summary.rds'))
 cat('F6E_INSTALLED_PUBLIC_REMAINING cases=27 refusals=6 backend_handles=cpu,metal no_download=TRUE carried_parent_cases=10\n')
}
main()
