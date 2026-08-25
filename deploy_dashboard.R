# Deploys dashboard_app/ to shinyapps.io — AND refreshes submissions from
# the latest raw export, AND regenerates the partner data quality digest
# (reports/), all as part of the same run. Refresh step added 2026-08-24
# after a redeploy went out still showing 21 Aug data despite a newer
# anonymised export (23 Aug) already sitting in cleaning/MSNA_Data_
# Cleaning/output/anonymised_data/ — confirmed with Jack: "redeploy" should
# always mean go back to the submission data and cleaning logs for
# whatever's currently there, not just re-push whatever data/
# real_submissions.csv already happens to contain. Same reasoning as the
# 2026-08-21d report integration: these are all downstream of the same
# daily refresh and inherently linked, not three separate things to
# remember to run in order. To refresh/report without deploying, run
# cleaning/real/prep_real_submissions.R and/or generate_partner_digest.R
# directly instead.
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

# ---- refresh submissions from whatever's currently in cleaning/ (picks up
# the latest anonymised export + all cleaning logs) — always the first
# step, per Jack: "redeploy" means go back to source, not re-push
# whatever data/real_submissions.csv already has sitting in it. Prints its
# own sanity banner at both start and end.
source("cleaning/real/prep_real_submissions.R")

source("cleaning/real/sanity_checks.R")
print_sanity_banner_if_present() # most important checkpoint: right before this goes live and public

# ---- report generation, before the deploy itself — same freshly-refreshed data, one run ----
source("generate_partner_digest.R")

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
