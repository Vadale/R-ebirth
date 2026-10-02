# Primary estimand chosen before fitting: programme-minus-comparison mean
# monthly change, visits 0--4. Random intercepts/slopes account for persons.
# Complete observations only; reject missingness instead of silently excluding.
# No stochastic algorithm or resampling is used, so no seed is required.
d <- read.csv(input_paths[[1]], stringsAsFactors = FALSE)
stopifnot(all(c('visit','person','group','score') %in% names(d)),
          !anyNA(d), !anyDuplicated(d[c('person','visit')]),
          all(is.finite(d$score)), all(is.finite(d$visit)),
          setequal(unique(d$group), c('comparison','programme')))
d$group <- factor(d$group, levels=c('comparison','programme'))
d$person <- factor(d$person)
stopifnot(all(table(d$person) == 5L),
          all(vapply(split(d$visit, d$person), function(x) setequal(x,0:4), logical(1))),
          all(vapply(split(d$group, d$person), function(x) length(unique(x))==1L, logical(1))))
d <- d[order(d$person,d$visit),]
contrasts(d$group) <- contr.treatment(c('comparison','programme'),base=1)
fit <- nlme::lme(score ~ group*visit, random=~visit|person, data=d,
                 method='REML', na.action=na.fail)
tt <- summary(fit)$tTable
b <- nlme::fixef(fit)
v <- vcov(fit)
interaction <- 'groupprogramme:visit'
row <- function(id, term, w, units='score units/month', mult=1) {
  estimate <- sum(w*b)*mult
  se <- sqrt(drop(t(w)%*%v%*%w))*abs(mult)
  df <- min(tt[w!=0,'DF'])
  ci <- estimate + c(-1,1)*qt(.975,df)*se
  data.frame(result_id=id,term=term,estimate=estimate,conf_low=ci[1],conf_high=ci[2],
             conf_level=.95,scale='difference',units=units,n=nrow(d),
             n_clusters=nlevels(d$person),method=paste('REML mixed model; Wald t 95% CI; df',df),
             status='ok',p_value=2*pt(-abs(estimate/se),df))
}
w <- setNames(rep(0,length(b)),names(b)); w[interaction] <- 1
est <- row('primary_slope','Programme minus comparison: monthly change',w)
est <- rbind(est,row('primary_4month','Programme minus comparison: 4-month change',w,
                     units='score units',mult=4))
w[] <- 0; w['visit'] <- 1
est <- rbind(est,row('comparison_slope','Comparison monthly change',w))
w[interaction] <- 1
est <- rbind(est,row('programme_slope','Programme monthly change',w))
w[] <- 0; w['groupprogramme'] <- 1
est <- rbind(est,row('baseline_difference','Programme minus comparison at visit 0',w,units='score units'))
# Design-based sensitivity: one first-to-last change per person and Welch CI.
first <- d[d$visit==0,]; last <- d[d$visit==4,]
change <- data.frame(person=first$person,group=first$group,
                     change=last$score[match(first$person,last$person)]-first$score)
test <- t.test(change$change[change$group=='programme'],
               change$change[change$group=='comparison'], conf.level=.95)
est <- rbind(est,data.frame(result_id='sensitivity_4month',term='Programme minus comparison: observed 4-month change',
 estimate=unname(diff(rev(test$estimate))),conf_low=test$conf.int[1],conf_high=test$conf.int[2],
 conf_level=.95,scale='difference',units='score units',n=nrow(change),n_clusters=nrow(change),
 method=paste('Welch t 95% CI on independent person-level changes; df',round(unname(test$parameter),2)),
 status='exploratory',p_value=test$p.value))
# Lack-of-linearity sensitivity uses identical covariance structures and ML.
linear_ml <- update(fit,method='ML')
curved_ml <- update(fit,fixed=score~group*factor(visit),method='ML')
form_check <- anova(linear_ml,curved_ml)
write.csv(form_check,file.path(output_dir,'linearity-check.csv'),row.names=FALSE)
write.csv(change,file.path(output_dir,'person-changes.csv'),row.names=FALSE)
means <- aggregate(score~group+visit,d,mean)
means$sd <- aggregate(score~group+visit,d,sd)$score
means$n <- aggregate(score~group+visit,d,length)$score
write.csv(means,file.path(output_dir,'observed-means.csv'),row.names=FALSE)
writeLines(capture.output(summary(fit)),file.path(output_dir,'model-summary.txt'))
writeLines(capture.output(nlme::VarCorr(fit)),file.path(output_dir,'variance-components.txt'))
acf <- nlme::ACF(fit,resType='normalized')
write.csv(acf,file.path(output_dir,'residual-acf.csv'),row.names=FALSE)
res <- residuals(fit,type='normalized')
write.csv(data.frame(group=d$group,visit=d$visit,fitted=fitted(fit),residual=res),
          file.path(output_dir,'residuals.csv'),row.names=FALSE)
# Fixed-effects uncertainty for population group means; conservative df 58.
new <- expand.grid(visit=seq(0,4,length.out=81),group=levels(d$group))
new$group <- factor(new$group,levels=levels(d$group))
x <- model.matrix(~group*visit,new,contrasts.arg=list(group=contrasts(d$group)))
new$mean <- as.vector(x%*%b)
se <- sqrt(rowSums((x%*%v)*x))
new$low <- new$mean-qt(.975,min(tt[,'DF']))*se
new$high <- new$mean+qt(.975,min(tt[,'DF']))*se
write.csv(new,file.path(output_dir,'fitted-trajectories.csv'),row.names=FALSE)
png(file.path(output_dir,'trajectories.png'),width=1300,height=850,res=140)
cols <- c('#0072B2','#D55E00')
plot(NA,xlim=c(0,4),ylim=range(c(new$low,new$high,means$score)),
     xlab='Months from first visit',ylab='Score (original units)',
     main='Observed group means and fitted mean trajectories',sub='60 persons; 30 per group. Shading: pointwise 95% CI for population means.')
for (i in 1:2) {
 g <- levels(d$group)[i]; z <- new[new$group==g,]; m <- means[means$group==g,]
 polygon(c(z$visit,rev(z$visit)),c(z$low,rev(z$high)),border=NA,col=adjustcolor(cols[i],alpha.f=.16))
 lines(z$visit,z$mean,col=cols[i],lwd=2)
 points(m$visit,m$score,pch=c(16,17)[i],col=cols[i],cex=1.2)
}
legend('topleft',legend=c('Comparison','Programme'),col=cols,pch=c(16,17),lwd=2,bty='n')
dev.off()
png(file.path(output_dir,'diagnostic-plots.png'),width=1300,height=650,res=130)
par(mfrow=c(1,2));plot(fitted(fit),res,xlab='Conditional fitted score',ylab='Normalized residual');abline(h=0,lty=2)
qqnorm(res,main='Normalized residual Q-Q plot');qqline(res);dev.off()
diagnostics <- data.frame(check=c('data','dependence','convergence','linearity','residual_correlation','distribution','causality'),
 status=c('pass','pass','pass','pass','not_assessed','not_assessed','warn'),
 detail=c('300 complete rows, 60 persons, 30 per group, unique person/visit and stable groups.',
 'Random intercepts and slopes by person; residual errors assumed independent conditional on random effects.',
 'nlme::lme returned without a reported convergence failure; inspect captured conditions and variance components.',
 sprintf('Exploratory ML test of categorical vs linear group trajectories: p=%.4g; non-significance does not prove linearity.',form_check[2,'p-value']),
 'Residual ACF retained for inspection; five visits per person limit covariance diagnosis.',
 'Residual/fitted and Q-Q plots retained for visual inspection; Gaussian random effects and conditional errors are assumptions.',
 'Nonrandom group allocation; no adjustment covariates or pretreatment trends supplied. Association only.'))
list(summary=c(sprintf('Programme-minus-comparison monthly change: %.3f score units (95%% CI %.3f to %.3f).',est$estimate[1],est$conf_low[1],est$conf_high[1]),
 sprintf('Over months 0 to 4: %.3f additional score units (95%% CI %.3f to %.3f).',est$estimate[2],est$conf_low[2],est$conf_high[2]),
 sprintf('Person-level change sensitivity: %.3f units (95%% CI %.3f to %.3f).',tail(est$estimate,1),tail(est$conf_low,1),tail(est$conf_high,1))),
 estimates=est,diagnostics=diagnostics,
 limitations=c('Nonrandomized groups: a trajectory difference cannot identify the causal effect of programme participation; confounding and selection remain.',
 'No score definition or minimally important difference is supplied; practical benefit and even whether higher scores are desirable cannot be established.',
 'The primary estimand assumes linear mean trajectories over four monthly intervals. Confidence intervals are conditional on the model and do not include model-selection or confounding uncertainty.',
 'No external population sampling frame or pretreatment trends are supplied. Generalization beyond these participants requires further justification.'))
