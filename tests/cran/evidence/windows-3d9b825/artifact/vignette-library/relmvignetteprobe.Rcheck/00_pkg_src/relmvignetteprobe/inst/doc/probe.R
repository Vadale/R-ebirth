## -----------------------------------------------------------------------------
#| label: setup
#| include: false
# R CMD build records its installation here. Quarto on Windows can lose the
# temporary library when starting its R subprocess (quarto-r issue #217).
build_library <- Sys.getenv("R_BUILD_TEMPLIB")
if (nzchar(build_library)) .libPaths(c(build_library, .libPaths()))
if (!nzchar(find.package('relmvignetteprobe', quiet = TRUE)))
  stop('Missing probe; R_BUILD_TEMPLIB=', Sys.getenv('R_BUILD_TEMPLIB'),
       '; R_LIBS=', Sys.getenv('R_LIBS'), '; libraries=', paste(.libPaths(), collapse=';'))
library(relmvignetteprobe)
stopifnot(packageVersion('relmvignetteprobe') == '0.0.1')
run_real <- FALSE

## -----------------------------------------------------------------------------
if (run_real) stop('Optional model branch must not execute')
if (isFALSE(run_real)) cat('TEMPORARY_LIBRARY_RENDER_OK')

