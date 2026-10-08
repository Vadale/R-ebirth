# Fresh exact default DLL; initialized main-thread R, zero model loads.
args<-commandArgs(TRUE);stopifnot(length(args)==2L)
dll<-dyn.load(normalizePath(args[[1]]));out<-args[[2]]
sym<-getNativeSymbolInfo('wrap__rebirth_selftest_projection_budget_error',dll)
stopifnot(sym$numParameters==0L,identical(normalizePath(sym$dll[['path']]),normalizePath(args[[1]])))
x<-.Call(sym$address)
stopifnot(identical(names(x),c('ok','oom','malformed','overflow','profile','inputs','terms','error_response_bytes')),identical(x$ok,TRUE))
saveRDS(x,file.path(out,'budget-class-payload.rds'))
repo<-'/Users/alessandrovadala/DOCUDESK/R-ebirth';env<-new.env(parent=globalenv())
for(f in c('conditions.R','direction-schema.R','direction-arithmetic.R','direction-encoding.R','direction-validation.R','directions.R','live-state.R','projection-memory.R'))sys.source(file.path(repo,'rebirth/R',f),env)
p<-env$projection_profile_validate(x$profile);i<-x$inputs
stopifnot(length(p)==27L,length(i)==15L,length(x$terms)==14L,i$production_armed==1)
stopifnot(identical(names(x$oom),c('ok','class','message','fields')),identical(x$oom$ok,FALSE),identical(x$oom$class,'relm_error_oom'),identical(names(x$oom$fields),c('estimate_bytes','budget_bytes')),
 identical(x$oom$message,'Projection owners and working copies exceed max_bytes. Reduce projection sites or increase max_bytes.'),
 identical(x$oom$fields$estimate_bytes,x$terms$total_bytes),identical(x$oom$fields$budget_bytes,i$max_bytes),i$max_bytes==x$terms$total_bytes-1)
stopifnot(identical(x$malformed$class,'relm_error_intervention'),identical(x$overflow$class,'relm_error_intervention'),identical(names(x$malformed$fields),'reason'),identical(names(x$overflow$fields),'reason'))
failure<-tryCatch(env$projection_memory_bound(p,i),error=identity)
stopifnot(inherits(failure,'relm_error_oom'))
i$max_bytes<-x$terms$total_bytes
terms<-env$projection_memory_bound(p,i);stopifnot(identical(terms,x$terms))
f<-env$projection_transport_bytes(p);sizes<-vapply(x[c('oom','malformed','overflow')],function(z)as.double(utils::object.size(z)),double(1))
stopifnot(all(sizes<=f$failure),x$error_response_bytes<=p$ffi_response_bytes,p$ffi_response_bytes==1512,p$error_format_bytes==150)
write.csv(data.frame(field=names(p),value=unlist(p,use.names=FALSE)),file.path(out,'budget-profile.csv'),row.names=FALSE)
write.csv(data.frame(field=names(x$inputs),value=unlist(x$inputs,use.names=FALSE)),file.path(out,'budget-inputs.csv'),row.names=FALSE)
write.csv(data.frame(field=names(terms),native=unlist(x$terms,use.names=FALSE),R=unlist(terms,use.names=FALSE)),file.path(out,'budget-terms.csv'),row.names=FALSE)
write.csv(data.frame(payload=names(sizes),actual=unname(sizes),charged=f$failure),file.path(out,'budget-errors.csv'),row.names=FALSE)
write.csv(data.frame(field=names(f),value=unlist(f,use.names=FALSE)),file.path(out,'budget-transport.csv'),row.names=FALSE)
cat('F6E_BUDGET_R_TWIN terms=14 exact_budget=1 minus_one_oom=1 payloads=3 models=0 inference=0\n')
rm(x);invisible(gc())
cat('F6E_BUDGET_R_HOSTED_SUCCESS cases=8 refusals=3 models=0 inference=0\n')
