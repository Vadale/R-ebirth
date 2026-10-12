# Recreates evidence plots/tables from trusted saved outputs; no model is loaded.
root <- '/private/tmp/relm-onboarding/agent/results/run-01'
out <- read.csv(file.path(root,'outputs.csv'),check.names=FALSE)
review <- data.frame(prompt_id=out$prompt_id,condition=out$condition,
  unsupported_city_assertion=TRUE,
  acknowledges_insufficient_evidence=out$prompt_id=='explicit' & out$condition!='addition',
  internally_consistent=!(out$prompt_id=='explicit' & out$condition!='addition'),
  completed_without_token_cap=out$finish_reason!='length',
  task_correct=FALSE,
  annotation='Manual descriptive review of the full text; no city is inferable from either prompt.')
write.csv(review,file.path(root,'manual-review.csv'),row.names=FALSE)
comparison_stats <- do.call(rbind,lapply(c('direct','explicit'),function(id){
  x <- readRDS(file.path(root,paste0(id,'-comparison.rds')))
  data.frame(prompt_id=id,coordinates=nrow(x),aligned=attr(x,'alignment')$matched,
    min_difference=min(x$difference),max_difference=max(x$difference),
    l2_difference=sqrt(sum(x$difference^2)))
}))
write.csv(comparison_stats,file.path(root,'comparison-summary.csv'),row.names=FALSE)
# Show all four distinct condition outputs. Zero controls exactly duplicate originals.
png(file.path(root,'response-review.png'),width=1600,height=1180,res=140)
par(mar=c(0,0,0,0),family='sans')
plot.new(); plot.window(xlim=c(0,1),ylim=c(0,1),xaxs='i',yaxs='i')
text(.045,.954,'The model changed its answers; it still invented missing facts',adj=0,cex=1.55,font=2,col='#142D43')
text(.045,.908,'Two formulations of one unanswerable envelope / city question',adj=0,cex=1.05,col='#435569')
text(.045,.870,'No city, language or addressee is provided in either prompt. All generated text is shown below.',adj=0,cex=.98,col='#435569')
labels <- c('Direct question | original','Explicit uncertainty option | original',
            'Direct question | addition = 1','Explicit uncertainty option | addition = 1')
keys <- list(c('direct','original'),c('explicit','original'),c('direct','addition'),c('explicit','addition'))
boxes <- list(c(.04,.51,.49,.815),c(.515,.985,.49,.815),c(.04,.51,.13,.455),c(.515,.985,.13,.455))
for(i in 1:4){
  b<-boxes[[i]]; z<-out[out$prompt_id==keys[[i]][1]&out$condition==keys[[i]][2],]
  rect(b[1],b[3],b[2]-.02,b[4],col='#F2F5F8',border='#D7E0E7')
  text(b[1]+.018,b[4]-.03,labels[i],adj=c(0,1),font=2,cex=1.04,col='#142D43')
  text(b[1]+.018,b[4]-.075,paste(z$sampled_states,'sampled states | finish:',z$finish_reason),adj=c(0,1),cex=.88,col='#6C4A33')
  paragraphs <- strsplit(trimws(z$text),'\n',fixed=TRUE)[[1]]
  lines <- unlist(lapply(paragraphs,function(s)if(nzchar(s))strwrap(s,width=56)else''))
  text(b[1]+.018,b[4]-.118,paste(lines,collapse='\n'),adj=c(0,1),cex=1.0,col='#223448')
}
text(.045,.087,'Zero coefficient exactly reproduced original text and sampled-token IDs for both prompts.',adj=0,cex=.97,col='#435569')
text(.045,.049,'Qwen2.5-0.5B Q8_0 | relm 0.4.0 | CPU | seed 3107 | greedy | 48-token cap | layer 12 residual',adj=0,cex=.87,col='#435569')
text(.045,.018,'One bounded agent-led first-use exercise. No tuning, general efficacy claim or external-human usability evidence.',adj=0,cex=.82,col='#435569')
dev.off()
