# Saved F6e-v1 observations only: no model, inference, selection or RNG draws.
args <- commandArgs(TRUE); stopifnot(length(args)==2L)
input <- normalizePath(args[[1L]]); output <- normalizePath(args[[2L]])
library(relm)
stopifnot(normalizePath(find.package('relm'))=='/private/tmp/relm-f6e/public-library-budget/relm')
report <- jsonlite::read_json(file.path(input,'complete-report.json'))
cfg <- jsonlite::read_json(file.path(input,'config.json'))
stopifnot(unname(tools::sha256sum(getLoadedDLLs()[['relm']][['path']]))==cfg$dll_sha256)
draw <- function(name, f) {
  for(kind in c('pdf','png')) {
    path <- file.path(output,paste0(name,'.',kind))
    if(kind=='pdf') grDevices::pdf(path,width=11,height=8) else grDevices::png(path,width=1650,height=1200,res=150)
    tryCatch(f(),finally=grDevices::dev.off())
  }
}
states <- lapply(c('v001','v002'),function(id) lapply(1:2,function(i) readRDS(file.path(input,'states',paste0(id,'-',i,'.rds')))))
settings <- list(seed=1046,chat=FALSE,temperature=0,top_p=.95,max_tokens=256L,stop=NULL,
  context_length=512L,backend='cpu',relm_version='0.3.0',engine_revision='b10828-patched-D039-D040')
for(i in 1:2) {
  context <- setNames(lapply(1:2,function(j) list(model_sha256=cfg$model_sha256,settings=settings,
    generated_tokens=vapply(states[[j]][seq_len(i)],function(s) s$step$token_id,integer(1)))),c('reference','intervention'))
  comparison <- llm_compare(states[[1L]][[i]],states[[2L]][[i]],context,12L,'mlp_out')
  expected <- states[[2L]][[i]]$trace$value-states[[1L]][[i]]$trace$value
  stopifnot(nrow(comparison)==896L,identical(comparison$difference,expected),isTRUE(attr(comparison,'alignment')$matched))
  saveRDS(comparison,file.path(output,paste0('comparison-',i,'.rds')))
  write.csv(comparison,file.path(output,paste0('comparison-',i,'.csv')),row.names=FALSE)
  draw(paste0('comparison-',i),function() plot(comparison,main=paste('Observed MLP difference | aligned state',i)))
}
for(j in 1:2) {
  timeline <- llm_timeline(states[[j]][[1L]],max_states=2L)
  timeline <- llm_timeline(states[[j]][[2L]],timeline,max_states=2L)
  stopifnot(nrow(timeline)==2L,identical(timeline$state_id,1:2),all(timeline$steering_revision==0L),all(is.na(timeline$coef)))
  saveRDS(timeline,file.path(output,paste0('timeline-',j,'.rds')))
  draw(paste0('timeline-',j),function() plot(timeline,main=if(j==1L) 'Original | two sampled states' else 'Static projection | no additive live revisions'))
}
tab <- read.csv(file.path(input,'owner-summary.csv'))
show <- c('baseline','selected_add','selected_project','random_project_1')
tab <- tab[match(show,tab$setting),]; labels <- c('Original','Addition (2)','Projection (1)','Random projection')
write.csv(tab,file.path(output,'final-summary.csv'),row.names=FALSE)
intervals <- do.call(rbind,lapply(report$intervals,function(x) data.frame(setting=x$setting,reference=x$reference,
  metric=x$metric,estimate=x$estimate,conf_low=x$conf_low,conf_high=x$conf_high)))
write.csv(intervals,file.path(output,'paired-intervals.csv'),row.names=FALSE)
draw('evaluation-summary',function() {
  par(mfrow=c(2,2),mar=c(7,4.5,3,1),oma=c(0,0,4,0))
  cols <- c('#59636e','#156b8a','#b65b2b','#8d78a5')
  barplot(tab$mean_characters,names.arg=labels,las=2,col=cols,ylab='Mean characters',main='All eight final questions')
  barplot(tab$truncated,names.arg=labels,las=2,col=cols,ylim=c(0,8),ylab='Count of eight',main='Reached the 256-token limit')
  barplot(tab$required,names.arg=labels,las=2,col=cols,ylim=c(0,8),ylab='Count of eight',main='Literal required-answer inclusion')
  x <- intervals[intervals$metric=='characters' & intervals$reference=='baseline' & intervals$setting %in% show[-1L],]
  x <- x[match(show[-1L],x$setting),]
  plot(seq_len(3L),x$estimate,ylim=range(c(0,x$conf_low,x$conf_high)),xaxt='n',xlab='',ylab='Character difference vs original',pch=19,col=cols[-1L],main='Paired descriptive 95% intervals')
  axis(1,at=1:3,labels=labels[-1L],las=2);abline(h=0,lty=2,col='#59636e')
  segments(1:3,x$conf_low,1:3,x$conf_high,col=cols[-1L],lwd=2)
  mtext('F6e-v1 | Fixed convenience corpus, n = 8 | Coefficients locked before final evaluation',outer=TRUE,line=2,cex=.95)
  mtext('Length-limited outputs; literal inclusion is not general correctness. No isolated-operator or population claim.',outer=TRUE,line=.6,cex=.8)
})
jsonlite::write_json(list(status='awaiting_visual_verification',models=0,inference=0,
  comparison_coordinates=1792L,timeline_states=4L,figures=5L,PDF=5L,PNG=5L,
  model_map='Not executed; requires a separate actual open configured handle',
  scope='Saved actual observations and independently verified fixed-corpus summaries'),
  file.path(output,'render-receipt.json'),auto_unbox=TRUE,pretty=TRUE)
cat('F6E_RENDER_COMPLETE comparison_coordinates=1792 timeline_states=4 figures=5 models=0 inference=0\n')
