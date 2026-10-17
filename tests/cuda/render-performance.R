# Render retained benchmark timings only; no package/model/RNG work.
a <- commandArgs(TRUE)
input <- if(length(a)) a[[1L]] else "tests/cuda/evidence/2026-10-17/performance-benchmark/owner-timings.csv"
output <- if(length(a)>1L) a[[2L]] else "docs/media/cuda-performance.png"
x <- read.csv(input); x <- x[x$iteration>0L,]
configs <- c("cpu_baseline","cuda_baseline","cuda_live_1ms")
modes <- c("plain_stream","projection_stream","live_stream")
values <- array(NA_real_,c(3L,3L,3L))
for(i in seq_along(configs)) for(j in seq_along(modes)) {
 v <- x$decode_tokens_per_second[x$config==configs[i]&x$mode==modes[j]]
 stopifnot(length(v)==3L,all(is.finite(v)),all(v>0))
 values[i,j,] <- c(min(v),median(v),max(v))
}
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
png(output,width=1400,height=850,res=130)
par(mar=c(6.5,5.5,5,1.5),family="sans",las=1,bg="#fbfcfd",fg="#253344",col.axis="#253344")
colors <- c("#66768c","#008579","#d99324")
pos <- barplot(values[,,2],beside=TRUE,col=colors,border=NA,ylim=c(0,310),
 names.arg=c("Token stream","Static projection","Live observation"),
 ylab="Generated tokens / second",cex.names=1.1,cex.lab=1.1)
abline(h=seq(50,300,50),col="#dce3e8",lty=3)
for(i in 1:3)for(j in 1:3){arrows(pos[i,j],values[i,j,1],pos[i,j],values[i,j,3],angle=90,code=3,length=.04,col="#253344");text(pos[i,j],values[i,j,3]+12,sprintf("%.0f",values[i,j,2]),cex=.9)}
title("Linux CUDA: measured generation and observation costs",line=2.1,adj=0,cex.main=1.35)
mtext("RTX 2060 Mobile 6 GiB · Qwen2.5 0.5B Q8_0 · 128-token cap",side=3,line=.55,adj=0,cex=1)
legend("topright",legend=c("CPU baseline","CUDA baseline (kept)","CUDA live timer 1 ms (rejected)"),fill=colors,bty="n",cex=.9)
mtext("Median and min–max of 3 warmed samples; one prompt, fixed order. No general maximum-speed claim.",side=1,line=3.8,adj=0,cex=.85)
mtext("Same-backend results matched exactly. Projection follows a changed history; live includes R callbacks.",side=1,line=5,adj=0,cex=.85)
invisible(dev.off())
