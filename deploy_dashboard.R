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

# ---- sync 1_sampling's mirrors FIRST, before anything below reads them
# (2026-09-14, reordered — audit finding, same incident class as
# 2026-09-08 below but one level deeper). This block used to sit right
# before bundle_dashboard_mirrors()/deployApp() at the END of this
# sequence — which fixed the 2026-09-08 dropdown/target bug (see that
# block's own comment, unchanged below) but left a subtler version of the
# exact same bug: prep_real_submissions.R (next) matches submissions
# against input_data/sampling_frame/, and generate_partner_digest.R
# (further below) sources global.R, which reads the same mirrors — both
# were still running against whatever mirror was left over from the
# PREVIOUS deploy, with the fresh sync only landing afterward for the
# deployed app's own dropdowns/targets. Live evidence this was actually
# happening, not just theoretical: on 2026-09-14, submissions got matched
# ~2 minutes before the accessibility mirror sync ran, within the same
# run. Moved here so every read below this point sees the CURRENT
# 1_sampling state, not last run's.
#
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

# 2026-09-14 (live gap caught by msna-n-wec-2026-f4 mid-deploy tonight, wired
# in here per its own suggestion): cleaning/prep/prep_accessibility_layer.R —
# which actually builds input_data/accessibility/accessibility_strata_level.csv
# from 1_sampling's impact workbook, the file target_sample_representativity
# reads from — was never called from anywhere automated, sync_accessibility_
# mirrors() above covers a different, overlapping-but-not-identical set of
# files (see that script's own header). A first deploy tonight went out still
# serving a pre-drop accessibility workbook as a direct result; running this
# script by hand and redeploying fixed it for tonight, this closes the gap
# permanently. Doesn't setwd() itself (unlike the two sync_*_mirrors() calls
# above), so no restore needed after.
source("cleaning/prep/prep_accessibility_layer.R")

# 2026-09-16 (live gap caught by msna-n-wec-2026-e6, 3rd recurring instance of
# the same "fix exists, never automated" pattern as sync_accessibility_
# mirrors.R/prep_accessibility_layer.R above): prep_psu_geometries.R builds
# input_data/boundaries/psu/psu_hexagons_non_idp.gpkg + psu_sites_idp.gpkg -
# the cluster hexagon/site geometry dashboard_app/global.R's cluster_targets
# lookup and the map's own polygons both read directly - but was never called
# from anywhere automated. Last manual run was 2026-09-14 23:42; any cluster
# added to the frame since then (a new resampling batch, say) would render
# with no hexagon/site geometry on the map, and cluster_targets would be
# missing that cluster's target_households entirely (silently undercounting
# achieved via compute_progress_by_stratum()'s per-cluster cap - the exact
# failure mode this script's own 2026-09-02 header already documents from a
# prior incident). Placed here, not later: generate_partner_digest.R below
# sources global.R, which reads these two files directly, so this must run
# before that, same reasoning as the accessibility layer above.
source("cleaning/prep/prep_psu_geometries.R")

# ---- refresh submissions from whatever's currently in cleaning/ (picks up
# the latest anonymised export + all cleaning logs) — always the first
# DATA step (mirrors above are plumbing, not data), per Jack: "redeploy"
# means go back to source, not re-push whatever data/real_submissions.csv
# already has sitting in it. Prints its own sanity banner at both start
# and end. Now correctly runs against the just-synced mirrors, not last
# run's.
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

# ADDED 2026-09-22 (Jack, after the cross-format sweep found it): the three
# deletion columns on real_submissions.csv were copied from the overlays by
# prep_real_submissions.R ABOVE - i.e. before the independent checks just
# ran and before the overlays were rebuilt on the line above this one. So
# each run's own new confirmations reached the overlays (which the partner
# workbooks and 1_sampling read directly) but not the copy the dashboard's
# is_achieved() reads, leaving the dashboard a full pipeline run behind the
# tracker every run - 110 interviews on the 2026-09-21 run. The circular
# dependency is genuine (the independent checks read today's
# real_submissions.csv, so they can't run before prep), so this re-joins
# those three columns from the just-rebuilt overlays instead of reordering.
# Must stay AFTER build_confirmed_deletions_overlay.R and BEFORE
# generate_partner_digest.R/bundle_dashboard_mirrors() below, both of which
# read the refreshed figures.
source("cleaning/real/refresh_deletion_columns.R")
refresh_deletion_columns()

source("cleaning/real/sanity_checks.R")
print_sanity_banner_if_present() # most important checkpoint: right before this goes live and public

# ---- report generation, before the deploy itself — same freshly-refreshed data, one run ----
source("generate_partner_digest.R")

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
