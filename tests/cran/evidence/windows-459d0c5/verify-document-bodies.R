chunks <- function(lines) {
  starts <- which(lines == '```{r}')
  lapply(starts, function(start) {
    end <- which(seq_along(lines)>start & lines=='```')[[1]]
    lines[(start+1L):(end-1L)]
  })
}
count <- 0L
for(name in c('anatomy-lab','topics-without-python','vision')) {
  path <- paste0('rebirth/vignettes/',name,'.qmd')
  before <- chunks(system2('git',c('show',paste0('HEAD:',path)),stdout=TRUE))
  after <- chunks(readLines(path))
  stopifnot(length(before)==length(after))
  for(i in seq_along(before)) {
    expr <- grep('^#\\| eval: !expr ',before[[i]],value=TRUE)
    b <- parse(text=before[[i]],keep.source=FALSE)
    a <- parse(text=after[[i]],keep.source=FALSE)
    if(length(expr)) {
      condition <- sub('^#\\| eval: !expr ','',expr)
      stopifnot(length(a)==1L, identical(a[[1L]][[1L]],as.name('if')),
        identical(a[[1L]][[2L]],parse(text=condition)[[1L]]),
        identical(as.list(a[[1L]][[3L]])[-1L],as.list(b)))
      count <- count+1L
    } else stopifnot(identical(a,b))
  }
}
for(name in c('contrast-directions','model-interventions')) {
  path <- paste0('rebirth/vignettes/',name,'.qmd')
  before <- system2('git',c('show',paste0('HEAD:',path)),stdout=TRUE)
  after <- readLines(path)
  starts <- which(after=='```{r}'); end<-which(seq_along(after)>starts[1] & after=='```')[1]
  # Removing only the inserted setup and its blank separator restores every byte-line.
  stopifnot(identical(after[-seq(starts[1],end+1L)],before))
}
cat(sprintf('DOCUMENT_BODY_PASS conditional_chunks=%d exact_conditions_and_AST=TRUE synthetic_bodies_unchanged=2 model_calls=0\n',count))
