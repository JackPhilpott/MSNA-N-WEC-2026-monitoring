# Deploys dashboard_app/ to shinyapps.io.
#
# shinyapps.io only bundles the app directory itself (dashboard_app/), not
# sibling folders — but the app reads its data from ../data and
# ../input_data (see the data-handoff convention in README.md, and
# global.R's DATA_DIR/INPUT_DIR). So this script copies both INTO
# dashboard_app/ first (dashboard_app/data/, dashboard_app/input_data/ —
# already gitignored, same rule that covers the top-level folders), then
# deploys. This is what was missing the first time: the deployed app
# errored on startup with "'../data/mock_submissions.csv' does not exist"
# (see `rsconnect::showLogs(appName = "dashboard_app")`).
#
# Run from this file's location (2_monitoring/ project root):
#   source("deploy_dashboard.R")
#
# Requires a shinyapps.io account already linked via
# rsconnect::setAccountInfo(name=, token=, secret=) — already done on this
# machine for account "impact-nga-jp" (see dashboard_app/rsconnect/, which
# is itself gitignored as it's machine-specific).

library(rsconnect)

for (d in c("dashboard_app/data", "dashboard_app/input_data")) {
  if (dir.exists(d)) unlink(d, recursive = TRUE)
}
dir.create("dashboard_app/data")
dir.create("dashboard_app/input_data")
file.copy(list.files("data", full.names = TRUE), "dashboard_app/data", recursive = TRUE)
file.copy(list.files("input_data", full.names = TRUE), "dashboard_app/input_data", recursive = TRUE)

cat("Bundled data/ (", sum(file.info(list.files("dashboard_app/data", recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE) %/% 1e6,
    "MB) and input_data/ (", sum(file.info(list.files("dashboard_app/input_data", recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE) %/% 1e6,
    "MB) into dashboard_app/\n", sep = "")

deployApp(
  appDir = "dashboard_app",
  appName = "dashboard_app",
  account = "impact-nga-jp",
  forceUpdate = TRUE
)
