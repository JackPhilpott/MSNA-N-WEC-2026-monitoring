# ==============================================================================
# project_root.R - finds the 2_monitoring project on ANY machine / Windows
# account, defines MONITORING_DIR (= PROJECT_DIR) and WORKSPACE_DIR, and
# setwd()s into 2_monitoring.
#
# ADDED 2026-09-11 as the single shared copy of the project's absolute path.
# REWRITTEN 2026-10-04 (Jack: the refresh + deploy chain moves to the data
# officer's own laptop): no hard-coded C:/Users/<name>/... path any more.
# Order:
#   1. MSNA_WORKSPACE environment variable - the workspace folder that holds
#      1_sampling/ and 2_monitoring/ (pointing it at 2_monitoring itself also
#      works). If it is set but holds no 2_monitoring, this STOPS rather than
#      quietly using some other copy of the project.
#   2. Auto-detect: walk up from the location of the script being run (when R
#      knows it - source() or Rscript), then from the working directory, to
#      the first folder that is 2_monitoring (holds deploy_dashboard.R and
#      dashboard_app/) or holds it.
# Jack's machine keeps working unchanged: everything here already runs from
# inside the workspace.
#
# From a script that may start with ANY working directory, find this file
# first with the same walk-up (no absolute path anywhere):
#   source((function() {  # 2_monitoring's project_root.R on any machine (MSNA_WORKSPACE, else walk up)
#     d <- normalizePath(Sys.getenv("MSNA_WORKSPACE", getwd()), winslash = "/", mustWork = FALSE)
#     repeat {
#       for (p in file.path(d, c(".", "2_monitoring"), "scripts/shared/project_root.R")) if (file.exists(p)) return(p)
#       if (dirname(d) == d) stop("can't find 2_monitoring - set MSNA_WORKSPACE to the folder holding it")
#       d <- dirname(d)
#     }
#   })())
# ==============================================================================

.msna_is_monitoring <- function(d) {
  file.exists(file.path(d, "deploy_dashboard.R")) && dir.exists(file.path(d, "dashboard_app"))
}

.msna_find_monitoring_dir <- function(start) {
  if (!nzchar(start) || !dir.exists(start)) return(NA_character_)
  d <- normalizePath(start, winslash = "/")
  repeat {
    for (cand in c(d, file.path(d, "2_monitoring"))) if (.msna_is_monitoring(cand)) return(normalizePath(cand, winslash = "/"))
    if (dirname(d) == d) return(NA_character_)
    d <- dirname(d)
  }
}

local({
  ws <- Sys.getenv("MSNA_WORKSPACE")
  if (nzchar(ws)) {
    found <- .msna_find_monitoring_dir(ws)
    if (is.na(found) || !(found %in% normalizePath(c(ws, file.path(ws, "2_monitoring")), winslash = "/", mustWork = FALSE))) {
      stop("project_root.R: MSNA_WORKSPACE is set to '", ws, "', which holds no 2_monitoring project ",
           "(a folder with deploy_dashboard.R and dashboard_app/). Point it at the folder holding 1_sampling/ and 2_monitoring/, ",
           "or unset it to auto-detect.")
    }
  } else {
    this_file <- NULL
    for (i in rev(seq_len(sys.nframe()))) {
      f <- sys.frame(i)$ofile
      if (!is.null(f)) { this_file <- f; break }
    }
    rscript_file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
    starts <- c(if (!is.null(this_file)) dirname(this_file), if (length(rscript_file)) dirname(rscript_file[1]), getwd())
    found <- NA_character_
    for (s in starts) {
      found <- .msna_find_monitoring_dir(s)
      if (!is.na(found)) break
    }
    if (is.na(found)) {
      stop("project_root.R: can't find the 2_monitoring project from '", getwd(), "'. Set the MSNA_WORKSPACE environment ",
           "variable to the folder holding 1_sampling/ and 2_monitoring/ (e.g. in a .Renviron line MSNA_WORKSPACE=C:/path/to/MSNA N-WEC 2026).")
    }
  }
  assign("MONITORING_DIR", found, envir = globalenv())
  assign("PROJECT_DIR", found, envir = globalenv())
  assign("WORKSPACE_DIR", dirname(found), envir = globalenv())
})
setwd(PROJECT_DIR)
