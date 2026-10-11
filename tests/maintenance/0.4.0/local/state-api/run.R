args <- commandArgs(TRUE); dyn.load(args[[1L]])
create <- function(ptr) .Call('state_create',ptr)
facts <- function(e,p) .Call('state_facts',e,p)
count <- 0L
check <- function(name,x) {stopifnot(isTRUE(x));count<<-count+1L;cat('STATE_API_CASE',name,'\n')}
p <- .Call('fresh_pointer'); e <- create(p)
check('plain_fixed_names',identical(sort(ls(e,all.names=TRUE)),c('closed','ptr')) && environmentIsLocked(e))
check('unhashed_and_empty_parent',is.null(env.profile(e)) && identical(parent.env(e),emptyenv()))
check('actual_state_facts',identical(facts(e,p),c(0,2,.Machine$sizeof.pointer)))
check('duplicate_pointer_refused',is.null(create(p)))
check('non_pointer_refused',is.null(create(1L)))
check('cannot_add_name',inherits(tryCatch({e$x<-1;NULL},error=identity),'error'))
check('cannot_remove_name',inherits(tryCatch(rm('ptr',envir=e),error=identity),'error'))
e$closed<-TRUE;check('closed_value_mutable',identical(facts(e,p),c(0,2,.Machine$sizeof.pointer)));e$closed<-FALSE
for (value in list(NA,0L,structure(FALSE,x=1),logical(),c(FALSE,FALSE))) {
 e$closed<-value;check(paste0('invalid_closed_',count),is.null(facts(e,p)))
}
e$closed<-FALSE
for (binding in c('closed','ptr')) {
 delayedAssign(binding,stop('PROMISE MUST NOT RUN'),assign.env=e)
 check(paste0('unforced_',binding),is.null(facts(e,p)))
 if(binding=='ptr') e$ptr<-p else e$closed<-FALSE
}
e$ptr<-.Call('fresh_pointer');check('wrong_binding_pointer',is.null(facts(e,p)));e$ptr<-p
attr(e,'extra')<-1;check('state_attributes',is.null(facts(e,p)));attr(e,'extra')<-NULL
parent.env(e)<-globalenv();check('wrong_parent',is.null(facts(e,p)));parent.env(e)<-emptyenv()
for(hash in c(FALSE,TRUE)) {
 forged<-new.env(hash=hash,parent=emptyenv(),size=10007L);forged$ptr<-p;forged$closed<-FALSE;lockEnvironment(forged)
 check(paste0('forged_',hash),is.null(facts(forged,p)))
}
check('wrong_proof_pointer',is.null(facts(e,.Call('fresh_pointer'))))
finalized<-0L
reg.finalizer(e,function(x){finalized<<-finalized+1L;stopifnot(identical(x$ptr,p))},onexit=FALSE)
rm(e);gc();gc()
check('weak_proof_does_not_retain_state',is.null(.Call('state_key',p)) && finalized==1L)
# Force collection at every allocation only during this new factory test.
gctorture(TRUE)
p2<-.Call('fresh_pointer'); e2<-create(p2); actual<-facts(e2,p2)
gctorture(FALSE)
check('factory_gc_protection',identical(actual,c(0,2,.Machine$sizeof.pointer)))
check('conservative_frame',identical(.Call('state_size',NULL),128))
cat('STATE_API_OK cases=',count,' model_calls=0\n',sep='')
