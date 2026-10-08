args <- commandArgs(trailingOnly=TRUE)
stopifnot(length(args)==3L,args[[2L]] %in% c("default","private"))
path <- normalizePath(args[[1L]],mustWork=TRUE)
stopifnot(!"relm" %in% names(getLoadedDLLs()))
dll <- dyn.load(path,local=TRUE,now=TRUE)
s <- getNativeSymbolInfo("wrap__rebirth_selftest_projection_combined_logits",PACKAGE=dll)
stopifnot(identical(s$numParameters,1L),identical(normalizePath(s$dll[["path"]],mustWork=TRUE),path))
z <- .Call(s,NULL)
expected_class <- if(args[[2L]]=="default") "relm_error_intervention" else "relm_error_closed"
expected_message <- if(args[[2L]]=="default") "Projection combined logits selftest is unavailable in this build." else "Projection admission could not access the model."
stopifnot(identical(names(z),c("ok","class","message","fields")),identical(z$ok,FALSE),identical(z$class,expected_class),identical(z$message,expected_message),identical(z$fields,list(reason=expected_message)))
cat(sprintf('F6E_PROJECTION_COMBINED_TOKEN_R {"mode":"%s","status":"passed","expected_cases":2,"executed_cases":2,"expected_rejections":1,"rejected_cases":1,"model_count":0}\n',args[[2L]]))
profile <- .Call(getNativeSymbolInfo('wrap__rebirth_projection_allocation_profile',PACKAGE=dll))
write.csv(data.frame(field=names(profile),value=unlist(profile,use.names=FALSE)),file.path(args[[3L]],paste0(args[[2L]],'-profile.csv')),row.names=FALSE)
