args <- commandArgs(TRUE); stopifnot(length(args)==2L)
input <- args[[1]]; output <- args[[2]]
for (i in 1:2) {
  a <- readRDS(file.path(input,'states',paste0('v001-',i,'.rds')))
  b <- readRDS(file.path(input,'states',paste0('v002-',i,'.rds')))
  z <- readRDS(file.path(output,paste0('comparison-',i,'.rds')))
  stopifnot(nrow(z)==896L, identical(z$reference,a$trace$value),
    identical(z$intervention,b$trace$value), identical(z$difference,b$trace$value-a$trace$value),
    isTRUE(attr(z,'alignment')$matched))
  csv <- read.csv(file.path(output,paste0('comparison-',i,'.csv')))
  stopifnot(identical(names(csv),names(z)),all(abs(csv$difference-z$difference)<1e-14))
}
for (j in 1:2) {
  z <- readRDS(file.path(output,paste0('timeline-',j,'.rds')))
  s <- lapply(1:2,function(i) readRDS(file.path(input,'states',paste0('v00',j,'-',i,'.rds'))))
  stopifnot(nrow(z)==2L,identical(z$state_id,1:2),all(z$steering_revision==0L),
    all(is.na(z$coef)),identical(z$token_id,vapply(s,function(x) x$step$token_id,integer(1))))
}
cat('F6E_RENDER_OWNER coordinates=1792 timeline_states=4 models=0 inference=0 PASS\n')
