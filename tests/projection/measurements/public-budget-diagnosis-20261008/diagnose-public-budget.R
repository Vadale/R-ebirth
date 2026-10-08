library(relm)
stopifnot(normalizePath(find.package('relm'))==normalizePath('/private/tmp/relm-f6e/public-library-corrected/relm'))
root <- '/private/tmp/relm-f6e/installed-public-docs-20261008-101706'
d <- readRDS(file.path(root,'public-direction.rds'))
record <- readRDS(file.path(root,'public-captures.rds'))$context$model
path <- '/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf'
m <- llm(path,backend='cpu',context_length=512L)
on.exit(close(m))
entry <- list(kind='project',layer=attr(d,'direction')$layer,component='mlp_out',direction=d$value,coef=1)
v <- relm:::direction_validate(d,extra_bytes=4*as.double(utils::object.size(record)))
p <- relm:::projection_prepare(m,entry,64*1024^2,v$estimate_bytes,direction_application=TRUE)
x <- tryCatch(llm_apply_direction(m,d,record,coef=1,max_bytes=p$response$terms$total_bytes-1,operator='project'),error=identity)
if(inherits(x,'llm')) {close(x);stop('Unexpected successful underbudget construction')}
stopifnot(inherits(x,'error'))
dput(list(class=class(x),message=conditionMessage(x),fields=as.list(x),exact_budget=p$response$terms$total_bytes,profile=p$profile,inputs=p$response$inputs,terms=p$response$terms),file='/private/tmp/relm-f6e/public-budget-diagnosis.R')
close(m)
cat('F6E_BUDGET_DIAGNOSIS recorded=TRUE model_loads=1 inference_calls=0\n')
