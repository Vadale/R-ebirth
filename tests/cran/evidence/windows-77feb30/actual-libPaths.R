function (new, include.site = TRUE) 
{
    if (!missing(new)) {
        new <- Sys.glob(path.expand(new))
        paths <- c(new, if (include.site) .Library.site, .Library)
        paths <- paths[dir.exists(paths)]
        .lib.loc <<- unique(normalizePath(paths, "/"))
    }
    else .lib.loc
}
