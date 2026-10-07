setwd('/Users/alessandrovadala/DOCUDESK/R-ebirth')
.libPaths(c('/private/tmp/relm-f6b/library', .libPaths()))
library(relm)
e <- new.env(parent = asNamespace('relm'))
for (p in list.files('rebirth/R', '^graphics.*[.]R$', full.names = TRUE)) sys.source(p, e)
sys.source('rebirth/tests/testthat/helper-llm.R', e)
sys.source('rebirth/tests/testthat/helper-graphics.R', e)
out <- '/private/tmp/relm-f6c/figures'; dir.create(out, showWarnings = FALSE)
golden <- read.csv('tests/graphics/reference/paired.csv')
a <- e$graphics_state_fixture(values = golden$reference)
b <- e$graphics_state_fixture(values = golden$intervention, token = 10L)
x <- e$llm_compare(a, b, e$graphics_context_fixture(9L, 10L), 2)
stopifnot(identical(x$difference, golden$difference))
h <- NULL
for (i in 1:12) {
  rev <- if (i < 4) 0L else if (i < 8) 1L else 2L
  after <- c(0L,3L,7L)[rev+1L]
  coef <- c(0.25,-0.5,0)[rev+1L]
  state <- e$graphics_state_fixture(i, token = as.integer(8 + i %% 4), coef = coef, revision = rev, after = after)
  h <- e$llm_timeline(state, h, max_states = 9)
}
m <- e$stub_llm(interventions = list(list(kind = 'steer', layer = 2L),list(kind='ablate', layer=5L)))
plots <- list(map = function(col) e$plot.llm(m, layers = c(1:6,12), main = 'Model map | illustrative metadata fixture',col=col),
 comparison = function(col) e$plot.relm_comparison(x,main='Observed states | synthetic numeric fixture',col=col),
 timeline = function(col) e$plot.relm_timeline(h,main='Applied steering | synthetic audit fixture',col=col))
for (name in names(plots)) for (size in c('normal','compact','mono')) {
 w <- if(size=='compact') 7 else 10; hh <- if(size=='compact') 5 else 7
 col <- if(size=='mono') '#202020' else c('#2369A0','#B35900','#7047A3')
 path <- file.path(out,paste0(name,'-',size))
 pdf(paste0(path,'.pdf'),width=w,height=hh);plots[[name]](col);dev.off()
 png(paste0(path,'.png'),width=w*140,height=hh*140,res=140,type='quartz');plots[[name]](col);dev.off()
}
write.csv(as.data.frame(x),file.path(out,'comparison.csv'),row.names=FALSE)
write.csv(as.data.frame(h),file.path(out,'timeline.csv'),row.names=FALSE)
saveRDS(list(comparison=x,timeline=h),file.path(out,'figure-data.rds'))
cat('F6C_SYNTHETIC_RENDER_PASSED 9PDF 9PNG\n')
