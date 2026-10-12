args <- commandArgs(TRUE)
library(relm)
stopifnot(identical(normalizePath(find.package("relm")), normalizePath(args[[1]])),
  identical(as.character(packageVersion("relm")), "0.4.0"))
ns <- asNamespace("relm")
src <- new.env(parent = ns)
for (p in sort(list.files(file.path(args[[2]], "R"), full.names = TRUE))) sys.source(p, src)
funs <- Filter(function(n) is.function(src[[n]]), ls(src, all.names = TRUE))
for (n in funs) stopifnot(exists(n, ns, inherits = FALSE),
  identical(body(src[[n]]), body(ns[[n]])), identical(formals(src[[n]]), formals(ns[[n]])))
codetools::checkUsagePackage("relm")
routines <- names(getDLLRegisteredRoutines("relm")[[".Call"]])
stopifnot(!any(grepl("^wrap__rebirth_(selftest_|async_test_)", routines)))
profile <- relm:::rebirth_projection_allocation_profile()
stopifnot(identical(profile, readRDS("/private/tmp/relm-maintenance-040/builds-20261011-180737/production/compiled-profile.rds")))
saveRDS(list(version = packageVersion("relm"), library = find.package("relm"),
  functions = funs, routines = routines, profile = profile,
  session = sessionInfo()), file.path(args[[3]], "installed-receipt.rds"))
cat("RELEASE_INSTALLED_OK functions=", length(funs), " fixtures=0 version=0.4.0\n", sep = "")
print(profile)
print(sessionInfo())
