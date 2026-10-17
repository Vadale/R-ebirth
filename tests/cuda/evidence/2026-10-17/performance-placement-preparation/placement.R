a<-commandArgs(TRUE);stopifnot(length(a)==2L);out<-a[[1]];backend<-a[[2]]
library(relm)
# Initialize the product's Once logger before installing the test-only collector.
stopifnot(identical(sort(relm:::rebirth_available_backends()),c('cpu','cuda')))
main<-function(){
 shim<-dyn.load('/tmp/relm-phase8/installed-pic/log_capture.so');m<-NULL
 stopifnot(.C('f6e_log_start',getLoadedDLLs()[['relm']][['path']],file.path(out,'native.log'),status=integer(1),PACKAGE=shim[['name']])$status==0L)
 on.exit({if(!is.null(m))close(m);stopifnot(.C('f6e_log_stop',status=integer(1),PACKAGE=shim[['name']])$status==0L)},add=TRUE)
 m<-llm('/home/grauk/.local/share/relm/models/qwen2.5-0.5b-instruct-q8_0.gguf',backend=backend,context_length=512L)
 stopifnot(m$backend==backend,m$context_length==512L)
 saveRDS(list(backend=m$backend,context=m$context_length,hidden=m$hidden_size,layers=m$layers,
  gpu_layers=m$gpu_layers,quantization=m$quantization,model_path=m$path,
  counts=c(load=1L,generate=0L,trace=0L,derive=0L,tokenize=0L)),file.path(out,'metadata.rds'))
 close(m);m<-NULL;stopifnot(is.null(relm:::.relm_async$job))
 cat('WP13_PLACEMENT_ONLY_PASS backend=',backend,' load=1 inference=0 owners_closed=TRUE\n',sep='')
}
main()
