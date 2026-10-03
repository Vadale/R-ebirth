run <- "/private/tmp/relm-f6b/latency-20261003-213919"
x <- readRDS(file.path(run,"public-update-latency-receipts.rds"))
stopifnot(length(x)==16L)
for (r in x) {
 e <- r$events
 changed <- r$mode=="changing"
 k <- seq_len(128L)
 stopifnot(r$completed,is.null(r$error),r$states==128L,r$tokens==128L,nrow(e)==128L,
  identical(e$state_id,k),identical(e$revision,if(changed)k-1L else rep(0L,128L)),
  all(e$applied_coef == if(changed)ifelse(k%%2L==0L,0.5,0) else 0),
  all(e$requested_coef == if(changed)ifelse(k%%2L==1L,0.5,0) else 0),
  all(diff(e$source_pos)==1L),all(e$object_bytes<=128*1024),
  all(e$object_bytes<=r$estimate$materialized_bytes),
  all(is.finite(r$callback_to_next_state_seconds)),all(r$callback_to_next_state_seconds>=0),
  identical(r$callback_to_next_state_seconds,e$entered[-1L]-head(e$leaving,-1L)))
}
result<-list(status="passed",runs=length(x),states=sum(vapply(x,`[[`,integer(1),"states")),
  backends=unique(vapply(x,`[[`,character(1),"backend")),rounds=0:3,
  scope="Public R callback-to-next-state interval includes validation, ack, decode, transport and polling; reset guarded in producer; backend labels are requested handles, not fresh offload evidence.")
for(b in result$backends) {
 selected<-Filter(function(r)r$backend==b && r$round>0,x)
 med<-function(mode)median(unlist(lapply(Filter(function(r)r$mode==mode,selected),`[[`,"callback_to_next_state_seconds")))
 saved<-read.csv(file.path(run,paste0("public-update-latency-",b,".csv")))
 stopifnot(length(selected)==6L,abs(saved$unchanged_interval_seconds-med("unchanged"))<1e-12,
  abs(saved$changing_interval_seconds-med("changing"))<1e-12)
}
jsonlite::write_json(result,file.path(run,"independent-verification.json"),auto_unbox=TRUE,pretty=TRUE)
print(result)
