args <- commandArgs(TRUE); stopifnot(length(args)==2L)
root <- args[[1L]]; output <- args[[2L]]
rows <- read.csv(file.path(root,'construction.csv'), stringsAsFactors=FALSE)
prompts <- read.csv('tests/projection/evaluation/prompts.csv', stringsAsFactors=FALSE)
p <- prompts[prompts$split=='construction',]
stopifnot(nrow(rows)==24L, identical(rows$item_id,p$item_id), identical(rows$role,p$role),
  identical(rows$prompt_sha256,p$prompt_sha256))
inputs <- lapply(c('residual','mlp','random_mlp'),function(k) readRDS(file.path(root,'artifacts',paste0(k,'-inputs.rds'))))
names(inputs) <- c('residual','mlp','random_mlp')
count <- 0L
for(i in seq_len(24L)) {
  t <- readRDS(file.path(root,rows$capture_file[i]))
  stopifnot(nrow(t)==1792L, all(t$layer==12L), all(t$token_pos==rows$source_pos[i]),
    all(is.finite(t$value)))
  for(k in c('residual','mlp')) {
    z <- t[t$component==if(k=='mlp') 'mlp_out' else 'residual',]
    a <- inputs[[k]][[rows$role[i]]][rows$item_id[i],]
    stopifnot(identical(z$neuron,seq_len(896L)), identical(unname(a),z$value))
    count <- count+length(a)
  }
}
signs <- read.csv(file.path(root,'random-signs.csv'))$sign
stopifnot(identical(signs,c(1L,-1L,-1L,-1L,1L,-1L,1L,-1L,1L,-1L,1L,1L)))
for(i in seq_len(12L)) for(side in c('target','control')) {
  other <- if(signs[i]==1L) side else if(side=='target') 'control' else 'target'
  stopifnot(identical(inputs$random_mlp[[side]][i,],inputs$mlp[[other]][i,]))
  for(field in c('sha256','pos')) stopifnot(identical(inputs$random_mlp$context$pairs[i,paste0(side,'_',field)],
    inputs$mlp$context$pairs[i,paste0(other,'_',field)]))
}
errors <- list()
for(k in names(inputs)) {
  a <- readRDS(file.path(root,'artifacts',paste0(k,'.rds')))
  v <- colMeans(inputs[[k]]$target-inputs[[k]]$control); v <- v/sqrt(sum(v*v))
  stopifnot(length(a$value)==896L, all(abs(a$value-v)<=1e-12*(1+abs(v))))
  errors[[k]] <- max(abs(a$value-v))
}
jsonlite::write_json(list(status='PASS', captures=24L, capture_matrix_values=count,
  randomized_rows=12L, direction_values=2688L, maximum_absolute_errors=errors,
  models=0, inference=0, scope='Independent retained RDS, matrix provenance, pair swaps and base-R arithmetic'),
  output, auto_unbox=TRUE,pretty=TRUE,digits=NA)
cat('F6E_CONSTRUCTION_OWNER captures=24 capture_matrix_values=',count,' direction_values=2688 models=0 inference=0\n',sep='')
