args <- commandArgs(trailingOnly=TRUE);stopifnot(length(args)==3L,args[[2L]] %in% c('default','private'))
path <- normalizePath(args[[1L]],mustWork=TRUE);mode <- args[[2L]];out<-args[[3L]]
stopifnot(!'relm' %in% names(getLoadedDLLs()))
dll<-dyn.load(path,local=TRUE,now=TRUE)
s<-getNativeSymbolInfo('wrap__rebirth_projection_construct',PACKAGE=dll)
stopifnot(identical(s$numParameters,7L),identical(normalizePath(s$dll[['path']],mustWork=TRUE),path))
z<-.Call(s,NULL,NULL,NULL,NULL,NULL,NULL,NULL)
stopifnot(identical(names(z),c('ok','class','message','fields')),identical(z$ok,FALSE),identical(z$class,'relm_error_intervention'))
expected<-if(mode=='default') 'Projection construction is unavailable in this build.' else 'Invalid projection admission configuration.'
stopifnot(identical(z$message,expected),identical(z$fields,list(reason=expected)))
profile<-.Call(getNativeSymbolInfo('wrap__rebirth_projection_allocation_profile',PACKAGE=dll))
write.csv(data.frame(field=names(profile),value=unlist(profile,use.names=FALSE)),file.path(out,paste0(mode,'-profile.csv')),row.names=FALSE)
cat(sprintf('F6E_PROJECTION_BRIDGE_R {"mode":"%s","status":"passed","expected_cases":2,"executed_cases":2,"expected_rejections":1,"rejected_cases":1,"model_count":0}\n',mode))
