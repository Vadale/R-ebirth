# New graphics acceptance on a real configured owner; no generation or capture.
args <- commandArgs(TRUE); stopifnot(length(args)==2L)
input <- normalizePath(args[[1L]]); output <- normalizePath(args[[2L]])
cfg <- jsonlite::read_json(file.path(input,'config.json'))
library(relm)
stopifnot(normalizePath(find.package('relm'))==cfg$library,
  unname(tools::sha256sum(getLoadedDLLs()[['relm']][['path']]))==cfg$dll_sha256)
expected <- c('actual_original_metadata','actual_projection_configuration',
  'print_and_summary','png_table_and_par','pdf_table_and_par',
  'closed_map_refused','owners_closed')
rows <- data.frame(case=character(),refusal=logical())
check <- function(name, ok, refusal=FALSE) {
  stopifnot(identical(name,expected[[nrow(rows)+1L]]),isTRUE(ok))
  rows[nrow(rows)+1L,] <<- list(name,refusal)
  write.csv(rows,file.path(output,'cases.csv'),row.names=FALSE)
  cat('F6E_MODEL_MAP_CASE ',name,' refusal=',refusal,'\n',sep='');flush.console()
}
main <- function() {
  relm:::rebirth_available_backends()
  shim <- dyn.load(cfg$logger)
  stopifnot(.C('f6e_log_start',getLoadedDLLs()[['relm']][['path']],
    file.path(output,'native-placement.log'),status=integer(1),PACKAGE=shim[['name']])$status==0L)
  on.exit(stopifnot(.C('f6e_log_stop',status=integer(1),PACKAGE=shim[['name']])$status==0L),add=TRUE)
  count <- list(load=1L,derive=0L,generate=0L,logits=0L,trace=0L,tokenize=0L)
  saveRDS(count,file.path(output,'attempts.rds'))
  m <- llm(cfg$model,backend='cpu',context_length=512L)
  on.exit(close(m),add=TRUE,after=FALSE)
  check('actual_original_metadata',m$hidden_size==896L && m$layers==24L &&
    identical(m$architecture,'qwen2') && identical(m$interventions,list()))
  d <- readRDS(file.path(input,'artifacts','mlp.rds'))
  record <- list(sha256=cfg$model_sha256,architecture=m$architecture,
    quantization=m$quantization,hidden_size=as.integer(m$hidden_size),
    layers=as.integer(m$layers),engine_revision='b10828-patched-D039-D040')
  count$derive <- 1L;saveRDS(count,file.path(output,'attempts.rds'))
  p <- llm_apply_direction(m,d,record,coef=1,operator='project')
  on.exit(close(p),add=TRUE,after=FALSE)
  check('actual_projection_configuration',length(p$interventions)==1L &&
    identical(p$interventions[[1L]]$kind,'project') &&
    identical(p$interventions[[1L]]$component,'mlp_out') && p$interventions[[1L]]$layer==12L)
  summary <- summary(p); text <- c(capture.output(print(p)),capture.output(print(summary)))
  writeLines(text,file.path(output,'handle-summary.txt'))
  saveRDS(list(model=record,interventions=summary$interventions),file.path(output,'configured-metadata.rds'))
  check('print_and_summary',identical(summary$interventions,p$interventions) &&
    sum(grepl('project',text,fixed=TRUE))==2L && sum(grepl('mlp_out',text,fixed=TRUE))==2L)
  tables <- list()
  for (kind in c('png','pdf')) {
    file <- file.path(output,paste0('configured-model-map.',kind))
    if(kind=='png') grDevices::png(file,width=1650,height=1200,res=150) else grDevices::pdf(file,width=11,height=8)
    before <- par(no.readonly=TRUE)
    tab <- tryCatch(plot(p,layers=c(1L,12L,24L),main='Actual configured handle | static MLP projection, coefficient 1'),
      finally={ after <- par(no.readonly=TRUE);grDevices::dev.off() })
    check(paste0(kind,'_table_and_par'),identical(before,after) &&
      identical(names(tab),c('layer','site','detail','configured_steers','configured_ablations','configured_projections')) &&
      nrow(tab)==9L && identical(tab$layer,rep(c(1L,12L,24L),each=3L)) &&
      identical(tab$site,rep(c('attn_out','mlp_out','residual'),3L)) &&
      identical(tab$configured_projections,c(0L,0L,0L,0L,1L,0L,0L,0L,0L)) &&
      identical(tab$configured_steers,integer(9L)) && identical(tab$configured_ablations,integer(9L)))
    tables[[kind]] <- tab
  }
  stopifnot(identical(tables$png,tables$pdf));saveRDS(tables$png,file.path(output,'sites.rds'))
  write.csv(tables$png,file.path(output,'sites.csv'),row.names=FALSE)
  close(p)
  e <- tryCatch(plot(p,layers=12L),error=identity)
  saveRDS(list(class=class(e),message=conditionMessage(e)),file.path(output,'closed-error.rds'))
  check('closed_map_refused',inherits(e,'relm_error_closed'),TRUE)
  close(m)
  check('owners_closed',relm:::rebirth_handle_is_closed(m$ptr) && relm:::rebirth_handle_is_closed(p$ptr))
  stopifnot(identical(rows$case,expected),nrow(rows)==7L,sum(rows$refusal)==1L)
  jsonlite::write_json(list(status='awaiting_visual_verification',cases=7L,refusals=1L,
    attempts=count,rows=9L,projections=1L,configured_site='layer12/mlp_out',
    scope='Actual configured handle metadata and graphics; no new inference or efficacy evidence'),
    file.path(output,'receipt.json'),auto_unbox=TRUE,pretty=TRUE)
  cat('F6E_MODEL_MAP_COMPLETE cases=7 refusals=1 load_attempts=1 derive_attempts=1 generation_attempts=0\n')
}
main()
