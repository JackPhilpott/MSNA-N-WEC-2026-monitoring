# run_logged.R - runs one R script with everything it prints going to the console AND a log file, its warnings and
# errors to the log, and exits 0 if it finished or 1 if it stopped with an error (the error and the calls that led to
# it are written at the end of the log). Used by run_refresh_and_deploy.R so each phase leaves a complete log behind.
#   Rscript scripts/shared/run_logged.R <log_file> <script.R>
# The working directory is wherever Rscript was started (run_refresh_and_deploy.R starts it in 2_monitoring/).
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  cat("usage: Rscript scripts/shared/run_logged.R <log_file> <script.R>\n")
  quit(status = 2, save = "no")
}
log_file <- args[1]
script <- args[2]
con <- file(log_file, open = "wt")
sink(con, split = TRUE)
sink(con, type = "message")
cat(sprintf("== %s | running %s in %s ==\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), script, getwd()))
status <- tryCatch(
  withCallingHandlers(
    {
      source(script, echo = FALSE)
      0L
    },
    error = function(e) {
      calls <- vapply(utils::tail(sys.calls(), 12), function(x) paste(deparse(x, nlines = 1L), collapse = " "), character(1))
      cat("\n== ERROR in", script, ":", conditionMessage(e), "==\nlast calls:\n", paste0("  ", calls, "\n"), file = con)
    }
  ),
  error = function(e) 1L
)
cat(sprintf("== %s | %s %s ==\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), script, if (status == 0L) "FINISHED" else "STOPPED WITH AN ERROR"))
sink(type = "message")
sink()
close(con)
quit(status = status, save = "no")
