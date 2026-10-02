# The deployApp() step on its own (2026-10-02) - run after _working_files/scripts/deploy_round1_staged.R has built and
# bundled everything and the local start check (run_app_local.R + smoke_test.R) has passed. Same call as the end of
# deploy_dashboard.R. Prints the bundled real_submissions md5 first, so the deployed data can be matched to the file
# the staged run verified.
#   Rscript _working_files/scripts/deploy_app_only.R
library(rsconnect)
cat("deploying bundle with real_submissions md5:", unname(tools::md5sum("dashboard_app/data/real_submissions.csv")), "\n")
deployApp(appDir = "dashboard_app", appName = "dashboard_app", account = "impact-nga-jp", forceUpdate = TRUE)
