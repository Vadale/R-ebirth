test_that("projection state provenance uses a weak fixed-name environment", {
  ptr <- relm:::rebirth_selftest_new_handle()
  state <- relm:::relm_check(relm:::rebirth_model_state(ptr))
  expect_true(environmentIsLocked(state))
  expect_identical(sort(ls(state, all.names = TRUE)), c("closed", "ptr"))
  expect_identical(parent.env(state), emptyenv())
  expect_null(env.profile(state))
  expected <- list(hash_slots = 0, bindings = 2, c_finalizer_bytes = as.double(.Machine$sizeof.pointer))
  expect_identical(relm:::rebirth_projection_state_facts(state, ptr), expected)
  state$closed <- TRUE
  expect_identical(relm:::rebirth_projection_state_facts(state, ptr), expected)
  expect_error(state$extra <- 1, "locked", fixed = TRUE)
  expect_error(rm("ptr", envir = state), "locked", fixed = TRUE)
  expect_error(relm:::relm_check(relm:::rebirth_model_state(ptr)), class = "relm_error_intervention")
  finalized <- FALSE
  reg.finalizer(state, function(e) { finalized <<- TRUE }, onexit = FALSE)
  rm(state)
  invisible(gc()); invisible(gc())
  expect_true(finalized) # ptr remains rooted; its proof must not retain the state.
})

test_that("projection state query refuses forged and lazy bindings before evaluation", {
  ptr <- relm:::rebirth_selftest_new_handle()
  state <- relm:::relm_check(relm:::rebirth_model_state(ptr))
  refuse <- function(e, p = ptr) expect_error(
    relm:::relm_check(relm:::rebirth_projection_state_facts(e, p)), class = "relm_error_intervention")
  for (hash in c(FALSE, TRUE)) {
    forged <- new.env(hash = hash, size = 10007L, parent = emptyenv())
    forged$ptr <- ptr; forged$closed <- FALSE; lockEnvironment(forged)
    refuse(forged)
  }
  delayedAssign("closed", stop("promise must not run"), assign.env = state)
  refuse(state)
  state$closed <- FALSE
  delayedAssign("ptr", stop("pointer promise must not run"), assign.env = state)
  refuse(state)
  state$ptr <- ptr
  other <- relm:::rebirth_selftest_new_handle()
  refuse(state, other)
  for (value in list(NA, 0L, logical(), c(FALSE, TRUE), structure(FALSE, x = 1L))) {
    state$closed <- value; refuse(state)
  }
  state$closed <- FALSE
  attr(state, "x") <- 1L; refuse(state); attr(state, "x") <- NULL
  parent.env(state) <- globalenv(); refuse(state); parent.env(state) <- emptyenv()
})

test_that("projection state inventory charges all three actual weak references", {
  facts <- list(hash_slots = 0, bindings = 2, c_finalizer_bytes = as.double(.Machine$sizeof.pointer))
  node <- as.double(object.size(pairlist(NULL)))
  weak <- as.double(object.size(vector("list", 4L)))
  expected <- 2 * node + 2 * as.double(object.size(as.name("ptr"))) +
    as.double(object.size(FALSE)) + 3 * weak + relm:::live_r_vector_bytes(facts$c_finalizer_bytes)
  expect_identical(relm:::projection_state_bytes(facts), expected)
})
