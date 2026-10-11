p <- '/private/tmp/relm-phase7/walkthrough-output'
read <- function(x) readRDS(file.path(p,x))
files <- read.csv(file.path(p,'files.csv'))
stopifnot(identical(unname(tools::sha256sum(file.path(p,files$file))),files$sha256))
rows <- read.csv(file.path(p,'outputs.csv'),stringsAsFactors=FALSE)
stopifnot(nrow(rows)==8L,all(rows$sampled_states<=32L),sum(rows$reached_token_cap)==4L)
captures <- read('construction.rds');directions <- read('directions.rds')
stopifnot(length(captures)==4L,all(vapply(captures,nrow,integer(1))==1792L))
errors <- vapply(names(directions),function(component) {
  v <- lapply(captures,function(x) x$value[x$component==component])
  mean_difference <- ((v[[1]]-v[[2]])+(v[[3]]-v[[4]]))/2
  expected <- mean_difference/sqrt(sum(mean_difference^2))
  max(abs(expected-directions[[component]]$value))
},numeric(1))
stopifnot(all(errors < 1e-12))
for (prompt in c('practice','evaluation')) {
  original <- read(paste0(prompt,'-original.rds'));zero <- read(paste0(prompt,'-zero.rds'))
  intervention <- read(paste0(prompt,'-projection.rds'))
  compared <- read(paste0(prompt,'-comparison.rds'))
  stopifnot(identical(original$text,zero$text),identical(original$sampled_ids,zero$sampled_ids),
    identical(compared$reference,original$first$trace$value),
    identical(compared$intervention,intervention$first$trace$value),
    identical(compared$difference,compared$intervention-compared$reference),nrow(compared)==896L)
  for (condition in c('original','zero','addition','projection')) {
    x <- read(paste0(prompt,'-',condition,'.rds'))
    stopifnot(length(x$sampled_ids)<=32L)
    r <- rows[rows$prompt_id==prompt & rows$condition==condition,]
    stopifnot(identical(r$text,unname(x$text[[1L]])),r$characters==nchar(x$text[[1L]],type='chars'),
      r$sampled_states==length(x$sampled_ids))
  }
}
cat('OWNER_RESULT_OK: 8 outputs, 4 captures/7168 values, 2 directions/1792 values, 2 zero identities, 1792 exact comparison differences\n')
cat('Direction maximum independent errors:',format(errors,digits=16),'\n')
cat('No model loads, inference, RNG generation or plotting in this inspection.\n')
