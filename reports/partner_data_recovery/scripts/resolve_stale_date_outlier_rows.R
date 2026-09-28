# ==============================================================================
# resolve_stale_date_outlier_rows.R - PREPARED 2026-09-25, NOT RUN. Needs Jack's word.
#
# WHAT IT IS FOR: tracker rows with deletion_reason = date_outlier that are still PENDING although
# prep_real_submissions.R no longer flags their interview (flag_date_outlier is FALSE now). On the
# 2026-09-25 data that is exactly two FACT rows (detected 2026-09-13):
#   20f8f4be-... fact_yob_msna_005   start 2026-09-14 00:32, end 2026-09-12 13:12, uploaded 2026-09-13 06:23
#   656aac0b-... fact_yob_msna_005   start 2026-09-14 02:07, end 2026-09-12 03:12, uploaded 2026-09-13 06:23
#
# READ THIS BEFORE USING IT - these rows are NOT stale in the sense of "fixed":
# the flag rule is `start < 2026-08-01 OR start > Sys.Date()`, so on 2026-09-13 a start of 09-14 was
# "in the future" and flagged, and from 09-14 on it no longer is - while the start is still impossible
# (18-20 h AFTER the upload, 35-47 h after the interview's own end time). The interview is almost
# certainly real (end/upload agree with each other and with a 09-12/13 collection date); only the
# start clock is wrong. So:
#   * recovery_type = "false_positive" would say "the flag was wrong" - it was NOT.
#   * recovery_type = "justified_exception" says "the flag was right, the interview stays" - accurate.
#   * The cleaner option is to do nothing: FACT's workbook 'Other Issues' sheet is still (correctly)
#     asking FACT to confirm the real date, and a partner reply resolves the row through the normal path.
# Closing the rows changes: tracker status pending -> confirmed with recovery_type set (so they leave
# both overlays, FACT's Other Issues sheet and 'Pending Deletion' by 2). It does NOT change the wrong
# submission_date (2026-09-14) still sitting on those two data rows - nothing here touches real_submissions.
#
# NOTHING runs on source(). apply needs confirm = TRUE AND an explicit recovery_type (no default:
# which of the two values is right is Jack's call).
#
#   source("reports/partner_data_recovery/scripts/issue_tracker.R")
#   source("reports/partner_data_recovery/scripts/resolve_stale_date_outlier_rows.R")
#   preview_stale_date_outlier_resolutions()                       # read-only: rows + evidence
#   apply_stale_date_outlier_resolutions(recovery_type = "justified_exception", confirm = TRUE)
#   restore_stale_date_outlier_resolutions("<snapshot csv>")       # undo, one call
#
# UNDO: apply writes a full pre-change snapshot of every row it touches to
# reports/partner_data_recovery/outputs/_review_decisions_log/<date>_stale_date_outlier_BEFORE.csv
# before changing anything; restore puts exactly those rows back (all TRACKER_COLUMNS) and logs it.
# Candidate rule (idempotent, no hard-coded uuids): pending date_outlier tracker rows, not recovered,
# whose interview exists in the data, is completed, and is no longer flagged by prep.
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})

.sdo_candidates <- function(subs_path = "data/real_submissions.csv") {
  tracker <- read_tracker()
  subs <- read_csv(subs_path, show_col_types = FALSE, na = character(), col_types = cols(.default = col_character()))
  cand <- tracker %>%
    filter(issue_type == "confirmed_deletion", deletion_reason == "date_outlier", status == "pending",
           is.na(recovery_type), !is.na(uuid), uuid != "")
  s <- subs[match(cand$uuid, subs$submission_uuid), ]
  cand$in_data <- !is.na(s$submission_uuid)
  cand$flag_now <- s$flag_date_outlier
  cand$outcome <- s$interview_outcome
  cand$enum_id <- s$enum_id
  cand$start_dt <- s$start_datetime; cand$end_dt <- s$end_datetime; cand$uploaded_at <- s$uploaded_at
  to_t <- function(x) suppressWarnings(as.POSIXct(substr(x, 1, 19), tz = "UTC", format = "%Y-%m-%d %H:%M:%S"))
  cand$start_minus_upload_h <- round(as.numeric(difftime(to_t(cand$start_dt), to_t(cand$uploaded_at), units = "hours")), 1)
  cand$start_minus_end_h <- round(as.numeric(difftime(to_t(cand$start_dt), to_t(cand$end_dt), units = "hours")), 1)
  cand %>% filter(in_data, outcome == "completed", toupper(flag_now) != "TRUE")
}

preview_stale_date_outlier_resolutions <- function(subs_path = "data/real_submissions.csv") {
  cand <- .sdo_candidates(subs_path)
  cat(sprintf("preview_stale_date_outlier_resolutions(): %d pending date_outlier tracker row(s) whose interview prep no longer flags.\n", nrow(cand)))
  if (nrow(cand) > 0) {
    print(as.data.frame(cand %>% transmute(org_id, uuid = substr(uuid, 1, 8), enum_id, start = start_dt, end = end_dt, uploaded = uploaded_at,
                                           start_minus_upload_h, start_minus_end_h, detected_date)), row.names = FALSE)
    cat("start later than upload/end = the start clock is wrong; the flag lapsed only because the rule compares the start with Sys.Date().\n")
    cat("Nothing has been changed. To close them: apply_stale_date_outlier_resolutions(recovery_type = 'justified_exception', confirm = TRUE).\n")
  }
  invisible(cand)
}

apply_stale_date_outlier_resolutions <- function(recovery_type, confirm = FALSE, decided_by = "Jack (via chat review)", resolution = NULL,
                                                 subs_path = "data/real_submissions.csv",
                                                 log_dir = "reports/partner_data_recovery/outputs/_review_decisions_log") {
  if (!isTRUE(confirm)) stop("apply_stale_date_outlier_resolutions(): pass confirm = TRUE explicitly - this resolves tracker rows and needs Jack's word.")
  if (missing(recovery_type) || !(recovery_type %in% c("justified_exception", "false_positive"))) {
    stop("apply_stale_date_outlier_resolutions(): recovery_type must be given explicitly: 'justified_exception' (the flag was right, the interview stays) or 'false_positive' (the flag was wrong). No default - it is Jack's call.")
  }
  cand <- .sdo_candidates(subs_path)
  if (nrow(cand) == 0) { cat("apply_stale_date_outlier_resolutions(): nothing to resolve.\n"); return(invisible(NULL)) }
  dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)
  stamp <- format(Sys.Date(), "%Y-%m-%d")
  snapshot_path <- file.path(log_dir, paste0(stamp, "_stale_date_outlier_BEFORE.csv"))
  if (file.exists(snapshot_path)) snapshot_path <- file.path(log_dir, paste0(stamp, "_", format(Sys.time(), "%H%M%S"), "_stale_date_outlier_BEFORE.csv"))
  write_csv(cand[, TRACKER_COLUMNS], snapshot_path, na = "")   # BEFORE any change

  if (is.null(resolution)) {
    resolution <- if (recovery_type == "justified_exception") {
      paste0("Closed internally ", stamp, " (", decided_by, "): the interview is real and stays in the sample. Its start time is wrong (later than its own upload and end times, i.e. a device clock ahead), so the exported date cannot be relied on; the true collection date could not be confirmed from the data. The flag was correct.")
    } else {
      paste0("Closed internally ", stamp, " (", decided_by, "): treated as a false positive - no date problem to correct.")
    }
  }
  tracker <- read_tracker()
  hit <- tracker$issue_id %in% cand$issue_id & tracker$status == "pending"
  tracker$status[hit] <- "confirmed"
  tracker$resolution[hit] <- resolution
  tracker$resolution_date[hit] <- stamp
  tracker$confirmed_by[hit] <- "internal_team"
  tracker$recovery_type[hit] <- recovery_type
  write_tracker(tracker)
  cat(paste0(sprintf("%s | decided_by=%s | n=%d | new_status=confirmed | confirmed_by=internal_team | recovery_type=%s | resolution=%s | snapshot=%s | issue_ids=%s",
                     format(Sys.time(), "%Y-%m-%d %H:%M:%S"), decided_by, sum(hit), recovery_type, resolution, basename(snapshot_path),
                     paste(tracker$issue_id[hit], collapse = ";")), "\n"),
      file = file.path(log_dir, paste0(stamp, ".log")), append = TRUE)
  cat(sprintf("apply_stale_date_outlier_resolutions(): resolved %d row(s) as %s; snapshot: %s\n", sum(hit), recovery_type, snapshot_path))
  invisible(list(n = sum(hit), snapshot = snapshot_path))
}

restore_stale_date_outlier_resolutions <- function(snapshot_path, decided_by = "Jack (via chat review)",
                                                   log_dir = "reports/partner_data_recovery/outputs/_review_decisions_log") {
  snap <- read_csv(snapshot_path, show_col_types = FALSE, col_types = cols(.default = "c"))
  for (col in setdiff(TRACKER_COLUMNS, names(snap))) snap[[col]] <- NA_character_
  tracker <- read_tracker()
  idx <- match(snap$issue_id, tracker$issue_id)
  if (anyNA(idx)) warning("restore_stale_date_outlier_resolutions(): ", sum(is.na(idx)), " snapshot row(s) no longer exist in the tracker - skipped.")
  ok <- !is.na(idx)
  for (col in TRACKER_COLUMNS) tracker[[col]][idx[ok]] <- snap[[col]][ok]
  write_tracker(tracker)
  dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)
  cat(paste0(sprintf("%s | decided_by=%s | RESTORE n=%d from %s | issue_ids=%s",
                     format(Sys.time(), "%Y-%m-%d %H:%M:%S"), decided_by, sum(ok), basename(snapshot_path), paste(snap$issue_id[ok], collapse = ";")), "\n"),
      file = file.path(log_dir, paste0(format(Sys.Date(), "%Y-%m-%d"), ".log")), append = TRUE)
  cat(sprintf("restore_stale_date_outlier_resolutions(): restored %d row(s) to their pre-change state.\n", sum(ok)))
  invisible(sum(ok))
}
