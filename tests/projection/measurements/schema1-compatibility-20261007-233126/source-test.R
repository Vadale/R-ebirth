test_that("canonical R bytes exactly match all independent typed streams", 
    {
        index <- direction_csv("encoding.csv")
        for (i in seq_len(nrow(index))) {
            f <- direction_fixture_nodes(index$case[i])
            emitted <- list()
            direction_stream(index$domain[i], f$value, 
                function(chunk) {
                  expect_lte(length(chunk), 4096L)
                  emitted[[length(emitted) + 1L]] <<- chunk
                }, vector = f$vector)
            actual <- do.call(c, emitted)
            bytes <- readBin(testthat::test_path("fixtures", 
                "directions", index$binary[i]), "raw", n = as.integer(index$bytes[i]))
            expect_identical(actual, bytes, info = index$case[i])
            expect_identical(direction_hash(index$domain[i], 
                f$value, length(bytes), f$vector), index$sha256[i])
        }
    })
test_that("independent binary artifact survives full validation and rejects edits", 
    {
        payload <- direction_fixture_nodes("artifact")$value
        index <- direction_csv("encoding.csv")
        payload$direction$digests$payload <- index$sha256[index$case == 
            "artifact"]
        artifact <- structure(payload[c("neuron", "value")], 
            class = c("relm_direction", "data.frame"), row.names = .set_row_names(length(payload$value)), 
            direction = payload$direction)
        expect_identical(direction_validate(artifact)$artifact, 
            artifact)
        bad <- artifact
        attr(bad, "direction")$digests$target <- paste(rep("a", 
            64), collapse = "")
        expect_error(direction_validate(bad), class = "relm_error_intervention")
    })
