r <- '/private/tmp/relm-f6e/installed-review-resume-20261008-151830'
library(relm)
a <- readRDS(file.path(r,'baseline-live.rds')); b <- readRDS(file.path(r,'zero-live.rds'))
stopifnot(length(a$states)==2L,length(b$states)==2L,identical(a$value,b$value),identical(readRDS(file.path(r,'original-after-gc.rds')),a$value))
csv <- read.csv(file.path(r,'zero-live-coordinates.csv'))
err <- 0
for(i in 1:2){
 av <- as.numeric(as.matrix(a$states[[i]]$trace,12L,'mlp_out'))
 bv <- as.numeric(as.matrix(b$states[[i]]$trace,12L,'mlp_out'))
 c <- csv[csv$state==i,]
 stopifnot(length(av)==896L,identical(av,bv),all(is.finite(av)),identical(c$neuron,1:896),all(c$original==c$zero),
  max(abs(c$original-av))<1e-12,identical(a$states[[i]]$step[setdiff(names(a$states[[i]]$step),'elapsed')],b$states[[i]]$step[setdiff(names(b$states[[i]]$step),'elapsed')]),is.finite(a$states[[i]]$step$elapsed),is.finite(b$states[[i]]$step$elapsed),
  identical(attr(a$states[[i]]$trace,'prompts'),attr(b$states[[i]]$trace,'prompts')))
 err<-max(err,max(abs(c$original-av)))
}
stopifnot(identical(a$events$token_id[a$events$event=='token'],b$events$token_id[b$events$event=='token']))
profiles <- readRDS(file.path(r,'registry-profiles.rds'))
caps <- vapply(profiles,function(x)(x$ffi_registry_bytes-32)/16,numeric(1))
stopifnot(identical(unname(caps),c(2,rep(2,8),2:4,2)))
for(p in profiles)stopifnot(length(p)==27L,p$ffi_fixed_bytes==p$ffi_response_bytes+p$ffi_registry_bytes+160,p$derive_frame_bytes==11959,p$runtime_bytes==5072,p$ffi_command_bytes==744,p$ffi_response_bytes==1512,p$error_format_bytes==150)
counts<-readRDS(file.path(r,'attempts.rds'));stopifnot(identical(counts,list(load=1L,derive=13L,generate=3L,trace=0L,logits=0L,tokenize=0L)))
jsonlite::write_json(list(status='passed',observed_states=4L,bitwise_coordinate_pairs=1792L,CSV_roundtrip_max_abs=err,registry_profiles=length(profiles),capacities=unname(caps),attempts=counts,model_calls_during_verification=0L),file.path(r,'owner-observation-verification.json'),pretty=TRUE,auto_unbox=TRUE)
cat('F6E_INSTALLED_REVIEW_OWNER observations=4 coordinate_pairs=1792 registry_profiles=13 model_calls=0\n')
