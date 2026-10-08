# New producer serialization/routing preflight only; no model creation or inference.
source('tests/projection/evaluation/run.R')
args <- commandArgs(TRUE); stopifnot(length(args) == 1L)
out <- args[[1L]]; dir.create(out, recursive = TRUE)
values <- list(NULL, TRUE, 2L, -0, paste('è', intToUtf8(0x1f680)), c(1L,2L), c(.1,-0), c('x','y'),
  data.frame(a = 1:2, b = c(.5,-.25)), list(neuron=1L,value=.2),
  matrix(c(.5,-0,2,3),2L,dimnames=list(c('a','b'),c('1','2'))))
f6e_json(lapply(values, f6e_node), file.path(out, 'typed.json'))
x <- data.frame(x=c('a\nb', 'è,"x"', 'NA'), y=c(NA_integer_,1L,2L),z=c(TRUE,FALSE,NA))
f6e_csv(x,file.path(out,'transport.csv'))
f6e_text(structure('è\n',seed=1046),file.path(out,'text.txt'))
manifest <- jsonlite::read_json('tests/projection/evaluation/manifest.json',simplifyVector=TRUE)
settings <- c(manifest$selection_settings,'selected_add','selected_project')
f6e_json(lapply(settings,function(k)c(list(setting=k),f6e_setting(k,list(add=-1,project=.5)))),file.path(out,'settings.json'))
stopifnot(length(f6e_empty_events())==9L,nrow(f6e_empty_events())==0L)
# Confirm actual installed APIs accept the planned argument names without invoking them.
.libPaths(c('/private/tmp/relm-f6e/public-library-budget',.libPaths()))
ns<-asNamespace('relm')
stopifnot(all(c('m','prompts','layers','components','positions','spill') %in% names(formals(get('llm_trace',ns)))),
 all(c('m','prompt','async','on_state','on_token','top','spill') %in% names(formals(get('llm_generate',ns)))),
 all(c('direction','context','operator','max_bytes') %in% names(formals(get('llm_apply_direction',ns)))))
cat('F6E_PRODUCER_R_PREFLIGHT typed_nodes=11 settings=14 csv_rows=3 model_calls=0\n')
