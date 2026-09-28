# ==============================================================================
# resolve_live_claimant_duplicates.R - change (4), PREPARED 2026-09-25, NOT RUN.
#
# The live-claimant rule (scripts/shared/live_claims.R) stops flagging the first
# LIVE interview of a point / IDP listing slot as a duplicate when every earlier
# claimant was already settled-deleted (mostly duration_under_20) or never a
# completed interview. Rows already in the tracker as PENDING duplicate_point
# for such interviews are stale: this file resolves them, in ONE bulk call, the
# same way the 35 fcs_zero rows were bulk-recovered on 2026-09-10 - status
# 'confirmed' with recovery_type 'false_positive', confirmed_by 'internal_team'
# (recovery_type non-NA is what removes a row from both overlays and every
# partner sheet).
#
# NOTHING here runs on source(). It needs Jack's word AND an explicit
# apply_live_claimant_resolutions(confirm = TRUE).
#
#   source("reports/partner_data_recovery/scripts/issue_tracker.R")
#   source("reports/partner_data_recovery/scripts/resolve_live_claimant_duplicates.R")
#   preview_live_claimant_resolutions()          # read-only: what WOULD change
#   apply_live_claimant_resolutions(confirm = TRUE)   # snapshot -> apply -> log
#   restore_live_claimant_resolutions("<snapshot csv>")  # undo, one call
#
# UNDO: apply writes a full pre-change snapshot of every tracker row it touches
# (reports/partner_data_recovery/outputs/_review_decisions_log/<date>_live_
# claimant_dups_BEFORE.csv) before changing anything. restore_...() puts exactly
# those rows back (status, resolution, resolution_date, confirmed_by,
# recovery_type - all of TRACKER_COLUMNS) and logs the restore. apply_resolution()
# itself cannot clear fields or reopen, which is why undo is snapshot-based.
#
# Candidate definition (idempotent - same answer before and after the pipeline
# has re-run with the new rule): tracker rows with issue_type confirmed_deletion,
# deletion_reason duplicate_point, status pending, whose interview is COMPLETE,
# not settled-deleted, and was a duplicate under the OLD rule but is NOT one under
# the live-claimant rule. Pending duplicate_point rows that were never key
# duplicates (e.g. 4 legacy FACT cluster-level rows for idp_NG008014_6) are
# deliberately left alone.
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source("scripts/shared/live_claims.R")

.lc_settled_uuids <- function(tracker) {
  tracker$uuid[tracker$issue_type == "confirmed_deletion" & tracker$status %in% TERMINAL_STATUSES &
                 is.na(tracker$recovery_type) & !is.na(tracker$uuid)]
}

.lc_candidates <- function(subs_path = "data/real_submissions.csv") {
  tracker <- read_tracker()
  subs <- read_csv(subs_path, show_col_types = FALSE, na = character(), col_types = cols(.default = col_character()))
  adj <- apply_live_claim_rule(subs, settled_uuid = .lc_settled_uuids(tracker))
  old_dup <- old_rule_duplicates(subs)
  # exactly the rows the rule clears: duplicates under the OLD rule, not under the new one
  not_dup <- adj$submission_uuid[old_dup & adj$is_duplicate == "FALSE" & adj$interview_outcome == "completed"]
  tracker %>%
    filter(issue_type == "confirmed_deletion", deletion_reason == "duplicate_point", status == "pending",
           !is.na(uuid), uuid %in% not_dup)
}

preview_live_claimant_resolutions <- function(subs_path = "data/real_submissions.csv") {
  cand <- .lc_candidates(subs_path)
  cat(sprintf("preview_live_claimant_resolutions(): %d pending duplicate_point tracker row(s) would be resolved as false_positive.\n", nrow(cand)))
  print(as.data.frame(cand %>% count(org_id, sort = TRUE)), row.names = FALSE)
  invisible(cand)
}

apply_live_claimant_resolutions <- function(confirm = FALSE, decided_by = "Jack (via chat review)",
                                            subs_path = "data/real_submissions.csv",
                                            log_dir = "reports/partner_data_recovery/outputs/_review_decisions_log") {
  if (!isTRUE(confirm)) stop("apply_live_claimant_resolutions(): pass confirm = TRUE explicitly - this resolves tracker rows and needs Jack's word.")
  cand <- .lc_candidates(subs_path)
  if (nrow(cand) == 0) { cat("apply_live_claimant_resolutions(): nothing to resolve.\n"); return(invisible(NULL)) }
  dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)
  stamp <- format(Sys.Date(), "%Y-%m-%d")
  snapshot_path <- file.path(log_dir, paste0(stamp, "_live_claimant_dups_BEFORE.csv"))
  if (file.exists(snapshot_path)) snapshot_path <- file.path(log_dir, paste0(stamp, "_", format(Sys.time(), "%H%M%S"), "_live_claimant_dups_BEFORE.csv"))
  write_csv(cand[, TRACKER_COLUMNS], snapshot_path, na = "")   # BEFORE any change

  tracker <- read_tracker()
  hit <- tracker$issue_id %in% cand$issue_id & tracker$status == "pending"
  resolution <- paste0("Auto-resolved ", stamp, " (live-claimant rule): every earlier claimant of this point/listing slot was already ",
                       "settled-deleted or never a completed interview, so this is the first live claimant, not a duplicate.")
  tracker$status[hit] <- "confirmed"
  tracker$resolution[hit] <- resolution
  tracker$resolution_date[hit] <- stamp
  tracker$confirmed_by[hit] <- "internal_team"
  tracker$recovery_type[hit] <- "false_positive"
  write_tracker(tracker)
  cat(paste0(sprintf("%s | decided_by=%s | n=%d | new_status=confirmed | confirmed_by=internal_team | recovery_type=false_positive | resolution=%s | snapshot=%s | issue_ids=%s",
                     format(Sys.time(), "%Y-%m-%d %H:%M:%S"), decided_by, sum(hit), resolution, basename(snapshot_path),
                     paste(tracker$issue_id[hit], collapse = ";")), "\n"),
      file = file.path(log_dir, paste0(stamp, ".log")), append = TRUE)
  cat(sprintf("apply_live_claimant_resolutions(): resolved %d row(s); snapshot: %s\n", sum(hit), snapshot_path))
  invisible(list(n = sum(hit), snapshot = snapshot_path))
}

restore_live_claimant_resolutions <- function(snapshot_path, decided_by = "Jack (via chat review)",
                                              log_dir = "reports/partner_data_recovery/outputs/_review_decisions_log") {
  snap <- read_csv(snapshot_path, show_col_types = FALSE, col_types = cols(.default = "c"))
  for (col in setdiff(TRACKER_COLUMNS, names(snap))) snap[[col]] <- NA_character_
  tracker <- read_tracker()
  idx <- match(snap$issue_id, tracker$issue_id)
  if (anyNA(idx)) warning("restore_live_claimant_resolutions(): ", sum(is.na(idx)), " snapshot row(s) no longer exist in the tracker - skipped.")
  ok <- !is.na(idx)
  for (col in TRACKER_COLUMNS) tracker[[col]][idx[ok]] <- snap[[col]][ok]
  write_tracker(tracker)
  dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)
  cat(paste0(sprintf("%s | decided_by=%s | RESTORE n=%d from %s | issue_ids=%s",
                     format(Sys.time(), "%Y-%m-%d %H:%M:%S"), decided_by, sum(ok), basename(snapshot_path),
                     paste(snap$issue_id[ok], collapse = ";")), "\n"),
      file = file.path(log_dir, paste0(format(Sys.Date(), "%Y-%m-%d"), ".log")), append = TRUE)
  cat(sprintf("restore_live_claimant_resolutions(): restored %d row(s) to their pre-change state.\n", sum(ok)))
  invisible(sum(ok))
}
