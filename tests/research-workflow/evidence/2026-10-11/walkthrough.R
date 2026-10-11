source("examples/research-workflow/run.R")
expected <- "452eb8eb3b4e5257dffa772c26732dd8352c9db9bb0a6dea6a3637c7a66866f8"
loadNamespace("relm")
dll <- getLoadedDLLs()[["relm"]][["path"]]
stopifnot(unname(tools::sha256sum(dll)) == expected)
cat("PARENT_INSTALLED_DLL", expected, "\n")
run_research_workflow(
  "/Users/alessandrovadala/models/qwen2.5-0.5b-instruct-q8_0.gguf",
  "/private/tmp/relm-phase7/walkthrough-output",
  "b10828-patched-D039-D040")
cat("RESEARCH_WORKFLOW_COMPLETE\n")
