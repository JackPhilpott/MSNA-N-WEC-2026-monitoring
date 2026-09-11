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

# 2026-09-09 (Jack, via cross-session flag from msna-n-wec-2026-80): neither
# of these was ever called from anywhere automated (confirmed by grepping the
# whole workspace) - PIPELINE_AUDIT_2026-09-07.md already flagged this the
# night before the 2026-09-08 rebuild, still open until now. In practice this
# was only ever correct because someone happened to rerun build_confirmed_
# deletions_overlay.R by hand after a recovery-tracker change and before the
# next deploy - the next resolution that wasn't followed by a manual rerun
# would have silently gone stale (a recovered interview staying excluded from
# Achieved forever, or a freshly no-appeal-confirmed one never reaching the
# resampling-facing overlay).
#
# RETIRED 2026-09-11 (Jack, explicit decision): this step used to also
# source register_deletion_log_issues.R here first (wiring the DO's daily
# deletion log into the tracker) - removed entirely. The DO's deletion log
# has real, evidenced under-flagging (no_consent alone missed 11 of 31 real
# refusals) traced to a structural flaw - each day's log file is a
# permanent, never-regenerated snapshot, so one incomplete day's run is
# unrecoverable in every later day's file too. By 2026-09-11 all six
# reasons it could emit had already been independently replaced below, and
# its one remaining live job (a one-time legacy CONFIRMED_QUALITY_
# EXCLUSIONS.csv bridge) had already fully executed - verified before
# retiring, nothing is lost. Script moved to reports/partner_data_recovery/
# scripts/_archive/2026-09-11_do_log_ingestion_retired/ (not deleted) if
# this ever needs reviving. The old circular-dependency ordering note this
# comment used to carry (about register_deletion_log_issues.R needing
# today's real_submissions.csv) no longer applies with it gone.
source("cleaning/real/independent_deletion_checks.R")
# Order matches the DO's own reason priority (no_consent > duration_under_20 >
# duplicate_point > ...) - register_issues() only sets deletion_reason on a
# row's first insert (issue_tracker.R), so a uuid tripping more than one check
# must see the higher-priority one register first, or a lower-priority reason
# could win the race. See that file's own header for duplicate_point's
# key-based-only scope and the still-open GPS-proximity question.
run_independent_no_consent_check()
run_independent_duration_check()
run_independent_duplicate_check()
run_independent_listing_missing_check()
run_independent_percentage_missing_check()
source("cleaning/real/build_confirmed_deletions_overlay.R")

source("cleaning/real/sanity_checks.R")
print_sanity_banner_if_present() # most important checkpoint: right before this goes live and public

# ---- report generation, before the deploy itself — same freshly-refreshed data, one run ----
source("generate_partner_digest.R")

# 2026-09-08 (Jack): accessibility + sampling-frame mirrors were both found
# stuck on stale versions (accessibility's own stamp file claimed 09-03 data
# three days after a rebuild; input_data/sampling_frame/ was stuck on v5/v6
# while 1_sampling had already moved to v7 — Dandume/Faskari were missing
# from the LGA dropdown as a direct result). Root cause: propagating from
# 1_sampling had always been a manual "someone copies the files" step with
# nothing in code enforcing it — happened again despite a sync script
# already existing (sync_accessibility_mirrors.R), because that script was
# never actually wired into anything, contrary to its own header comment's
# claim. Fixed generically here rather than patched again as a one-off:
# both scripts live in 1_sampling (they read its output/ as source of
# truth) and each setwd()s there as a side effect of being sourced, so
# restore this script's own working directory immediately after each call —
# everything below this block still expects cwd = 2_monitoring project root.
.deploy_root_wd <- getwd()
source("../1_sampling/resampling/scripts/sync_accessibility_mirrors.R")
sync_accessibility_mirrors()
setwd(.deploy_root_wd)
source("../1_sampling/resampling/scripts/sync_sampling_frame_mirrors.R")
sync_sampling_frame_mirrors()
setwd(.deploy_root_wd)

# 2026-09-08: bundling step extracted to scripts/shared/bundle_dashboard_
# mirrors.R so it can also run standalone (assert_fresh-triggered, between
# full deploys) instead of only ever happening as a side effect of this
# whole heavier sequence - see that file's header for why.
source("scripts/shared/bundle_dashboard_mirrors.R")
bundle_dashboard_mirrors(".")

deployApp(
  appDir = "dashboard_app",
  appName = "dashboard_app",
  account = "impact-nga-jp",
  forceUpdate = TRUE
)
