# Local start check before a deploy (2026-10-02): serve dashboard_app/ on a local port so the page can be requested
# with curl. Stop it with TaskStop / by killing the process once checked.
#   Rscript _working_files/scripts/run_app_local.R
shiny::runApp("dashboard_app", port = 8765, launch.browser = FALSE, host = "127.0.0.1")
