# Real-R control for native CI and the deferred target-webR route; no models.
args <- commandArgs(TRUE)
stopifnot(length(args) == 1L)
dll <- dyn.load(args[[1L]])
probe <- function(env, name, inherits = TRUE) {
  x <- .Call("wrap__lookup_probe", env, name, inherits)
  stopifnot(identical(x$drops, 1L))
  x
}
parent <- new.env(parent = baseenv()); env <- new.env(parent = parent)
parent$x <- 11L; parent$ancestor <- 19L; env$x <- 23L; env$null <- NULL
stopifnot(identical(probe(env, "x")$value, 23L),
          identical(probe(env, "x", FALSE)$value, 23L),
          identical(probe(env, "ancestor")$value, 19L),
          identical(probe(env, "ancestor", FALSE)$status, "missing"),
          identical(probe(env, "absent")$status, "missing"),
          identical(probe(env, "absent", FALSE)$status, "missing"),
          identical(probe(env, "null")$status, "ok"),
          is.null(probe(env, "null")$value),
          identical(probe(env, "null", FALSE)$status, "ok"),
          is.null(probe(env, "null", FALSE)$value))
stopifnot(identical(.Call("wrap__lookup_raw_present", env, "ancestor", TRUE), 19L),
          identical(.Call("wrap__lookup_raw_present", env, "x", FALSE), 23L))
# Promise evaluation is a >=4.5 API behavior; old findVar returns an unforced promise.
if (getRversion() >= "4.5.0") {
  delayedAssign("good", { gc(); 31L }, assign.env = env)
  delayedAssign("bad", stop("lookup promise sentinel"), assign.env = env)
  stopifnot(identical(probe(env, "good")$value, 31L),
            identical(probe(env, "bad")$status, "error"),
            identical(probe(env, "x")$value, 23L))
}
makeActiveBinding("active", function() { gc(); c(47L, 48L)[[1L]] }, env)
makeActiveBinding("broken", function() stop("lookup active-binding sentinel"), env)
stopifnot(identical(probe(env, "active", FALSE)$value, 47L),
          identical(probe(env, "broken", FALSE)$status, "error"),
          identical(probe(env, "x", FALSE)$value, 23L))
# GC pressure exercises the sentinel and fresh active-binding result rooting.
gctorture(TRUE)
stopifnot(identical(probe(env, "active")$value, 47L),
          identical(probe(env, "absent")$status, "missing"),
          identical(probe(env, "null")$status, "ok"))
gctorture(FALSE)
cat("EXTENDR_LOOKUP_OK order inheritance shadowing missing NULL promises active_bindings drops recovery GC raw_arity models=0\n")
