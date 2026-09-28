#!/usr/bin/env Rscript
# Generate a user-level supervisor definition; never install/start it implicitly.
script <- sub('^--file=', '', grep('^--file=', commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(normalizePath(script)), 'common.R'))
app_cli({
  Sys.umask('0077')
  args <- app_options(commandArgs(TRUE), c('manager', 'name', 'environment', 'store', 'output', 'port'))
  if (!all(c('manager', 'name', 'environment', 'store', 'output') %in% names(args)))
    app_abort('Supply --manager, --name, --environment, --store and --output.')
  if (!args$manager %in% c('launchd', 'systemd-user')) app_abort('Choose launchd or systemd-user.')
  if (!grepl('^[A-Za-z][A-Za-z0-9_.-]{0,63}$', args$name)) app_abort('Invalid supervisor name.')
  environment <- normalizePath(args$environment, mustWork = TRUE)
  svc_library(file.path(environment, 'library'))
  parent <- dirname(path.expand(args$store))
  dir.create(parent, recursive = TRUE, showWarnings = FALSE, mode = '0700')
  store <- file.path(normalizePath(parent, mustWork = TRUE), basename(args$store))
  if (any(grepl('[[:cntrl:]]', c(environment, store, svc_module)))) app_abort('Control characters are not supported in supervisor paths.')
  port <- if (is.null(args$port)) 8765L else app_integer(as.numeric(args$port), 'port', 1024L, 65535L)
  rscript <- normalizePath(Sys.which('Rscript'), mustWork = TRUE)
  start <- c(rscript, '--vanilla', file.path(svc_module, 'start.R'), '--environment', environment, '--store', store, '--port', as.character(port))
  stop <- c(rscript, '--vanilla', file.path(svc_module, 'stop.R'), '--environment', environment, '--store', store)
  if (args$manager == 'launchd') {
    xml <- function(x) {
      x <- gsub('&', '&amp;', x, fixed = TRUE)
      x <- gsub('<', '&lt;', x, fixed = TRUE)
      gsub('>', '&gt;', x, fixed = TRUE)
    }
    body <- c('<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0"><dict>', paste0('<key>Label</key><string>', xml(args$name), '</string>'),
      '<key>ProgramArguments</key><array>', paste0('<string>', xml(start), '</string>'), '</array>',
      '<key>RunAtLoad</key><true/>', '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>',
      '<key>ThrottleInterval</key><integer>5</integer>', '<key>ExitTimeOut</key><integer>15</integer>',
      '<key>AbandonProcessGroup</key><false/>', '<key>ProcessType</key><string>Background</string>',
      '<key>Umask</key><integer>63</integer>', '</dict></plist>')
  } else {
    quote_arg <- function(x) vapply(x, function(s) app_canonical(gsub('$', '$$', gsub('%', '%%', s, fixed = TRUE), fixed = TRUE)), '')
    body <- c('[Unit]', 'Description=relm local funding extraction', 'StartLimitIntervalSec=300', 'StartLimitBurst=3',
      '', '[Service]', 'Type=exec', paste0('ExecStart=', paste(quote_arg(start), collapse = ' ')),
      paste0('ExecStop=', paste(quote_arg(stop), collapse = ' ')), 'Restart=on-failure', 'RestartSec=5',
      'KillMode=control-group', 'TimeoutStopSec=15', 'UMask=0077', 'StandardOutput=null', 'StandardError=null',
      '', '[Install]', 'WantedBy=default.target')
  }
  app_no_symlink(args$output)
  if (file.exists(args$output)) app_abort('Supervisor output exists; choose a new file.')
  writeLines(body, args$output, useBytes = TRUE)
  Sys.chmod(args$output, '0600')
  cat('Supervisor definition written:', normalizePath(args$output), '\n')
})
