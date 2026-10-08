out <- commandArgs(TRUE)[[1L]]
z <- readRDS(file.path(out,'sites.rds'))
meta <- readRDS(file.path(out,'configured-metadata.rds'))
counts <- readRDS(file.path(out,'attempts.rds'))
err <- readRDS(file.path(out,'closed-error.rds'))
stopifnot(identical(counts,list(load=1L,derive=1L,generate=0L,logits=0L,trace=0L,tokenize=0L)),
  identical(class(z),'data.frame'),nrow(z)==9L,ncol(z)==6L,
  identical(z$layer,rep(c(1L,12L,24L),each=3L)),
  identical(z$site,rep(c('attn_out','mlp_out','residual'),3L)),
  identical(z$configured_projections,c(0L,0L,0L,0L,1L,0L,0L,0L,0L)),
  identical(z$configured_steers,integer(9L)),identical(z$configured_ablations,integer(9L)),
  identical(meta$model$architecture,'qwen2'),meta$model$hidden_size==896L,meta$model$layers==24L,
  length(meta$interventions)==1L,identical(meta$interventions[[1L]]$kind,'project'),
  identical(meta$interventions[[1L]]$layer,12L),identical(meta$interventions[[1L]]$component,'mlp_out'),
  identical(meta$interventions[[1L]]$coef,1),'relm_error_closed' %in% err$class)
csv <- read.csv(file.path(out,'sites.csv'))
stopifnot(identical(names(csv),names(z)),all(vapply(seq_along(z),function(i) identical(csv[[i]],z[[i]]),logical(1))))
cat('F6E_MODEL_MAP_OWNER rows=9 columns=6 configured_projection=layer12/mlp_out load_attempts=1 derive_attempts=1 generation_attempts=0 PASS\n')
