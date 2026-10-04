root <- "/private/tmp/relm-f6b/rstudio"
s <- readRDS(file.path(root,"status.rds"))
r <- readRDS(file.path(root,"result.rds"))
fresh <- readRDS(file.path(root,"fresh-session.rds"))
restored <- readRDS(file.path(root,"user-restoration-verification.rds"))
e <- r$events
n <- s$states
k <- seq_len(n)
revision <- (k-1L)%/%16L
after <- revision*16L
p <- e$source_pos[[1L]]
stopifnot(identical(s$status,"passed"),nrow(e)==n,n==346L,s$tokens==n-1L,
 identical(e$state_id,k),identical(e$token_pos,k),all(e$prompt_id==1L),
 identical(e$steering_revision,revision),identical(e$applied_after_state,after),
 identical(e$effective_source_pos,ifelse(after==0L,1L,p+after)),
 identical(e$source_pos,p+k-1L),identical(e$context_pos,e$source_pos+1L),
 all(e$coef==ifelse(revision%%2L==0L,0,0.5)),length(unique(e$steering_revision))==22L,
 all(is.finite(e$score)),all(diff(e$elapsed)>=0),
 all(e$object_bytes<=r$estimate$materialized_bytes),
 r$duration_seconds>=6,s$heartbeats>=10L,r$reset,
 inherits(r$error,"relm_error_cancelled"),identical(r$error$reason,"requested"),
 r$error$generated_tokens==n,isTRUE(r$probe$was_running),isTRUE(r$probe$native_running),
 identical(r$probe$value,2),r$probe$elapsed<0.5,r$probe$states_delivered==n-1L,
 r$probe$applied_revision>=2L,identical(s$pid,fresh$pid),fresh$pid!=fresh$previous_pid,
 fresh$namespace_unloaded,identical(s$pid,r$probe$pid),identical(restored$pid,s$pid),
 all(unlist(restored[setdiff(names(restored),"pid")])))
csv <- read.csv(file.path(root,"states.csv"),check.names=FALSE)
stopifnot(isTRUE(all.equal(unname(as.matrix(csv)),unname(as.matrix(e)),check.attributes=FALSE,tolerance=1e-12)))
out<-list(status="independently_verified",date="2026-10-04",source_head="490c7f41a417110d0109be01ce74d8e213e1ee46",
 rstudio_pid=s$pid,previous_pid=fresh$previous_pid,package=s$package,package_version=as.character(s$version),
 duration_seconds=r$duration_seconds,submission_seconds=r$submission_seconds,states=n,tokens=s$tokens,
 coefficient_revisions=s$revisions,heartbeats=s$heartbeats,probe_elapsed_seconds=r$probe$elapsed,
 probe_clock_scope="Below R elapsed-clock resolution; not a claim of zero physical latency",
 probe_states=r$probe$states_delivered,probe_native_active=TRUE,cancelled_at_state=n,
 max_delivered_bytes=max(e$object_bytes),materialized_bound=r$estimate$materialized_bytes,
 reset=TRUE,workspace_restored=TRUE,seed_restored=TRUE,library_search_environment_restored=TRUE,
 ui_observation="CUA observed real foreground Console source, separate probe returning2, live plot, COMPLETE passed and WORKSPACE_RESTORED; editor pane remained untouched.")
jsonlite::write_json(out,file.path(root,"independent-verification.json"),pretty=TRUE,auto_unbox=TRUE,digits=16)
print(out)
