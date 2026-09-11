# ==============================================================================
# Writes TWO overlays from recovery_issue_tracker.csv - the two distinct
# Achieved bases the approved deletion/recovery-confirmation model calls for
# (see issue_tracker.R's header): resampling only ever treats a SETTLED
# deletion as gone, while the dashboard shows a merely-flagged-but-still-open
# record as provisionally not achieved too (the intended incentive - field
# teams see what they'll lose unless recovered). Realised 2026-09-06 while
# wiring is_achieved() up to this: my own original single-overlay design
# only implemented the settled/resampling basis - there was nothing yet
# giving the dashboard the wider, provisional one, contrary to the approved
# spec. Fixed here rather than shipped half-done.
#
# - data/CONFIRMED_DELETIONS_OVERLAY.csv: status %in% TERMINAL_STATUSES
#   (confirmed OR contested - both mean "this deletion stands": a contested
#   row here is one a partner disputed and a reviewer upheld anyway, per its
#   own resolution text, e.g. "contest reviewed and rejected - deletion
#   stands" - not an open dispute). This is the RESAMPLING-facing artifact -
#   read directly by 1_sampling once handed off (replacing combined_
#   deletion_log.rds), and by prep_real_submissions.R's quality_exclusion_
#   reason below, unchanged from the original build.
# - data/FLAGGED_DELETIONS_OVERLAY.csv: every confirmed_deletion tracker row
#   regardless of status (pending/sent/rejected/confirmed/contested) - the
#   DASHBOARD-facing, provisional basis. Feeds a NEW flagged_deletion_reason
#   column (prep_real_submissions.R) that is_achieved() (dashboard_app/
#   global.R) now checks - redefining that one function is enough to cover
#   every existing call site, none of which need their own code touched.
#
# Run this (part of the daily refresh chain, same as prep_real_submissions.R
# itself) any time the tracker has moved - in practice, right after
# reports/partner_data_recovery/scripts/register_deletion_log_issues.R and
# before cleaning/real/prep_real_submissions.R, so Achieved reflects
# whatever's currently in the tracker.
#
# FIXED 2026-09-08 (Jack): a row with recovery_type set (false_positive |
# justified_exception - i.e. apply_resolution() was called with
# recovery_type, meaning the flagged issue turned out to be a genuine,
# non-duplicate interview rather than a real deletion) is now excluded from
# BOTH overlays, not just left sitting in FLAGGED_DELETIONS_OVERLAY forever.
# Before this fix, status alone drove both overlays' filters, so a
# recovered/false-positive row (status="confirmed", recovery_type set) was
# indistinguishable from a genuine confirmed deletion: it stayed in
# CONFIRMED_DELETIONS_OVERLAY (wrongly telling 1_sampling to resample a
# household that didn't actually need replacing) AND in
# FLAGGED_DELETIONS_OVERLAY forever (permanently suppressing Achieved credit
# for an interview that was never actually deleted). Gives the three real
# outcomes Jack described: resolved-recovered (recovery_type set - excluded
# from both overlays, counts as Achieved again), resolved-delete (status in
# TERMINAL_STATUSES, recovery_type NA - stays in both, genuinely gone, feeds
# resampling), unresolved (status pending/sent/rejected - stays in
# FLAGGED_DELETIONS_OVERLAY only, not yet resampling-actionable since it
# might still be recovered).
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})

source("reports/partner_data_recovery/scripts/issue_tracker.R")

tracker <- read_tracker()
confirmed_deletions <- tracker %>% filter(issue_type == "confirmed_deletion")

write_overlay <- function(df, csv_path, version_path) {
  write_csv(df, csv_path)
  writeLines(c(
    paste0("stamped_at: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    paste0("overlay_csv_mtime: ", format(file.info(csv_path)$mtime, "%Y-%m-%d %H:%M:%S")),
    paste0("overlay_csv_md5: ", tools::md5sum(csv_path)),
    paste0("overlay_csv_rows: ", nrow(df)),
    # FIX 2026-09-11: was a second hardcoded literal copy of the tracker
    # path, independent of issue_tracker.R's own dynamically-resolved
    # TRACKER_PATH (already in scope from the source() above) - two
    # expressions of the same path could silently diverge if either the
    # tracker or the scripts folder ever moved.
    paste0("source_tracker_md5: ", tools::md5sum(TRACKER_PATH))
  ), version_path)
}

confirmed_overlay <- confirmed_deletions %>%
  filter(status %in% TERMINAL_STATUSES, is.na(recovery_type)) %>%
  transmute(uuid, reason = deletion_reason, status, confirmed_by, resolution, resolution_date)
write_overlay(confirmed_overlay, "data/CONFIRMED_DELETIONS_OVERLAY.csv", "data/CONFIRMED_DELETIONS_OVERLAY_version.txt")

flagged_overlay <- confirmed_deletions %>%
  filter(is.na(recovery_type)) %>%
  transmute(uuid, reason = deletion_reason, status, rounds_outstanding)
write_overlay(flagged_overlay, "data/FLAGGED_DELETIONS_OVERLAY.csv", "data/FLAGGED_DELETIONS_OVERLAY_version.txt")

cat(sprintf(
  "build_confirmed_deletions_overlay(): CONFIRMED_DELETIONS_OVERLAY: %d row(s) (%d confirmed, %d contested) - resampling basis.\n",
  nrow(confirmed_overlay), sum(confirmed_overlay$status == "confirmed"), sum(confirmed_overlay$status == "contested")
))
cat(sprintf(
  "build_confirmed_deletions_overlay(): FLAGGED_DELETIONS_OVERLAY: %d row(s) (%d still pending/sent/rejected) - dashboard provisional basis.\n",
  nrow(flagged_overlay), sum(!flagged_overlay$status %in% c("confirmed", "contested"))
))
