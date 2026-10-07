stopifnot(Sys.getenv('RSTUDIO')=='1',!exists('.relm_f6c',.GlobalEnv,inherits=FALSE))
.relm_f6c <- local({
 a <- new.env(parent=globalenv());a$root<-'/private/tmp/relm-f6c/rstudio'
 a$pre<-list(globals=ls(.GlobalEnv,all.names=TRUE),seed=get0('.Random.seed',.GlobalEnv),
  library=.libPaths(),search=search(),options=options(),environment=Sys.getenv(),
  devices=dev.list(),wd=getwd(),pid=Sys.getpid(),namespaces=loadedNamespaces())
 a$original<-mget(a$pre$globals,envir=.GlobalEnv,inherits=FALSE)
 saveRDS(a$pre,file.path(a$root,'private-preflight.rds'))
 saveRDS(a$original,file.path(a$root,'private-workspace.rds'))
 stopifnot(!'relm'%in%loadedNamespaces())
 .libPaths(c('/private/tmp/relm-f6c/library',.libPaths()))
 stopifnot(requireNamespace('relm',quietly=TRUE),normalizePath(find.package('relm'))=='/private/tmp/relm-f6c/library/relm')
 a$data<-readRDS('/private/tmp/relm-f6c/package-resume-20261007-134046/model-graphics.rds')
 a$m<-relm::llm('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf',backend='cpu',context_length=512L)
 a$changed<-relm::llm_steer(a$m,2L,rep(0.1,a$m$hidden_size),coef=0.5)
 a$shown<-character()
 a$draw<-function(what) {
  returned<-switch(what,map=plot(a$changed,layers=c(1:4,12L,24L)),
   comparison=plot(a$data$comparison),timeline=plot(a$data$timeline))
  if(what!='map')stopifnot(identical(returned,a$data[[what]]))
  a$shown<-c(a$shown,what)
  saveRDS(list(pid=Sys.getpid(),shown=a$shown,package=find.package('relm'),device=names(dev.cur()),
   returned=returned),file.path(a$root,paste0(what,'.rds')))
  cat('F6C_RSTUDIO_PLOT',what,'\n')
  invisible(NULL)
 }
 a$restore<-function() {
  close(a$changed);close(a$m)
  .libPaths(a$pre$library)
  added<-setdiff(names(options()),names(a$pre$options))
  if(length(added))options(setNames(rep(list(NULL),length(added)),added))
  options(a$pre$options)
  if(is.null(a$pre$seed)) {if(exists('.Random.seed',.GlobalEnv,inherits=FALSE))rm('.Random.seed',envir=.GlobalEnv)} else assign('.Random.seed',a$pre$seed,.GlobalEnv)
  # Close only the graphics device created by this acceptance, if any.
  current<-dev.list();extra<-setdiff(unname(current),unname(a$pre$devices))
  for(d in extra)dev.off(d)
  globals<-setdiff(ls(.GlobalEnv,all.names=TRUE),c('.relm_f6c','.Last.value'))
  expected<-setdiff(a$pre$globals,'.Last.value')
  checks<-list(globals=identical(globals,expected),values=identical(mget(expected,.GlobalEnv,inherits=FALSE),a$original[expected]),
   rng=identical(get0('.Random.seed',.GlobalEnv),a$pre$seed),library=identical(.libPaths(),a$pre$library),
   search=identical(search(),a$pre$search),environment=identical(Sys.getenv(),a$pre$environment),
   wd=identical(getwd(),a$pre$wd),options=identical(options(),a$pre$options))
  saveRDS(list(checks=checks,shown=a$shown,pid=Sys.getpid()),file.path(a$root,'restoration.rds'))
  stopifnot(all(unlist(checks)),identical(a$shown,c('map','comparison','timeline')))
  rm('.relm_f6c',envir=.GlobalEnv)
  cat('F6C_RSTUDIO_RESTORED\n')
  invisible(NULL)
 }
 a
})
.relm_f6c$draw('map')
