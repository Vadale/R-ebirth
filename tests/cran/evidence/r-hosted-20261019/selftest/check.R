library(relm, lib.loc = "/home/grauk/Work/relm-phase9/r-hosted-wrappers/fixture-controls/selftest/library")
stopifnot(identical(relm:::rebirth_probe(17L), 17L))
stopifnot(exists('rebirth_selftest_probe', asNamespace('relm'), inherits=FALSE) == TRUE)
