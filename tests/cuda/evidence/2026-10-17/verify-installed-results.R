# Saved observations only: never load relm or execute a model.
b <- '/tmp/relm-phase8/installed-pic'; w <- file.path(b, 'workflow')
rd <- function(n) readRDS(file.path(w, paste0(n, '.rds')))
settings <- rd('settings'); captures <- rd('construction'); directions <- rd('directions')
stopifnot(settings$backend == 'cuda', settings$seed == 1707L, settings$max_tokens == 32L,
  settings$temperature == 0, length(captures) == 4L)
errors <- numeric()
for (component in names(directions)) {
  rows <- lapply(captures, function(x) {
    stopifnot(nrow(x)==1792L, identical(sort(unique(x$component)),c('mlp_out','residual')),
      all(x$layer == 12L), length(unique(x$token_pos))==1L, all(is.finite(x$value)))
    y <- x[x$component==component, ];stopifnot(identical(y$neuron,seq_len(896L)));y$value
  })
  delta <- ((rows[[1L]]-rows[[2L]])+(rows[[3L]]-rows[[4L]]))/2
  expected <- delta/sqrt(sum(delta*delta))
  errors[[component]] <- max(abs(directions[[component]]$value-expected))
  stopifnot(errors[[component]] <= 1e-12)
  info <- attr(directions[[component]], 'direction')
  stopifnot(info$layer==12L, info$component==component, info$context$capture$backend=='cuda',
    identical(info$context$pairs$target_pos,vapply(captures[c(1,3)],function(x)unique(x$token_pos),integer(1))))
}
rows <- read.csv(file.path(w,'outputs.csv'),check.names=FALSE)
stopifnot(nrow(rows)==8L,all(!rows$reached_token_cap))
zero_values <- comparison_values <- states <- 0L
for (prompt in c('practice','evaluation')) {
  original <- rd(paste0(prompt,'-original'));zero <- rd(paste0(prompt,'-zero'))
  stopifnot(identical(original$text,zero$text), identical(original$sampled_ids,zero$sampled_ids),
    identical(original$first$trace,zero$first$trace),identical(original$first$logits,zero$first$logits))
  columns<-setdiff(names(original$first$step),'elapsed')
  stopifnot(identical(original$first$step[columns],zero$first$step[columns]))
  columns<-setdiff(names(original$timeline),'elapsed')
  # Data columns only: retained size estimates and other attributes remain in raw RDS.
  stopifnot(identical(unclass(original$timeline)[columns],unclass(zero$timeline)[columns]))
  zero_values<-zero_values+nrow(original$first$trace)
  projected<-rd(paste0(prompt,'-projection')); cmp<-rd(paste0(prompt,'-comparison'))
  stopifnot(nrow(cmp)==896L,identical(cmp$reference,original$first$trace$value),
    identical(cmp$intervention,projected$first$trace$value),
    identical(cmp$difference,cmp$intervention-cmp$reference),attr(cmp,'alignment')$matched,
    original$first$step$source_pos==projected$first$step$source_pos)
  comparison_values<-comparison_values+nrow(cmp)
  for(condition in c('original','zero','addition','projection')) {
    x<-rd(paste(prompt,condition,sep='-'));row<-rows[rows$prompt_id==prompt & rows$condition==condition,]
    stopifnot(length(x$text)==1L,attr(x$text,'seed')==1707,identical(x$sampled_ids,x$timeline$token_id),
      row$characters==nchar(x$text,type='chars'),row$text==unname(x$text),
      row$sampled_states==length(x$sampled_ids),length(x$sampled_ids)<=32L,
      all(x$timeline$steering_revision==0L),all(is.finite(x$first$trace$value)))
    states<-states+length(x$sampled_ids)
  }
}
checks <- read.csv(file.path(b,'boundary-tests.csv'))
stopifnot(nrow(checks)==12L,sum(checks$passed)==58L,sum(checks$skipped)==1L,
  all(checks$failed==0L),!any(checks$error))
result<-list(status='passed',construction_values=4L*1792L,direction_values=1792L,
  direction_max_abs_error=errors,zero_identity_values=zero_values,
  comparison_coordinates=comparison_values,successful_generations=8L,sampled_states=states,
  models_loaded_by_verifier=0L,scope='Operational CUDA workflow; not an efficacy or same-row native operator claim')
saveRDS(result,file.path(b,'owner-results.rds'));dput(result)
