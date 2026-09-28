#!/usr/bin/env Rscript
# Real filesystem races, injected exactly between enumeration and stat.
script <- sub('^--file=', '', grep('^--file=', commandArgs(FALSE), value = TRUE)[[1L]])
root <- normalizePath(file.path(dirname(script), '..', '..'), mustWork = TRUE)
source(file.path(root, 'examples', 'funding-service', 'common.R'))
source(file.path(svc_module, 'runtime.R'))

main <- function() {
  work <- tempfile('relm-ipc-scan-')
  dir.create(work, mode = '0700')
  on.exit(unlink(work, recursive = TRUE), add = TRUE)
  checks <- 0L
  check <- function(label, expression) {
    force(expression)
    checks <<- checks + 1L
    cat('PASS:', label, '\n')
  }
  expect_error <- function(expression, class) {
    result <- tryCatch(force(expression), error = identity)
    stopifnot(inherits(result, class))
  }
  fixture <- function(name, nested = FALSE) {
    path <- file.path(work, name)
    dir.create(path, mode = '0700')
    survivor <- file.path(path, 'survivor')
    writeBin(as.raw(1:3), survivor)
    parent <- if (nested) file.path(path, 'consumed') else path
    if (nested) dir.create(parent, mode = '0700')
    transient <- file.path(parent, 'transient')
    writeBin(as.raw(1:7), transient)
    list(path = path, survivor = survivor, transient = transient, parent = parent)
  }
  # Use the product closure unchanged, with local base-filesystem seams. The
  # tests neither reimplement its scanner nor modify the global base namespace.
  scanner <- function(info = base::file.info, access = base::file.access) {
    scan <- svc_tree_bytes
    environment(scan) <- list2env(list(file.info = info, file.access = access),
                                 parent = environment(svc_tree_bytes))
    scan
  }
  disappearing <- function(f, remove_parent = FALSE, unknown_ancestor = FALSE,
                            inaccessible_ancestor = FALSE) {
    removed <- FALSE
    info <- function(paths, ...) {
      if (!removed && f$transient %in% paths) {
        unlink(if (remove_parent) f$parent else f$transient, recursive = TRUE)
        removed <<- TRUE
      }
      value <- base::file.info(paths, ...)
      if (removed && unknown_ancestor) value$isdir[paths == f$path] <- NA
      value
    }
    access <- function(paths, mode = 0) {
      value <- base::file.access(paths, mode)
      if (removed && inaccessible_ancestor) value[paths == f$path] <- -1L
      value
    }
    scanner(info, access)
  }

  f <- fixture('stable')
  check('stable IPC and durable totals use actual bytes', {
    stopifnot(svc_tree_bytes(f$path, live_ipc = TRUE) == 10,
              svc_tree_bytes(f$path) == 10)
  })
  f <- fixture('live-removal')
  check('confirmed live IPC disappearance preserves surviving bytes', {
    stopifnot(disappearing(f)(f$path, live_ipc = TRUE) == 3,
              !file.exists(f$transient), file.info(f$survivor)$size == 3)
  })
  f <- fixture('durable-removal')
  check('durable disappearance remains a filesystem error', {
    expect_error(disappearing(f)(f$path), 'funding_error_filesystem')
    stopifnot(!file.exists(f$transient))
  })
  f <- fixture('nested-removal', nested = TRUE)
  check('consumed IPC subdirectory needs an accessible containing ancestor', {
    stopifnot(disappearing(f, remove_parent = TRUE)(f$path, live_ipc = TRUE) == 3,
              !dir.exists(f$parent))
  })
  f <- fixture('existing-unstatable')
  info <- function(paths, ...) {
    value <- base::file.info(paths, ...)
    value$size[paths == f$transient] <- NA
    value
  }
  check('still-existing unstatable IPC file fails closed', {
    expect_error(scanner(info)(f$path, live_ipc = TRUE), 'funding_error_ipc')
    stopifnot(file.exists(f$transient))
  })
  f <- fixture('unknown-ancestor')
  check('unknown containing ancestor is not proof of deletion', {
    expect_error(disappearing(f, unknown_ancestor = TRUE)(f$path, live_ipc = TRUE),
                 'funding_error_ipc')
  })
  f <- fixture('inaccessible-ancestor')
  check('inaccessible containing ancestor is not proof of deletion', {
    expect_error(disappearing(f, inaccessible_ancestor = TRUE)(f$path, live_ipc = TRUE),
                 'funding_error_ipc')
  })
  f <- fixture('file-symlink')
  stopifnot(file.symlink(f$survivor, file.path(f$path, 'alias')))
  check('file symlinks are refused in both scanning modes', {
    expect_error(svc_tree_bytes(f$path, live_ipc = TRUE), 'funding_error_filesystem')
    expect_error(svc_tree_bytes(f$path), 'funding_error_filesystem')
  })
  f <- fixture('directory-symlink')
  outside <- file.path(work, 'outside')
  dir.create(outside, mode = '0700')
  writeBin(as.raw(1:5), file.path(outside, 'foreign'))
  stopifnot(file.symlink(outside, file.path(f$path, 'alias')))
  check('directory symlinks are refused in both scanning modes', {
    expect_error(svc_tree_bytes(f$path, live_ipc = TRUE), 'funding_error_filesystem')
    expect_error(svc_tree_bytes(f$path), 'funding_error_filesystem')
  })
  cat(sprintf('PASS: %d IPC scanner regressions; no model or HTTP process started\n', checks))
}
main()
