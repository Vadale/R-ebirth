# Actual compiled v2 native receipts, independently recomputed in R; no model.
repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_CONSTRUCTOR_RUN');stopifnot(nzchar(out))
for(f in c('conditions.R','direction-schema.R','live-state.R','projection-memory.R'))
 sys.source(file.path(repo,'rebirth/R',f),envir=.GlobalEnv)
x <- read.csv(file.path(out,'native-twins.csv'),stringsAsFactors=FALSE)
stopifnot(identical(names(x),c('case','section','field','value')),
 identical(unique(x$case),c('s0a0','s1a0','s0a1','s1a1')))
results <- list();at <- 0L
for(id in unique(x$case)) {
 part <- x[x$case==id,,drop=FALSE]
 extract <- function(section,fields) {
  z <- part[part$section==section,,drop=FALSE]
  stopifnot(identical(z$field,fields),all(is.finite(z$value)))
  setNames(as.list(as.double(z$value)),z$field)
 }
 p <- extract('profile',projection_profile_fields)
 i <- extract('inputs',projection_input_fields)
 native <- extract('terms',projection_term_fields)
 stopifnot(length(p)==27L,length(i)==15L,length(native)==14L,p$version==2)
 actual <- projection_memory_bound(p,i)
 stopifnot(identical(actual,native))
 exact <- i;exact$max_bytes <- actual$total_bytes
 stopifnot(identical(projection_memory_bound(p,exact),native))
 exact$max_bytes <- exact$max_bytes-1
 bad <- tryCatch(projection_memory_bound(p,exact),error=identity)
 stopifnot(inherits(bad,'relm_error_oom'))
 for(key in projection_term_fields) {
  at <- at+1L;results[[at]] <- data.frame(case=id,field=key,native=native[[key]],R=actual[[key]],difference=actual[[key]]-native[[key]])
 }
}
res <- do.call(rbind,results);stopifnot(nrow(res)==56L,all(res$difference==0))
write.csv(res,file.path(out,'r-native-parity.csv'),row.names=FALSE)
cat('F6E_CONSTRUCTOR_R_TWIN cases=4 compared_terms=56 exact_budgets=4 rejected_budget_minus_one=4 differences=0 models=0\n')
