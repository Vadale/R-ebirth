# Focused configure-only coverage for the R compiler/portable build contract.
# Reuse the existing fixture function without replaying source extraction tests.
expressions <- parse('tests/cran/configuration.R')
assignment <- Filter(function(x) is.call(x) && identical(x[[1L]], as.name('<-')) &&
                     identical(x[[2L]], as.name('configure_case')), as.list(expressions))
stopifnot(length(assignment) == 1L)
repo <- normalizePath('.', winslash = '/')
root <- tempfile('relm-portable-config-'); dir.create(root)
eval(assignment[[1L]])
for (windows in c(FALSE, TRUE)) {
  config <- configure_case(TRUE, 'false', windows)
  stopifnot(is.environment(config),
    grepl('RELM_R_PORTABLE=1', config$.native_build_env, fixed = TRUE),
    grepl('CC="$(CC)" CXX="$(CXX17)"', config$.native_build_env, fixed = TRUE),
    grepl('$(CXX17FLAGS) $(CXX17PICFLAGS) $(CXX17STD)', config$.native_build_env, fixed = TRUE),
    sum(grepl('export CMAKE=', config$new_txt, fixed = TRUE)) == 2L,
    !any(grepl('@NATIVE_BUILD_ENV@', config$new_txt, fixed = TRUE)))
}
# Exercise the real Unix make/shell path, including space-bearing tool paths and
# exact R compiler flags, without invoking Cargo or any compiler.
makefile <- file.path(root, 'env.mk')
flags <- '-O1 -g -fPIC -DRELM_CONTROL=17'
writeLines(c('CC = cc', 'CXX17 = c++', paste('CFLAGS =', flags), 'CPPFLAGS =',
 'CPICFLAGS =', paste('CXX17FLAGS =', flags), 'CXX17PICFLAGS =', 'CXX17STD = -std=gnu++17',
 'all:', paste0('\t@export ', config$.native_build_env, '; ',
 'test "$$RELM_R_PORTABLE" = 1 && test "$$CC" = cc && ',
 'test "$$CXX" = c++ && test "$$CFLAGS" = " ', flags, ' " && ',
 'test "$$CXXFLAGS" = " ', flags, '  -std=gnu++17"')), makefile)
if (.Platform$OS.type != 'windows') stopifnot(system2('make', c('-f', shQuote(makefile))) == 0L)
unlink(root, recursive = TRUE)
cat('CRAN_NATIVE_CONFIG_OK platforms=2 cargo_commands=4 model_calls=0 native_compiles=0\n')
