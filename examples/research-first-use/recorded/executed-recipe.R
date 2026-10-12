# Self-contained bounded public-API first-use exercise. Run once in a fresh R process.
# No download/build/install. OUTPUT_DIR must not exist. Long native work is run
# by launching this script in a background R process; live delivery pumps R's event loop.
.libPaths(c('/private/tmp/relm-release-0.4.0/runiverse-install/library',
            '/Users/alessandrovadala/Library/R/arm64/4.5/library', .libPaths()))
output_dir <- Sys.getenv('OUTPUT_DIR', '/private/tmp/relm-onboarding/agent/results/run-01')
model_path <- Sys.getenv('MODEL_PATH', '/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf')
stopifnot(!file.exists(output_dir), dir.exists(dirname(output_dir)))
dir.create(output_dir)
p <- function(name) file.path(output_dir, name)
save <- function(x, name) saveRDS(x, p(name), version=3)
csv <- function(x, name) write.csv(x, p(name), row.names=FALSE, fileEncoding='UTF-8')
hash_text <- function(x) {
  f <- tempfile(); on.exit(unlink(f)); writeBin(charToRaw(enc2utf8(x)), f)
  unname(tools::sha256sum(f))
}
figure <- function(name, draw) {
  png(p(name), width=1400, height=980, res=140)
  on.exit(dev.off()); draw()
}
conditions_log <- list(); timings <- list(); current_step <- 'startup'
record_condition <- function(c, kind) {
  conditions_log[[length(conditions_log)+1L]] <<- list(
    time=as.character(Sys.time()), step=current_step, kind=kind,
    classes=class(c), message=conditionMessage(c), condition=c)
  save(conditions_log, 'conditions.rds')
  csv(do.call(rbind, lapply(conditions_log, function(z)
    data.frame(time=z$time, step=z$step, kind=z$kind,
               classes=paste(z$classes, collapse=';'), message=z$message))), 'conditions.csv')
}
step <- function(name, expr) {
  current_step <<- name; cat(format(Sys.time()), name, '\n'); flush.console()
  start <- proc.time()[['elapsed']]
  on.exit({ timings[[name]] <<- data.frame(step=name, seconds=proc.time()[['elapsed']]-start)
    csv(do.call(rbind, timings), 'timings.csv') })
  force(expr)
}
writeLines('INCOMPLETE', p('STATUS.txt'))
run <- function() {
  library(relm)
  stopifnot(as.character(packageVersion('relm')) == '0.4.0',
    packageDescription('relm')$RemoteSha == '3bd5da7399dc163d8c9e4a4e1865a875e7186e71',
    all(c('llm_direction','llm_apply_direction','llm_compare','llm_timeline') %in% getNamespaceExports('relm')),
    requireNamespace('later', quietly=TRUE), requireNamespace('promises',quietly=TRUE),
    getNamespaceVersion('later') >= package_version('1.4.8'),
    getNamespaceVersion('promises') >= package_version('1.5.0'))
  writeLines(capture.output(sessionInfo()), p('session-info.txt'))
  model_sha <- step('model_checksum', unname(tools::sha256sum(model_path)))
  stopifnot(identical(model_sha, 'ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'))
  prompts <- data.frame(
    id=c('box-target','box-control','parcel-target','parcel-control','reserved-selection','direct','explicit'),
    split=c(rep('construction',4),'selection','evaluation','evaluation'),
    executed=c(TRUE,TRUE,TRUE,TRUE,FALSE,TRUE,TRUE),
    text=c(
      'Question: A locked box has no label. What material is the object inside made of?\nAnswer: There is not enough information to determine the material.',
      'Question: A locked box has no label. What material is the object inside made of?\nAnswer: The object inside is made of copper.',
      'Question: The contents of an unopened parcel are not described. What color is the item inside?\nAnswer: There is not enough information to determine the color.',
      'Question: The contents of an unopened parcel are not described. What color is the item inside?\nAnswer: The item inside is blue.',
      'Question: A closed drawer has no description. What tool is inside?\nAnswer:',
      'Question: A sealed envelope has no markings. Which city is named in the letter inside?\nAnswer:',
      'Question: A sealed envelope has no markings. Which city is named in the letter inside? State the city, or say that the evidence is insufficient.\nAnswer:'
    ), stringsAsFactors=FALSE)
  prompts$sha256 <- vapply(prompts$text, hash_text, character(1))
  csv(prompts, 'prompts.csv')
  settings <- list(seed=3107L, chat=FALSE, temperature=0, top_p=0.95,
    max_tokens=48L, stop=NULL, context_length=512L, backend='cpu',
    relm_version=as.character(packageVersion('relm')), engine_revision='b10828-patched-D039-D040')
  save(settings,'settings.rds')
  csv(data.frame(condition=c('original','zero','addition'), operator=c('none','add','add'),
                 coefficient=c(0,0,1)), 'design.csv')
  m <- step('load_original', llm(model_path, backend='cpu', context_length=512L))
  on.exit(close(m),add=TRUE)
  stopifnot(m$architecture=='qwen2', m$hidden_size==896L, m$layers==24L, m$backend=='cpu')
  model_record <- list(sha256=model_sha, architecture=m$architecture,
    quantization=m$quantization, hidden_size=as.integer(m$hidden_size),
    layers=as.integer(m$layers), engine_revision=settings$engine_revision)
  # Metadata is independently recorded from the verified file and actual original handle.
  save(list(model=model_record, path=model_path, installed_library=find.package('relm'),
      RemoteSha=packageDescription('relm')$RemoteSha,
      engine_revision_source='Caller-supplied public release build label; not native binary authentication'), 'provenance.rds')
  dll <- getLoadedDLLs()[['relm']][['path']]
  csv(data.frame(path=dll, sha256=unname(tools::sha256sum(dll))), 'installed-dll.csv')
  captures <- lapply(1:4,function(i) step(paste0('trace_',prompts$id[i]),
    llm_trace(m,prompts$text[i],layers=12L,positions='last',components='residual',spill=FALSE)))
  save(captures,'construction.rds')
  for (tr in captures) stopifnot(nrow(tr)==896L, length(unique(tr$token_pos))==1L,
                              identical(tr$neuron,1:896), all(is.finite(tr$value)))
  csv(do.call(rbind,lapply(seq_along(captures),function(i) data.frame(prompt_id=prompts$id[i],
    rows=nrow(captures[[i]]), layer=12L, component='residual',
    source_position=unique(captures[[i]]$token_pos)))), 'capture-summary.csv')
  pairs <- data.frame(pair_id=c('box','parcel'), target_sha256=prompts$sha256[c(1,3)],
    control_sha256=prompts$sha256[c(2,4)],
    target_pos=vapply(captures[c(1,3)],function(tr) unique(tr$token_pos),integer(1)),
    control_pos=vapply(captures[c(2,4)],function(tr) unique(tr$token_pos),integer(1)))
  target <- do.call(rbind,lapply(captures[c(1,3)],function(tr)tr$value))
  control <- do.call(rbind,lapply(captures[c(2,4)],function(tr)tr$value))
  dimnames(target) <- dimnames(control) <- list(pairs$pair_id,as.character(1:896))
  context <- list(model=model_record, capture=list(component='residual',positions='last',
    input_format='raw_text',tokenizer='gguf_embedded',add_special=TRUE,parse_special=FALSE,
    template_sha256=NULL,context_length=512L,backend='cpu',relm_version=settings$relm_version),
    pairs=pairs,splits=data.frame(prompt_sha256=prompts$sha256,split=prompts$split),seed=NULL)
  direction <- step('construct_direction',llm_direction(target,control,context,layer=12L))
  save(direction,'direction.rds'); stopifnot(identical(direction,readRDS(p('direction.rds'))))
  collect <- function(handle,prompt,key) {
    first <- NULL; last <- NULL; ids <- integer(); timeline <- NULL; events <- list()
    done <- FALSE; value <- NULL; failure <- NULL
    pending <- llm_generate(handle,prompt,chat=settings$chat,max_tokens=settings$max_tokens,
      temperature=settings$temperature,top_p=settings$top_p,seed=settings$seed,async=TRUE,
      layers=12L,components='residual',top=5L,spill=FALSE,
      on_token=function(batch) { events[[length(events)+1L]] <<- batch; invisible(NULL) },
      on_state=function(state) {
        if(is.null(first)) first <<- state
        last <<- state; ids <<- c(ids,state$step$token_id)
        timeline <<- llm_timeline(state,timeline,max_states=48L)
        invisible(NULL)
      })
    observer <- promises::then(pending,
      onFulfilled=function(x){value <<- x; done <<- TRUE; NULL},
      onRejected=function(e){failure <<- e; done <<- TRUE; NULL})
    deadline <- proc.time()[['elapsed']]+120
    while(!done && proc.time()[['elapsed']]<deadline) later::run_now(0.05)
    if(!done) {
      llm_cancel(handle); deadline <- proc.time()[['elapsed']]+30
      while(!done && proc.time()[['elapsed']]<deadline) later::run_now(0.05)
      stop('Generation exceeded fixed watchdog; no automatic retry.')
    }
    if(!is.null(failure)) stop(failure)
    event_table <- do.call(rbind,events)
    result <- list(text=value,first=first,last=last,ids=ids,timeline=timeline,events=event_table)
    save(result,paste0(key,'.rds')); csv(event_table,paste0(key,'-events.csv'))
    stopifnot(!is.null(first),identical(paste0(event_table$text[event_table$event=='text'],collapse=''),unname(value[[1L]])))
    result
  }
  results <- list(); output_rows <- list()
  for(condition in c('original','zero','addition')) {
    (function() {
      handle <- m
      if(condition!='original') {
        handle <- step(paste0('derive_',condition),llm_apply_direction(m,direction,model_record,
          coef=if(condition=='zero')0 else 1,operator='add'))
        on.exit({close(handle); cat('CLOSED derived',condition,'\n')},add=TRUE)
      }
      if(condition=='addition') {
        figure('configured-model.png',function()plot(handle,layers=c(1L,12L,24L)))
        rejected <- tryCatch(llm_trace(handle,prompts$text[6],layers=12L,positions='last',
          components='residual',spill=FALSE),error=function(e)e)
        stopifnot(inherits(rejected,'relm_error_trace'))
        record_condition(rejected,'expected documented capability rejection')
        save(rejected,'expected-trace-rejection.rds')
      }
      for(i in 6:7) {
        key <- paste(prompts$id[i],condition,sep='-')
        value <- step(paste0('generate_',key),collect(handle,prompts$text[i],key))
        results[[key]] <<- value
        output_rows[[key]] <<- data.frame(prompt_id=prompts$id[i],condition=condition,
          characters=nchar(value$text[[1]],type='chars'),sampled_states=length(value$ids),
          finish_reason=value$events$finish_reason[value$events$event=='prompt_end'],
          text=unname(value$text[[1]]))
        csv(do.call(rbind,output_rows),'outputs.csv')
      }
    })()
  }
  for(id in c('direct','explicit')) {
    baseline <- results[[paste(id,'original',sep='-')]]
    zero <- results[[paste(id,'zero',sep='-')]]
    addition <- results[[paste(id,'addition',sep='-')]]
    stopifnot(identical(baseline$text,zero$text),identical(baseline$ids,zero$ids))
    observation <- function(x)list(model_sha256=model_sha,settings=settings,generated_tokens=x$ids[1L])
    compared <- step(paste0('compare_',id),llm_compare(baseline$first,addition$first,
      list(reference=observation(baseline),intervention=observation(addition)),
      layer=12L,component='residual'))
    save(compared,paste0(id,'-comparison.rds')); csv(as.data.frame(compared),paste0(id,'-comparison.csv'))
    figure(paste0(id,'-comparison.png'),function()plot(compared,
      main=paste('First state:',id,'prompt; residual addition versus original')))
  }
  csv(data.frame(prompt_id=c('direct','explicit'),original_zero_text_identical=TRUE,
                 original_zero_sampled_ids_identical=TRUE),'zero-controls.csv')
  figure('addition-timeline.png',function()plot(results[['explicit-addition']]$timeline,
    main='Applied coefficient: explicit prompt, fixed residual addition'))
  save(results,'all-results.rds')
  close(m); cat('CLOSED original\n')
  files <- list.files(output_dir,full.names=TRUE)
  csv(data.frame(file=basename(files),sha256=unname(tools::sha256sum(files))),'files.csv')
  writeLines('COMPLETE: bounded first-use execution; no efficacy or external-human-usability claim.',p('STATUS.txt'))
}
tryCatch(withCallingHandlers(run(),warning=function(w)record_condition(w,'warning')),
  error=function(e){record_condition(e,'unexpected error'); writeLines('FAILED: inspect conditions and retained partial evidence.',p('STATUS.txt')); quit(status=1L)})
