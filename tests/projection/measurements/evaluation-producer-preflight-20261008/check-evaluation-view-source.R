source('tests/projection/evaluation/run.R')
p<-list(ids=c(11L,22L),pieces=c('a','b'))
e<-data.frame(event='token',token_id=33L)
a<-list(step=data.frame(state_id=1L,source_pos=2L,token_id=999L),trace=structure(data.frame(token='b'),prompt_token_count=2L))
b<-list(step=data.frame(state_id=2L,source_pos=3L,token_id=888L),trace=structure(data.frame(token='c'),prompt_token_count=2L))
stopifnot(identical(f6e_view_source(a,e,p),list(id=22L,prefix='')),
 identical(f6e_view_source(b,e,p),list(id=33L,prefix='33')))
rejects<-function(expr) inherits(tryCatch(force(expr),error=identity),'error')
bad<-a;attr(bad$trace,'prompt_token_count')<-3L
stopifnot(rejects(f6e_view_source(bad,e,p)))
bad<-a;bad$trace$token<-'wrong'
stopifnot(rejects(f6e_view_source(bad,e,p)),rejects(f6e_view_source(b,e[FALSE,],p)))
cat('F6E_VIEW_SOURCE_PREFLIGHT cases=5 positives=2 refusals=3 models=0 inference=0\n')
