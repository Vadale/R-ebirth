.libPaths(c('/home/grauk/.local/share/relm/phase8/R-library', .Library), include.site=FALSE)
stopifnot(as.character(packageVersion('ps')) == '1.9.3')
source('examples/funding-service/common.R'); source('examples/funding-service/runtime.R')
owner <- svc_process(); h <- ps::ps_handle(owner$pid)
old <- owner; old$birth <- sprintf('%.6f', as.numeric(owner$birth)-1)
zero <- owner; zero$birth <- '0.000000'
line <- readLines(sprintf('/proc/%d/stat', owner$pid))
fields <- strsplit(sub('^.*\\) ', '', line), ' ', fixed=TRUE)[[1L]]
period <- 1/as.numeric(system2('getconf', 'CLK_TCK', stdout=TRUE))
legacy_boot <- as.numeric(sub('^btime ', '', grep('^btime ', readLines('/proc/stat'), value=TRUE)))
legacy <- owner; legacy$birth <- sprintf('%.6f', legacy_boot+as.numeric(fields[[20L]])*period)
result <- list(ps_version=as.character(packageVersion('ps')), owner=owner,
 old_fixture=old, old_alive=svc_alive(old), legacy_fixture=legacy, legacy_alive=svc_alive(legacy),
 epoch_fixture=zero, epoch_alive=svc_alive(zero), owner_alive=svc_alive(owner),
 clock_period=period, model_loads=0L)
stopifnot(isTRUE(result$owner_alive), isTRUE(result$legacy_alive), identical(result$epoch_alive,FALSE))
writeLines(jsonlite::toJSON(result, auto_unbox=TRUE, pretty=TRUE, digits=17),
 '/home/grauk/Work/relm-phase9/process-identity-5371f40/real-process-observation.json')
cat('REAL_PROCESS_OBSERVATION_OK old_fixture_alive=', result$old_alive, ' legacy_alive=TRUE epoch_alive=FALSE owner_alive=TRUE models=0\n',sep='')
