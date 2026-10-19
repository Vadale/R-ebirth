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
    sum(grepl('export CMAKE=', config$new_txt, fixed = TRUE)) == 1L,
    !any(grepl('cargo run', config$new_txt, fixed = TRUE)),
    sum(grepl('generate-wrappers.R', config$new_txt, fixed = TRUE)) == 1L,
    !any(grepl('@RSCRIPT@', config$new_txt, fixed = TRUE)),
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
# Configure the actual templates with literal Windows paths. Discovery/version
# probing is mocked; the generated export passes through real make and sh on
# Unix, without executing CMake, Cargo, a compiler or a model.
cmake_paths <- c('C:\\rtools45\\X86_64~1.POS\\bin\\cmake.exe',
                 "C:\\tools with spaces\\owner's $tools\\cmake.exe")
for (cmake in cmake_paths) {
  for (windows in c(FALSE, TRUE)) {
    config <- configure_case(TRUE, 'false', windows, cmake = cmake)
    stopifnot(is.environment(config), identical(config$cmake_command, cmake))
    exports <- trimws(grep('export CMAKE=', config$new_txt, value = TRUE, fixed = TRUE))
    expected <- paste0('export ', config$.native_build_env, ' && \\')
    stopifnot(length(exports) == 1L, all(exports == expected))
    # The former regex replacement must fail this same byte comparison.
    old <- gsub('@NATIVE_BUILD_ENV@', config$.native_build_env, config$mv_txt)
    old_exports <- trimws(grep('export CMAKE=', old, value = TRUE, fixed = TRUE))
    stopifnot(length(old_exports) == 1L, all(old_exports != expected))
    if (.Platform$OS.type != 'windows') {
      capture <- file.path(root, 'cmake-path.txt')
      recipe <- sub(' && \\', '', exports[[1L]], fixed = TRUE)
      writeLines(c('all:', paste0('\t@', recipe, '; printf "%s" "$$CMAKE" > ',
                                 shQuote(capture))), makefile)
      stopifnot(system2('make', c('-f', shQuote(makefile))) == 0L,
                identical(readChar(capture, file.info(capture)$size, useBytes = TRUE), cmake))
    }
  }
}
unlink(root, recursive = TRUE)
cat('CRAN_NATIVE_CONFIG_OK platforms=2 cargo_commands=2 literal_paths=4 model_calls=0 native_compiles=0\n')
