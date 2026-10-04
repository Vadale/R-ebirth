live_steering_specs <- function() list(list(kind = "steer", layer = 2L, direction = c(0.25, -0.5), coef = 0, positions = "all"), list(kind = "ablate", layer = 2L, neurons = 1L, value = 0.125, component = "residual"), list(kind = "steer", layer = 2L, direction = c(-0.125, 0.25), coef = 0.5, positions = "all"))
live_steering_reply <- function(intervention, coef) {
    list(steer = data.frame(intervention = intervention, coef = coef))
}
live_steering_metadata <- function(m) {
    serialize(m[setdiff(names(m), c("ptr", "state"))], NULL, version = 2)
}
live_steering_audit <- function(state, indices, layers, coefs, revision, after, effective) {
    expect_identical(names(state), c("step", "logits", "trace"))
    columns <- c("steering_revision", "applied_after_state", "effective_source_pos")
    expect_identical(tail(names(state$step), 4L), c("elapsed", columns))
    expect_identical(unname(vapply(state$step[columns], typeof, character(1))), rep("integer", 3L))
    expect_identical(state$step$steering_revision, as.integer(revision))
    expect_identical(state$step$applied_after_state, as.integer(after))
    expect_identical(state$step$effective_source_pos, as.integer(effective))
    audit <- attr(state, "steering", exact = TRUE)
    expect_identical(class(audit), "data.frame")
    expect_identical(names(audit), c("intervention", "layer", "coef"))
    expect_identical(unname(vapply(audit, typeof, character(1))), c("integer", "integer", "double"))
    expect_identical(audit$intervention, as.integer(indices))
    expect_identical(audit$layer, as.integer(layers))
    expect_identical(audit$coef, as.double(coefs))
    invisible(audit)
}
test_that("[MODEL] live steering audits partial zero and unchanged updates with ablation", {
    m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
    on.exit(close(m), add = TRUE)
    first <- llm_steer(m, 2L, rep(0.02, m$hidden_size), coef = 0)
    on.exit(close(first), add = TRUE)
    ablated <- llm_ablate(first, 2L, 1L, value = 0.125)
    on.exit(close(ablated), add = TRUE)
    d <- llm_steer(ablated, 2L, rep(c(0.01, -0.01), length.out = m$hidden_size), coef = 0.5)
    on.exit(close(d), add = TRUE)
    close(first)
    close(ablated)
    original <- live_steering_metadata(d)
    original_base <- live_steering_metadata(m)
    old <- options(relm.trace_budget = 128 * 1024)
    on.exit(options(old), add = TRUE)
    prompt <- "1, 2, 3, 4, 5, 6, 7, 8, 9, 10,"
    baseline <- llm_generate(d, prompt, chat = FALSE, max_tokens = 6L, temperature = 0, seed = 617)
    states <- list()
    coefficients <- list(c(0, 0.5), c(1, 0.5), c(1, 0), c(0, 0), c(0, 0), c(0, 0))
    revisions <- c(0L, 1L, 2L, 3L, 3L, 3L)
    after <- c(0L, 1L, 2L, 3L, 3L, 3L)
    observed <- stream_test_observe(llm_generate(d, prompt, chat = FALSE, max_tokens = 6L, temperature = 0, seed = 617, async = TRUE, layers = 2L, top = 3L, spill = FALSE, on_state = function(state) {
        k <- length(states) + 1L
        states[[k]] <<- state
        p <- attr(state$trace, "prompt_token_count")
        live_steering_audit(state, c(1L, 3L), c(2L, 2L), coefficients[[k]], revisions[[k]], after[[k]], if (k == 1L) 
            1L
        else p + after[[k]])
        expect_identical(as.matrix(state$trace, layer = 2L)[1L, 1L], 0.125)
        expect_lte(as.numeric(object.size(state)), 128 * 1024)
        expect_lte(as.numeric(object.size(state)), relm:::.relm_async$job$live$estimate$materialized_bytes)
        expect_identical(live_steering_metadata(d), original)
        switch(k, live_steering_reply(1L, 1), live_steering_reply(3L, 0), live_steering_reply(c(1L, 3L), c(0, 0)), live_steering_reply(1L, 0), live_steering_reply(integer(), double()), NULL)
    }))
    {
        stream_test_wait(observed, timeout = 120)
        saveRDS(list(error = observed$error, states = states), file.path(Sys.getenv("RELM_F6B_EVIDENCE"), "callback-diagnostic.rds"))
        if (!is.null(observed$error)) {
            print(observed$error)
            print(observed$error$parent)
            str(observed$error)
        }
    }
    expect_null(observed$error)
    expect_length(states, 6L)
    expect_identical(observed$settlements, 1L)
    expect_identical(attr(observed$value, "seed"), attr(baseline, "seed"))
    expect_identical(live_steering_metadata(d), original)
    expect_identical(live_steering_metadata(m), original_base)
    expect_identical(llm_generate(d, prompt, chat = FALSE, max_tokens = 6L, temperature = 0, seed = 617), baseline)
    expect_null(relm:::.relm_async$job)
})
