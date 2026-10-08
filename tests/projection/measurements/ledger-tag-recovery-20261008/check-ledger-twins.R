# Independent R recomputation of actual compiled native receipts; no DLL/model.
repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_LEDGER_RUN'); stopifnot(nzchar(out))
for(f in c('conditions.R','direction-schema.R','live-state.R','projection-memory.R'))
 sys.source(file.path(repo,'rebirth/R',f),envir=.GlobalEnv)
x <- read.csv(file.path(out,'native-twins.csv'),stringsAsFactors=FALSE)
stopifnot(identical(names(x),c('case','section','field','value')),length(unique(x$case))==12L)
results <- list(); at <- 0L
for (id in unique(x$case)) {
 part <- x[x$case==id,,drop=FALSE]
 extract <- function(section,fields) {
  z <- part[part$section==section,,drop=FALSE]
  stopifnot(identical(z$field,fields),all(is.finite(z$value)))
  setNames(as.list(as.double(z$value)),z$field)
 }
 p <- extract('profile',projection_profile_fields)
 i <- extract('inputs',projection_input_fields)
 native <- extract('terms',projection_term_fields)
 actual <- projection_memory_bound(p,i)
 stopifnot(identical(actual,native))
 exact <- i; exact$max_bytes <- actual$total_bytes
 stopifnot(identical(projection_memory_bound(p,exact),native))
 low <- exact; low$max_bytes <- low$max_bytes-1
 bad <- tryCatch(projection_memory_bound(p,low),error=identity)
 stopifnot(inherits(bad,'relm_error_oom'))
 for (key in projection_term_fields) {
  at <- at+1L;results[[at]] <- data.frame(case=id,field=key,native=native[[key]],R=actual[[key]],difference=actual[[key]]-native[[key]])
 }
 fixed <- projection_transport_bytes(p)
 stopifnot(fixed$tags==2*live_r_vector_bytes(8)+live_r_vector_bytes(p$ffi_handle_tag_bytes+1))
}
res <- do.call(rbind,results)
stopifnot(nrow(res)==156L,all(res$difference==0))
write.csv(res,file.path(out,'r-native-parity.csv'),row.names=FALSE)
saveRDS(list(profile=p,fingerprint=projection_r_fingerprint(),transport=fixed),file.path(out,'r-allocation-prototype.rds'))
cat('F6E_LEDGER_R_TWIN cases=12 compared_terms=156 exact_budgets=12 rejected_budget_minus_one=12 differences=0 models=0\n')
