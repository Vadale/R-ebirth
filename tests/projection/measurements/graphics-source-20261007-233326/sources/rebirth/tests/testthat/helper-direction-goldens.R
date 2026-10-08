# Independent Python/Decimal fixtures, copied byte-for-byte into package tests.
direction_csv <- function(name) {
  read.csv(testthat::test_path("fixtures", "directions", name),
    colClasses = "character", check.names = FALSE, stringsAsFactors = FALSE)
}

direction_hex <- function(x) {
  if (!nzchar(x)) return(raw())
  starts <- seq.int(1L, nchar(x), by = 2L)
  as.raw(strtoi(substring(x, starts, starts + 1L), base = 16L))
}

direction_fixture_nodes <- function(case, fixture = "directions") {
  nodes <- read.csv(testthat::test_path("fixtures", fixture, "encoding-fields.csv"),
    colClasses = "character", check.names = FALSE, stringsAsFactors = FALSE)
  nodes <- nodes[nodes$case == case, , drop = FALSE]
  read_node <- function(path) {
    row <- nodes[nodes$path == path, , drop = FALSE]
    stopifnot(nrow(row) == 1L)
    kind <- row$kind
    if (kind == "N") return(NULL)
    if (kind %in% c("L", "I", "D", "S")) {
      bytes <- direction_hex(row$scalar_hex)
      if (kind == "L") return(as.logical(bytes))
      if (kind == "S") { text <- rawToChar(bytes); Encoding(text) <- "UTF-8"; return(text) }
      return(readBin(bytes, if (kind == "I") "integer" else "double", n = 1L,
        size = if (kind == "I") 4L else 8L, endian = "little"))
    }
    children <- nodes[dirname(nodes$path) == if (nzchar(path)) path else "/", , drop = FALSE]
    # Root itself has empty path and must never become its own child.
    children <- children[nzchar(children$path) & children$path != path, , drop = FALSE]
    values <- lapply(children$path, read_node)
    if (kind %in% c("l", "i", "d", "s")) {
      zero <- switch(kind, l = logical(), i = integer(), d = double(), s = character())
      return(if (length(values)) unlist(values, use.names = FALSE) else zero)
    }
    names(values) <- children$field
    if (kind == "R") return(values)
    if (kind == "F") return(structure(values, class = "data.frame", row.names = .set_row_names(as.integer(row$nrow))))
    if (kind == "M") return(matrix(values$values, as.integer(row$nrow), as.integer(row$ncol),
      byrow = TRUE, dimnames = list(values$row_names, values$column_names)))
    stop("Unknown independent fixture kind")
  }
  list(value = read_node(""), vector = nodes$kind[1L] %in% c("l", "i", "d", "s"))
}
