# ==============================================================================
# preserve_duplicate_history.R - stops a full pipeline re-run from silently
# reverting an already-settled interview's is_duplicate flag.
#
# WHY THIS EXISTS (found + fixed 2026-09-27, Jack's decision to build the
# proper fix rather than accept the drift): prep_real_submissions.R's own
# is_duplicate (section 4) is recomputed FRESH every run from raw dup_key +
# upload-time ordering alone - it has zero memory of past runs or of who has
# since been confirmed-deleted. The correct value for an interview that is
# ITSELF already settled (confirmed/contested) instead depends on accumulated
# history: scripts/shared/live_claims.R's apply_live_claim_rule() (called by
# refresh_deletion_columns()) only ever promotes the CURRENT first-LIVE
# claimant of a key and explicitly "keeps exactly the flag" everyone else -
# including already-settled rows - already had. A bare full re-run overwrites
# that history with the naive value BEFORE refresh_deletion_columns() ever
# runs, and refresh can't recover it afterward: a settled row is by
# definition not live, so apply_live_claim_rule() never re-touches it,
# whatever its is_duplicate happens to read at that point. Verified
# empirically (both a bare prep-only run and the FULL real deploy_dashboard.R
# chain, byte-identical result either way): 20 already-settled rows flip
# is_duplicate FALSE->TRUE on every subsequent full run, permanently, with no
# way back except a pre-run backup.
#
# Zero Achieved/credited impact either way - is_achieved() never reads
# is_duplicate (see live_claims.R's own header) - so this is a display/
# record-keeping correctness fix, not a data-safety one. Built anyway per
# Jack's explicit decision (2026-09-27): the historical flag should read as
# it did at the time the interview was actually reviewed, not flap on every
# unrelated re-run.
#
# MECHANISM: a snapshot-and-restore pair, bracketing the run.
#   snapshot_duplicate_history()  - call FIRST, before prep_real_submissions.R
#                                    runs (while real_submissions.csv still
#                                    holds last run's correct, accumulated
#                                    state). Writes a small 3-column cache.
#   restore_duplicate_history()   - call LAST, after refresh_deletion_columns()
#                                    has done its normal job. For any row that
#                                    was ALREADY settled in the snapshot AND
#                                    is STILL settled now, overwrites
#                                    is_duplicate with the snapshot's value
#                                    (recombined with this run's own OTHER
#                                    quality flags into any_quality_flag - see
#                                    that step's own comment for why it's a
#                                    recombine, not a blind overwrite).
#
# Deliberately does NOT touch:
# - a row settled in the snapshot but NO LONGER settled now (recovered via
#   recovery_type - build_confirmed_deletions_overlay.R excludes it from
#   both overlays entirely) - it should behave as a normal live claimant
#   again, so the fresh computation is left standing, not restored.
# - a row NOT settled in the snapshot that becomes NEWLY settled this run -
#   its group may have a genuinely new promotion to make this run (e.g. a
#   second member of the same key also just got confirmed), which needs the
#   FRESH computation, not a stale pre-run value. Restoring here would
#   silently un-do a legitimate new promotion.
# - n_live_claims - a live, current-state count, not a historical record;
#   always left as freshly (correctly) computed.
# - any row that was already live and stays live - untouched either way,
#   since apply_live_claim_rule() already computes those correctly from
#   scratch every time.
#
# First run ever (no snapshot file yet): restore_duplicate_history() no-ops
# with a message, same "nothing to protect yet" spirit as prep's own prev_meta
# handling.
#
# Usage (deploy_dashboard.R): snapshot_duplicate_history() immediately BEFORE
# source("cleaning/real/prep_real_submissions.R"); restore_duplicate_history()
# immediately AFTER refresh_deletion_columns().
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source("scripts/shared/retry_file_write.R")

SNAPSHOT_PATH <- "data/_pre_run_duplicate_snapshot.csv"
SETTLED_STATUSES <- c("confirmed", "contested")

snapshot_duplicate_history <- function(csv_path = "data/real_submissions.csv", snapshot_path = SNAPSHOT_PATH) {
  if (!file.exists(csv_path)) {
    cat("snapshot_duplicate_history(): no", csv_path, "yet - nothing to snapshot.\n")
    return(invisible(NULL))
  }
  subs <- read_csv(csv_path, show_col_types = FALSE, na = character(),
                    col_types = cols(.default = col_character()))
  needed <- c("submission_uuid", "deletion_status", "is_duplicate")
  missing <- setdiff(needed, names(subs))
  if (length(missing) > 0) {
    cat("snapshot_duplicate_history(): ", csv_path, " missing column(s) ", paste(missing, collapse = ", "),
        " - skipping (output shape has changed, nothing to snapshot against).\n", sep = "")
    return(invisible(NULL))
  }
  snap <- subs %>% transmute(submission_uuid, deletion_status, is_duplicate)
  retry_file_write(function(p) write_csv(snap, p, na = "NA"), snapshot_path)
  cat(sprintf(
    "snapshot_duplicate_history(): saved %d row(s) (%d already settled) to %s before this run's refresh.\n",
    nrow(snap), sum(snap$deletion_status %in% SETTLED_STATUSES), snapshot_path
  ))
  invisible(snap)
}

restore_duplicate_history <- function(csv_path = "data/real_submissions.csv", snapshot_path = SNAPSHOT_PATH) {
  if (!file.exists(snapshot_path)) {
    cat("restore_duplicate_history(): no", snapshot_path, "(first run, or snapshot step was skipped) - nothing to restore, leaving this run's fresh computation as-is.\n")
    return(invisible(list(restored = 0L)))
  }
  if (!file.exists(csv_path)) {
    cat("restore_duplicate_history(): no", csv_path, "- nothing to restore into.\n")
    return(invisible(list(restored = 0L)))
  }
  snap <- read_csv(snapshot_path, show_col_types = FALSE, na = character(), col_types = cols(.default = col_character()))
  subs <- read_csv(csv_path, show_col_types = FALSE, na = character(), col_types = cols(.default = col_character()))
  needed <- c("submission_uuid", "deletion_status", "is_duplicate", "any_quality_flag",
              "flag_gps_outlier", "flag_duration_outlier", "flag_hh_size_mismatch", "flag_lga_mismatch")
  missing <- setdiff(needed, names(subs))
  if (length(missing) > 0) {
    cat("restore_duplicate_history(): ", csv_path, " missing column(s) ", paste(missing, collapse = ", "),
        " - skipping (output shape has changed, nothing safe to restore).\n", sep = "")
    return(invisible(list(restored = 0L)))
  }

  snap_by_uuid <- setNames(snap$is_duplicate, snap$submission_uuid)
  snap_settled_by_uuid <- setNames(snap$deletion_status %in% SETTLED_STATUSES, snap$submission_uuid)
  was_settled <- unname(snap_settled_by_uuid[subs$submission_uuid]); was_settled[is.na(was_settled)] <- FALSE
  is_settled_now <- subs$deletion_status %in% SETTLED_STATUSES
  # the ONLY rows this ever touches: settled before AND still settled now - see this file's own
  # header for why every other case (recovered, newly-settled, still-live) is deliberately left alone.
  protect <- was_settled & is_settled_now
  restored_dup <- unname(snap_by_uuid[subs$submission_uuid])
  would_flip <- protect & !is.na(restored_dup) & subs$is_duplicate != restored_dup
  n_flip <- sum(would_flip)
  if (n_flip == 0) {
    cat("restore_duplicate_history(): no already-settled row's is_duplicate drifted from its pre-run value this run - nothing to restore.\n")
    return(invisible(list(restored = 0L)))
  }

  as_lgl <- function(x) toupper(x) == "TRUE"
  new_is_dup <- subs$is_duplicate
  new_is_dup[would_flip] <- restored_dup[would_flip]
  # any_quality_flag is a RECOMBINE, not a blind restore: OR the restored duplicate flag with THIS
  # run's own other quality flags (gps/duration/hh_size/lga_mismatch), so a genuinely new flag on an
  # already-settled row (e.g. duration_under_20 itself, which is exactly why these rows are settled)
  # is never lost - only the duplicate component is protected.
  other_flags <- as_lgl(subs$flag_gps_outlier) | as_lgl(subs$flag_duration_outlier) |
    as_lgl(subs$flag_hh_size_mismatch) | as_lgl(subs$flag_lga_mismatch)
  new_any_flag <- subs$any_quality_flag
  new_any_flag[would_flip] <- ifelse(other_flags[would_flip] | as_lgl(new_is_dup[would_flip]), "TRUE", "FALSE")

  subs$is_duplicate <- new_is_dup
  subs$any_quality_flag <- new_any_flag
  retry_file_write(function(p) write_csv(subs, p, na = "NA"), csv_path)

  cat(sprintf(
    "restore_duplicate_history(): restored the pre-run is_duplicate value on %d already-settled row(s) that this run's fresh computation had drifted (%d cleared to FALSE, %d reset to TRUE); any_quality_flag re-combined with this run's own other flags, not blindly restored. Achieved/credited unaffected either way.\n",
    n_flip, sum(would_flip & new_is_dup == "FALSE"), sum(would_flip & new_is_dup == "TRUE")
  ))
  invisible(list(restored = n_flip))
}
