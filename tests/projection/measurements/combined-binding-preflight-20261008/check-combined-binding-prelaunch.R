args <- commandArgs(trailingOnly=TRUE)
stopifnot(length(args)==2L)
repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'; out <- Sys.getenv('F6E_COMBINED_RUN')
stopifnot(nzchar(out), !'relm' %in% names(getLoadedDLLs()))
path <- normalizePath(args[[1L]],mustWork=TRUE); model <- normalizePath(args[[2L]],mustWork=TRUE)
dll <- dyn.load(path,local=TRUE,now=TRUE)
symbol <- function(name,n) {
 s <- getNativeSymbolInfo(name,PACKAGE=dll)
 stopifnot(identical(s$numParameters,as.integer(n)),identical(normalizePath(s$dll[['path']],mustWork=TRUE),path));s
}
e <- new.env(parent=globalenv())
for (f in c('conditions.R','direction-schema.R','live-state.R','llm.R','projection-memory.R','projection-owners.R','projection-binding.R')) sys.source(file.path(repo,'rebirth/R',f),envir=e)
profile_symbol <- symbol('wrap__rebirth_projection_allocation_profile',0L)
state_symbol <- symbol('wrap__rebirth_projection_state_facts',2L)
preflight_symbol <- symbol('wrap__rebirth_projection_preflight',2L)
construct_symbol <- symbol('wrap__rebirth_projection_construct',7L)
close_symbol <- symbol('wrap__rebirth_handle_close',1L)
closed_symbol <- symbol('wrap__rebirth_handle_is_closed',1L)
logit_symbol <- symbol('wrap__rebirth_logits',3L)
load_symbol <- symbol('wrap__rebirth_model_load',6L)
e$rebirth_projection_allocation_profile <- function() .Call(profile_symbol)
e$rebirth_projection_state_facts <- function(state,ptr) .Call(state_symbol,state,ptr)
e$rebirth_projection_preflight <- function(ptr,config) .Call(preflight_symbol,ptr,config)
construct_calls <- 0L; last_ptr <- NULL; close_calls <- 0L
e$rebirth_projection_construct <- function(ptr,config,sl,sv,al,an,av) {
 construct_calls <<- construct_calls+1L
 z <- .Call(construct_symbol,ptr,config,sl,sv,al,an,av)
 if(identical(z$ok,TRUE)) last_ptr <<- z$ptr
 z
}
e$rebirth_handle_close <- function(ptr) { close_calls <<- close_calls+1L;.Call(close_symbol,ptr) }
e$rebirth_handle_is_closed <- function(ptr) .Call(closed_symbol,ptr)
logits <- function(m) e$relm_check(.Call(logit_symbol,m$ptr,'a',48L))
close_m <- function(m) { e$rebirth_handle_close(m$ptr);m$state$closed<-TRUE;invisible(NULL) }
rows <- list()
check <- function(name,value) { stopifnot(isTRUE(value));rows[[length(rows)+1L]] <<- data.frame(case=name,status='passed',refusal=FALSE);invisible(NULL) }
refuse <- function(name,expr,cls) {
 err <- tryCatch({force(expr);NULL},error=identity)
 stopifnot(inherits(err,cls));rows[[length(rows)+1L]] <<- data.frame(case=name,status='passed',refusal=TRUE);invisible(err)
}
loaded <- e$relm_check(.Call(load_symbol,model,768L,0L,'cpu',TRUE,''))
m <- e$new_llm(loaded,model)
check('actual_model_shape',identical(m$hidden_size,32L)&&identical(m$layers,3L)&&identical(m$backend,'cpu'))
baseline <- logits(m)
entry <- list(kind='project',layer=2L,component='mlp_out',direction=c(0,1,rep(0,30)),coef=.5)
# Deliberately large *real scalar metadata*, not a fictional reserve: raises the
# exact materialization budget above the approved public one-MiB lower bound.
wide <- m;wide$.description<-strrep('x',600000L)
prepared <- e$projection_prepare(wide,entry,64*2^20,0)
exact <- prepared$response$terms$total_bytes
check('actual_budget_above_public_minimum',exact>2^20 && exact<64*2^20)
check('combined_R_charge',identical(prepared$config$r_projection_fixed_bytes,prepared$inventory$r_projection_fixed_bytes+prepared$workspace_bytes))
check('all_native_R_terms',identical(prepared$response$terms,e$projection_memory_bound(prepared$profile,prepared$response$inputs)))
refuse('combined_budget_minus_one',e$projection_derive(wide,entry,exact-1,0),'relm_error_intervention')
check('minus_one_before_constructor',construct_calls==0L)
check('source_unchanged_after_refusal',identical(logits(m),baseline))
big <- e$projection_derive(wide,entry,exact,0)
check('combined_exact_budget_constructed',construct_calls==1L&&!e$rebirth_handle_is_closed(big$ptr))
check('actual_candidate_metadata',identical(big$.description,wide$.description)&&!identical(big$state,wide$state))
facts <- e$rebirth_projection_state_facts(big$state,big$ptr)
check('actual_unhashed_candidate_state',identical(facts,list(hash_slots=0,bindings=2,c_finalizer_bytes=8)))
flat <- e$projection_flatten(wide$interventions,entry,wide$hidden_size,prepared$inventory$counts)
actual_R <- as.double(object.size(wide))+as.double(object.size(big))+prepared$inventory$state_extra_bytes+as.double(object.size(flat))
R_bound <- prepared$response$terms$r_projection_bytes+prepared$response$terms$r_adapter_bytes
check('actual_R_materialization_within_bound',actual_R<=R_bound)
check('five_array_bytes',identical(as.double(object.size(flat)),e$projection_flat_bytes(prepared$inventory$counts,wide$hidden_size)))
close_m(big)
check('exact_candidate_closed',e$rebirth_handle_is_closed(big$ptr))
p <- e$projection_derive(m,entry,64*2^20,0)
check('projected_handle_configured',identical(p$interventions,list(entry)))
calls_before<-construct_calls
refuse('duplicate_site_before_transfer',e$projection_derive(p,entry,64*2^20,0),'relm_error_intervention')
check('duplicate_never_constructed',construct_calls==calls_before)
sentry <- list(kind='steer',layer=2L,direction=rep(.125,32),coef=.5,positions='all')
sp <- e$projection_prepare(p,sentry,64*2^20,0)
s <- e$projection_derive(p,sentry,64*2^20,0)
check('steering_inherits_static_projection',identical(s$interventions,list(entry,sentry))&&sp$config$mode=='inherit')
check('new_residual_probe_charged',sp$response$terms$residual_probe_bytes==8*32*3+4*32+sp$profile$residual_probe_fixed_bytes)
aentry <- list(kind='ablate',layer=2L,neurons=c(1L,3L),value=-.25,component='residual')
ap <- e$projection_prepare(s,aentry,64*2^20,0)
a <- e$projection_derive(s,aentry,64*2^20,0)
check('mixed_accumulated_entries',identical(a$interventions,list(entry,sentry,aentry))&&ap$config$steer_entries==1&&ap$config$ablate_entries==2)
af <- e$projection_flatten(s$interventions,aentry,32L,ap$inventory$counts)
check('mixed_five_arrays_measured',identical(as.double(object.size(af)),e$projection_flat_bytes(ap$inventory$counts,32L)))
active <- logits(a);close_m(p);close_m(s)
check('descendant_survives_parent_close',identical(logits(a),active))
refuse('closed_source_refused',e$projection_derive(s,aentry,64*2^20,0),'relm_error_closed')
# Force a new failure after a genuine handle transfer; the test-only pointer
# reference records cleanup and is not part of the package constructor payload.
original_builder<-e$projection_new_llm; e$projection_new_llm<-function(...) stop('forced R wrapping failure')
before_close<-close_calls
refuse('delivered_handle_R_failure',e$projection_derive(m,entry,64*2^20,0),'simpleError')
e$projection_new_llm<-original_builder
check('delivered_native_owner_closed',close_calls==before_close+1L&&e$rebirth_handle_is_closed(last_ptr))
check('original_reset_exact',identical(logits(m),baseline))
close_m(a);close_m(a)
check('derived_close_idempotent',e$rebirth_handle_is_closed(a$ptr))
close_m(m)
check('original_closed',e$rebirth_handle_is_closed(m$ptr))
result<-do.call(rbind,rows);write.csv(result,file.path(out,'combined-cases.csv'),row.names=FALSE)
stopifnot(nrow(result)==27L,sum(result$refusal)==4L,construct_calls==6L)
# Preserve arithmetic, actual materialization and model input without pointers.
receipts<-list(exact=prepared,steer=sp,mixed=ap)
for(name in names(receipts)) {
 r<-receipts[[name]]
 table<-do.call(rbind,lapply(c('profile','inputs','terms'),function(section) {
  value<-r$response[[section]];data.frame(case=name,section=section,field=names(value),value=unlist(value,use.names=FALSE))
 }))
 write.csv(table,file.path(out,paste0('combined-',name,'-terms.csv')),row.names=FALSE)
}
write.csv(data.frame(exact_budget=exact,actual_R_bytes=actual_R,R_bound_bytes=R_bound,
 workspace_bytes=prepared$workspace_bytes,model_skeleton_bytes=prepared$inventory$model_skeleton_bytes,
 state_extra_bytes=prepared$inventory$state_extra_bytes,flat_bytes=as.double(object.size(flat)),
 mixed_flat_bytes=as.double(object.size(af)),construct_calls=construct_calls,model_loads=1L),
 file.path(out,'combined-materialization.csv'),row.names=FALSE)
cat('F6E_COMBINED_R_BINDING cases=27 refusals=4 constructor_calls=6 model_loads=1 source_reset=TRUE closed=TRUE\n')
