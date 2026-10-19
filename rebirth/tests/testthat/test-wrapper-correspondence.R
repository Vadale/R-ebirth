# Ordinary production and selftest R package CI; no model or inference.
test_that("installed wrappers match the loaded DLL metadata exactly", {
  symbol <- getNativeSymbolInfo("wrap__make_relm_wrappers", PACKAGE = "relm")
  generated <- .Call(symbol, TRUE, "relm")
  expected <- new.env(parent = baseenv())
  eval(parse(text = generated), expected)
  ns <- asNamespace("relm")
  names <- ls(expected, all.names = TRUE)
  expect_true(length(names) >= 31L)
  for (name in names) {
    expect_true(exists(name, ns, inherits = FALSE), info = name)
    expect_identical(formals(ns[[name]]), formals(expected[[name]]), info = name)
    expect_identical(body(ns[[name]]), body(expected[[name]]), info = name)
  }
  actual <- grep("^rebirth_", ls(ns, all.names = TRUE), value = TRUE)
  # Internal native wrappers, including explicitly enabled fixtures, are the
  # entire rebirth_* namespace; public R functions use llm_* instead.
  expect_setequal(actual, names)
})
