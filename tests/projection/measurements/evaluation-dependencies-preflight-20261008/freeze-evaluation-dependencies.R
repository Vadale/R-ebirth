args <- commandArgs(TRUE); stopifnot(length(args)==1L)
stopifnot(requireNamespace('jsonlite', quietly=TRUE))
library(relm)
relm:::async_check_dependencies()
stopifnot(normalizePath(find.package('relm'))=='/private/tmp/relm-f6e/public-library-budget/relm')
packages <- sort(unique(c('later','promises','jsonlite',loadedNamespaces())))
result <- list()
for(p in packages) {
  d <- read.dcf(file.path(find.package(p),'DESCRIPTION'))
  priority <- if('Priority' %in% colnames(d)) d[1,'Priority'] else NA_character_
  if(p=='relm' || !is.na(priority)) next
  root <- normalizePath(find.package(p))
  files <- list.files(root,recursive=TRUE,full.names=TRUE,all.files=TRUE,no..=TRUE)
  files <- files[!dir.exists(files)]
  result[[length(result)+1L]] <- list(package=p,version=as.character(packageVersion(p)),path=root,
    files=as.list(setNames(unname(tools::sha256sum(files)),substring(files,nchar(root)+2L))))
}
jsonlite::write_json(result,args[[1L]],auto_unbox=TRUE,pretty=TRUE)
cat('F6E_DEPENDENCIES_FROZEN packages=',length(result),' models=0 inference=0\n',sep='')
