# Raw-result inspection only; never loads relm or a model.
b <- '/home/grauk/Work/relm-phase9'
x <- readRDS(file.path(b, 'readiness-fixtures/installed-result.rds'))
stopifnot(length(x$functions) == 250L, length(x$profile) == 27L,
          length(x$registered) == 33L, !any(grepl('selftest', x$registered)),
          identical(x$version, '0.4.0'), x$loads == 0L, x$inference == 0L)
tar <- file.path(b, 'readiness-build/relm_0.4.0.tar.gz')
dest <- file.path(b, 'readiness-description'); dir.create(dest)
utils::untar(tar, files='relm/DESCRIPTION', exdir=dest)
original <- read.dcf('rebirth/DESCRIPTION'); generated <- read.dcf(file.path(dest, 'relm/DESCRIPTION'))
stopifnot(identical(unname(original), unname(generated[, colnames(original), drop=FALSE])))
cat('RAW_RDS_OK functions=250 registered=33 hooks=0 profile=27 loads=0 inference=0\n')
cat('DESCRIPTION original_fields=', ncol(original), ' build_fields=',
    paste(setdiff(colnames(generated), colnames(original)), collapse=','), '\n', sep='')
dput(x$profile)
cat(x$session$R.version$version.string, '\n')
