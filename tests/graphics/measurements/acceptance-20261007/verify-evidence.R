root<-'/private/tmp/relm-f6c'
a<-readRDS(file.path(root,'package-resume-20261007-134046/model-graphics.rds'))
r<-readRDS(file.path(root,'rstudio/restoration.rds'))
stopifnot(all(unlist(r$checks)))
for(i in c('comparison','spill','later_comparison')) {
 x<-a[[i]];stopifnot(nrow(x)==896L,identical(x$neuron,1:896),
  identical(x$difference,x$intervention-x$reference),
  as.double(object.size(x))<=attr(x,'estimate_bytes'),attr(x,'estimate_bytes')<=attr(x,'max_bytes'))
}
stopifnot(max(abs(a$spill$difference))==0,
 max(abs(a$comparison$difference-0.05))<1e-6,
 identical(a$timeline$state_id,3:8),all(a$timeline$coef==0.5),
 isTRUE(all.equal(read.csv(file.path(root,'rstudio/export.csv')),as.data.frame(a$comparison),check.attributes=FALSE)))
cat('F6C_INDEPENDENT_RECEIPT_CHECK_PASSED: 896 coordinates; additive 0.05 within 1e-6; spill exact; IDs 3:8; RStudio CSV and all restoration fields\n')
