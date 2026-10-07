# Read accepted measurements only: this renderer never loads a model.
args<-commandArgs(TRUE);stopifnot(length(args) %in% 1:2)
input<-normalizePath(args[1]);out<-file.path(input,'final-figures');dir.create(out,showWarnings=FALSE)
scores<-read.csv(file.path(input,'selection-scores.csv'))
runs<-read.csv(file.path(input,'runs.csv'))
intervals<-read.csv(file.path(input,'paired-intervals.csv'))
graphics<-readRDS(file.path(input,'graphics.rds'))
library(relm)
figures<-list(selection=function() {
 par(mar=c(5,5,4,2)+.1)
 plot(scores$coefficient,scores$mean_characters,type='b',pch=19,xlab='Additive coefficient',ylab='Selection mean output characters',main='Fixed coefficient grid on six selection tasks')
 abline(h=mean(runs$characters[runs$phase=='selection'&runs$setting=='baseline']),lty=2)
 points(scores$coefficient[!scores$eligible],scores$mean_characters[!scores$eligible],pch=4,col='firebrick',cex=1.5)
 legend('bottomleft',c('Learned direction','Baseline','Fails the fixed eligibility rule'),pch=c(19,NA,4),lty=c(1,2,NA),col=c('black','black','firebrick'),bty='n')
},holdout=function() {
 par(mfrow=c(1,2),mar=c(5,4,3,1)+.1,oma=c(4.5,0,3,0))
 for(metric in c('characters','answer')) {
  x<-intervals[intervals$metric==metric,];stopifnot(identical(x$setting,c('zero','selected','random')))
  plot(1:3,x$mean_difference,xlim=c(.65,3.35),ylim=range(c(0,x$lower,x$upper)),xaxt='n',pch=19,cex.axis=.85,
   xlab='Setting versus baseline',ylab=if(metric=='answer')'Change in required-answer inclusion' else 'Change in output characters',
   main=if(metric=='answer')'Literal answer criterion' else 'Output length')
  axis(1,1:3,x$setting,cex.axis=.85);segments(1:3,x$lower,1:3,x$upper);abline(h=0,lty=2)
 }
 mtext('Eight fixed held-out tasks: paired differences and 95% bootstrap intervals',outer=TRUE,side=3,line=1,cex=1.05,font=2)
 mtext('64-token cap: baseline 8/8 and selected 6/8 outputs reach the cap.',outer=TRUE,side=1,line=1,cex=.85)
 mtext('Conditional on these tasks; answer inclusion is not a complete quality assessment.',outer=TRUE,side=1,line=2.2,cex=.8)
},comparison=function()plot(graphics$comparisons[[1]]),timeline=function()plot(graphics$history))
selected <- if(length(args)==2L) args[2L] else names(figures)
stopifnot(all(selected %in% names(figures)))
for(nm in selected) {
 pdf(file.path(out,paste0(nm,'.pdf')),width=10,height=7);tryCatch(figures[[nm]](),finally=dev.off())
 png(file.path(out,paste0(nm,'.png')),width=1400,height=980,res=140,type='quartz');tryCatch(figures[[nm]](),finally=dev.off())
}
cat('F6D_FIGURES_RENDERED_FROM_ACCEPTED_MEASUREMENTS\n')
