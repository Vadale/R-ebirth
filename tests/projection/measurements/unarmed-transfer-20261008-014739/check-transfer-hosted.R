args <- commandArgs(trailingOnly = TRUE); stopifnot(length(args)==1L)
path <- normalizePath(args[[1L]],mustWork=TRUE)
stopifnot(!'relm' %in% names(getLoadedDLLs()))
dll <- dyn.load(path,local=TRUE,now=TRUE)
symbol <- function(name,n) {
  s <- getNativeSymbolInfo(name,PACKAGE=dll)
  stopifnot(identical(s$numParameters,as.integer(n)),identical(normalizePath(s$dll[['path']],mustWork=TRUE),path))
  s
}
result <- .Call(symbol('wrap__rebirth_selftest_projection_transfer',0L))
stopifnot(identical(result,list(ok=TRUE)))
cat('F6E_TRANSFER_R_HOSTED_SUCCESS outcomes=3 cases=42 rejections=31 models=0\n')
repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_TRANSFER_RUN'); stopifnot(nzchar(out))
for (f in c('conditions.R','direction-schema.R','live-state.R','projection-memory.R','projection-owners.R'))
  sys.source(file.path(repo,'rebirth/R',f),.GlobalEnv)
profile <- .Call(symbol('wrap__rebirth_projection_allocation_profile',0L))
projection_profile_validate(profile)
write.csv(data.frame(field=names(profile),value=vapply(profile,function(x)formatC(x,format='f',digits=0),character(1))),file.path(out,'actual-profile.csv'),row.names=FALSE)
defs <- as.list(parse(file.path(repo,'rebirth/tests/testthat/test-projection-owners.R')))
for (x in defs) if (is.call(x) && identical(x[[1]],as.name('<-')) &&
    as.character(x[[2]]) %in% c('projection_owner_model','projection_owner_entry')) eval(x)
defs <- as.list(parse(file.path(repo,'rebirth/R/llm.R')))
for (x in defs) if (is.call(x) && identical(x[[1]],as.name('<-')) && identical(x[[2]],as.name('finalize_llm_state'))) eval(x)
newptr <- symbol('wrap__rebirth_selftest_new_handle',0L)
query <- symbol('wrap__rebirth_projection_state_facts',2L)
closeptr <- symbol('wrap__rebirth_handle_close',1L)
rebirth_handle_close <- function(ptr) .Call(closeptr,ptr)
rows <- list()
for (hashed in c(FALSE,TRUE)) {
  m <- projection_owner_model()
  m$ptr <- .Call(newptr)
  m$state <- new.env(hash=hashed,parent=emptyenv())
  m$state$ptr <- m$ptr; m$state$closed <- TRUE
  facts <- .Call(query,m$state,m$ptr)
  stopifnot(identical(names(facts),c('hash_slots','bindings','c_finalizer_bytes')),
    facts$hash_slots==if(hashed)29 else 0,facts$bindings==2,facts$c_finalizer_bytes==8)
  entry <- projection_owner_entry()
  inventory <- projection_owner_inventory(m,entry,facts,profile,64*2^20,2^20)
  candidate <- projection_new_llm(m,.Call(newptr),entry,64*2^20,2^20)
  actual <- .Call(query,candidate$state,candidate$ptr)
  stopifnot(identical(actual,list(hash_slots=0,bindings=2,c_finalizer_bytes=8)))
  stopifnot(inventory$state_extra_bytes==if(hashed)1272 else 992)
  before <- candidate$state
  finalize_llm_state(before)
  stopifnot(identical(before$closed,TRUE),identical(m$state$closed,TRUE),!identical(before,m$state))
  again <- .Call(query,before,candidate$ptr)
  stopifnot(identical(again,actual))
  rows[[length(rows)+1L]] <- data.frame(hashed=hashed,hash_slots=facts$hash_slots,
    state_extra_bytes=inventory$state_extra_bytes,r_projection_fixed_bytes=inventory$r_projection_fixed_bytes,
    r_adapter_bytes=inventory$r_adapter_bytes,query_roundtrip=TRUE,close_state=TRUE,models=0L)
}
write.csv(do.call(rbind,rows),file.path(out,'r-state-binding.csv'),row.names=FALSE)
invisible(gc())
cat('F6E_TRANSFER_R_BINDING states=2 candidate_queries=2 close_checks=2 models=0 armed=FALSE\n')
