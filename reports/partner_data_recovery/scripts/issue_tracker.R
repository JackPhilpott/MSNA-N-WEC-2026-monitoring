# ==============================================================================
# Persistent cross-batch state for the data-recovery-workbook process
# (2_monitoring/reports/partner_data_recovery/). Built 2026-09-03 as the
# foundation piece of the "consolidated recovery_workbooks module" Jack
# asked for (generation + ingestion + verification) - this file is ONLY the
# state layer: one row per detected issue, with a status that survives
# across multiple generation/ingestion runs, so:
#   - a new generation run doesn't re-flag an issue a partner already
#     resolved in an earlier round (see get_unresolved_issue_ids()), and
#   - a partial/multi-round response can be ingested idempotently (re-
#     applying the same resolution twice is a no-op, not a duplicate row).
#
# UPDATED 2026-09-11 (was stale since 2026-09-03): this IS now wired into
# both full_batch_pipeline.R (sources this file directly, calls
# register_issues() via independent_deletion_checks.R and reads the
# tracker for the Confirmed Deletions sheet) and, via the Python twin
# below, verify_data_recovery_response.py's apply_writeback path (live
# since 2026-09-06 - confirmed against production data, 56+ rows carry
# confirmed_by='partner', a value only that one call site ever writes).
# The header used to say this integration was "a following step" - it
# happened days ago and the comment was never updated, which is exactly
# the kind of staleness this project keeps getting bitten by. Matching
# Python counterpart: issue_tracker.py (same CSV, same schema, used from
# verify_data_recovery_response.py and review_recovery_response.py).
#
# This tracker is INTERNAL bookkeeping for coordinating recovery-workbook
# batches - separate from the two other pieces of Jack's stated plan:
#   - the OVERLAY CSV that will actually apply confirmed corrections to
#     real_submissions.csv (CONFIRMED_QUALITY_EXCLUSIONS.csv-style, read by
#     prep_real_submissions.R) - not built yet, a later step.
#   - the TRACE/LOG CSV handed to the data officer periodically - also not
#     built yet; this tracker could feed it, but isn't itself that document.
#
# Schema (cleaning/real/data_recovery_responses/recovery_issue_tracker.csv):
#   issue_id       - "<issue_type>::<key>", stable across reruns (see
#                    build_issue_id() below) - THE de-dup key.
#   issue_type     - gps_duplicate | idp_listing_duplicate |
#                    missing_hh_listing | confirmed_deletion
#   deletion_reason - (added 2026-09-06, confirmed_deletion issues only)
#                    which of deletion_log.R's six CURRENT rules fired - the
#                    exact `reason` values build_deletion_log() emits today:
#                    no_consent | duration_under_20 | duplicate_point |
#                    listing_missing | pct_missing_flagged | fcs_zero. NA for
#                    the other three issue_types. Drives which rows get a
#                    real appeal (Contest This?) vs. an FYI-only note in the
#                    recovery workbook - see NO_APPEAL_DELETION_REASONS below
#                    - rather than needing a separate issue_type per rule.
#                    Historical deletion-log files from before 2026-09-01 also
#                    emit a retired seventh value, duration_under_30 (the old
#                    30-min floor) - register_deletion_log_issues.R drops
#                    those at ingestion rather than ever writing this column,
#                    so this column itself should never actually hold it.
#   org_id         - partner (lowercase org_id, matches ORG_LABELS)
#   cluster_id     - matched_cluster_id / idp_cluster_id as applicable
#   strata_id      - for the downstream resampling feedback loop (Jack:
#                    "keep cluster_id/strata_id clearly attached to
#                    whatever confirmed deletions output you produce") -
#                    nullable, filled in by the caller when known.
#   uuid           - the interview's uuid; NA for missing_hh_listing (that
#                    issue type is cluster-level, not interview-level).
#   listing_number - IDP listing number in dispute; NA otherwise.
#   status         - pending (detected, not yet sent) | sent (in an
#                    outgoing workbook, awaiting response) | confirmed
#                    (partner responded, passed verification) | rejected
#                    (response failed verification / needs a re-ask) |
#                    contested (partner disputed a Confirmed Deletion).
#   detected_date  - first time this issue_id was registered.
#   first_batch_date / last_batch_date - date(s) of the workbook(s) that
#                    carried this issue; last_batch_date updates each time
#                    an unresolved issue is re-included in a later batch.
#   rounds_outstanding - (added 2026-09-06) count of batches this issue has
#                    been re-seen while still open. VISIBILITY ONLY - never
#                    used to trigger any automatic decision (Jack explicitly
#                    rejected any auto-confirmation from a clock running
#                    out). Lets a genuinely-stuck item stand out from the
#                    normal "resolved within a round or two" pattern.
#   resolution     - free text: recovered survey_id, confirmed listing
#                    number, or a rejection/contest reason.
#   resolution_date
#   confirmed_by   - (added 2026-09-06) partner | internal_team. Who
#                    actually confirmed a deletion - never left to infer
#                    from a timeout, always set explicitly by whichever
#                    code path calls apply_resolution(..., "confirmed").
#   recovery_type  - (added 2026-09-06) false_positive | justified_exception,
#                    set when a flagged issue is instead resolved as
#                    recovered (rejoins Achieved) rather than confirmed
#                    deleted. NA for anything not recovered.
#   notes
#
# Status lifecycle: pending -> sent -> (confirmed | rejected | contested).
# rejected can go back to sent (re-asked in a later batch) via
# register_issues() picking it up again - see that function's own note.
# confirmed and contested are treated as terminal for
# get_unresolved_issue_ids() (already resolved, don't re-flag) but
# apply_resolution() can still move a contested row to confirmed once
# the dispute is settled.
# ==============================================================================
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tibble)
})

# Resolved relative to THIS script's own location (not the working
# directory) - generation scripts run from the project root, but nothing
# should break if some future caller source()'s this from elsewhere.
#
# BUG FIX 2026-09-06 19:45: sys.frame(1)$ofile assumes issue_tracker.R is
# always exactly one source() call deep, which breaks as soon as it's
# sourced indirectly (e.g. run_full_batch.R -> full_batch_pipeline.R ->
# issue_tracker.R, two levels deep - frame 1 there is full_batch_pipeline.R's
# OWN source() call, not this file's). Verified directly: under that real
# call chain this silently fell back to the wrong hardcoded relative path
# below (which doesn't exist), returning an EMPTY tracker with no error -
# meaning any real run of run_full_batch.R to date would have silently shown
# zero confirmed deletions for every partner. Search every active frame for
# the one whose ofile is THIS file, regardless of nesting depth - matches
# issue_tracker.py's __file__-based resolution, which has no such fragility.
TRACKER_PATH <- local({
  this_file <- NA_character_
  for (i in seq_len(sys.nframe())) {
    ofile <- sys.frame(i)$ofile
    if (!is.null(ofile) && grepl("issue_tracker\\.R$", ofile)) {
      this_file <- tryCatch(normalizePath(ofile), error = function(e) NA_character_)
      break
    }
  }
  if (is.na(this_file)) {
    # source()'d via a mechanism that doesn't set ofile at all (e.g.
    # Rscript -e) - fall back to the conventional project-root-relative path.
    "reports/partner_data_recovery/scripts/recovery_issue_tracker.csv"
  } else {
    file.path(dirname(this_file), "recovery_issue_tracker.csv")
  }
})

TRACKER_COLUMNS <- c(
  "issue_id", "issue_type", "deletion_reason", "org_id", "cluster_id", "strata_id", "uuid", "listing_number",
  "status", "detected_date", "first_batch_date", "last_batch_date", "rounds_outstanding",
  "resolution", "resolution_date", "confirmed_by", "recovery_type", "notes"
)

# confirmed_deletion issues that are validated methodology thresholds, not
# partner judgment calls - these register as immediately confirmed
# (confirmed_by = "internal_team", no pending_review stop) rather than going
# through the normal appeal flow. Used by the deletion_log.R wiring (this
# folder's caller script) and by the recovery-workbook generation step to
# decide which rows get a real "Contest This?" vs. an FYI-only note.
#
# REVERTED 2026-09-06 19:20: duration_under_30 was added here earlier tonight
# on my own initiative, not by approval - Jack's actual approved no-appeal set
# was always exactly these two. It was also wrong on the merits, independent
# of approval: the 30-minute floor was retired 2026-09-01 (replaced by 20),
# and every uuid ever labeled duration_under_30 across all 27 deletion-log
# files comes EXCLUSIVELY from files dated before that change - none reappear
# under ANY reason in a file from 09-01 onward, meaning the data officer's
# current active rules no longer consider them flagged at all. Registering
# and auto-confirming 1,628 such rows as no-appeal deletions tonight was a
# real bug (caught by the coordinating session + 8d spot-checking duration_min
# against the label and finding no relationship - durations up to 4,593
# minutes labeled "under 30"). register_deletion_log_issues.R now drops
# duration_under_30 rows at ingestion entirely rather than registering them
# under any status - see that script's header.
# fcs_zero REMOVED 2026-09-10 (Jack): downgraded from an automatic no-appeal
# deletion to a plain logical-error flag - it does nothing in the deletion
# pipeline any more, the interview is kept (assuming it clears every other
# criterion). register_deletion_log_issues.R no longer registers fcs_zero
# rows as confirmed_deletion candidates at all (dropped at ingestion, same
# treatment as the retired duration_under_30 reason - see that script's own
# header). Existing tracker rows already carrying deletion_reason=fcs_zero
# were bulk-recovered (recovery_type=false_positive) the same night so they
# stop being excluded from Achieved retroactively too.
# no_consent ADDED 2026-09-11 (Jack, confirmed directly): "these are the
# only two automatic deletion/removal records which don't need further
# verification or approval" (no_consent + duration_under_20). Reverses the
# earlier policy (no_consent was deliberately kept appealable when
# independent_deletion_checks.R was first built, matching how every
# no_consent item had been handled all along this project) - see that
# file's own run_independent_no_consent_check() for the auto-confirm
# mechanics this drives.
NO_APPEAL_DELETION_REASONS <- c("duration_under_20", "no_consent")

# NAMING CAUTION (added 2026-09-11, after this exact conflation produced a
# real bug in 1_sampling's partner-package scripts): "terminal" here means
# ONLY "excluded from re-flagging by register_issues() / excluded from
# get_unresolved_issue_ids()". It does NOT mean "settled" or "immutable" -
# apply_resolution() can still move a contested row to confirmed later
# (see that function's allow_reopen parameter below). Any downstream code
# treating one of these two statuses as more final/trustworthy than the
# other (e.g. filtering to status=="confirmed" only) is almost certainly
# wrong - both are equally terminal for achieved-status purposes.
TERMINAL_STATUSES <- c("confirmed", "contested")

empty_tracker <- function() {
  as_tibble(setNames(replicate(length(TRACKER_COLUMNS), character(0), simplify = FALSE), TRACKER_COLUMNS))
}

# Backfills any TRACKER_COLUMNS missing from an on-disk tracker with NA
# before returning - lets the schema grow (as it just did: deletion_reason/
# rounds_outstanding/confirmed_by/recovery_type, 2026-09-06) without a
# separate one-off migration step each time.
read_tracker <- function() {
  if (!file.exists(TRACKER_PATH)) return(empty_tracker())
  df <- read_csv(TRACKER_PATH, show_col_types = FALSE, col_types = cols(.default = "c"))
  for (col in setdiff(TRACKER_COLUMNS, names(df))) df[[col]] <- NA_character_
  df[, TRACKER_COLUMNS]
}

write_tracker <- function(df) {
  # na = "" (not readr::write_csv()'s default "NA"): this file is read/
  # written by BOTH this R script and issue_tracker.py. Python's csv module
  # writes a missing field as an empty string, and any Python-side blank/
  # truthiness check (e.g. verify_data_recovery_response.py's future
  # write-back) would treat the literal text "NA" as a non-empty value -
  # found 2026-09-06 while checking confirmed_by after a restore, before it
  # became load-bearing anywhere. Keep both languages writing "no value" the
  # same way.
  write_csv(df[, TRACKER_COLUMNS], TRACKER_PATH, na = "")
}

# One issue_id per (issue_type, natural key) - stable across reruns so the
# SAME real-world issue (e.g. the same interview's GPS mismatch) always
# maps to the same row here no matter how many times generation reruns.
build_issue_id <- function(issue_type, uuid = NA_character_, cluster_id = NA_character_, listing_number = NA) {
  key <- if (issue_type == "missing_hh_listing") cluster_id else uuid
  if (any(is.na(key) | !nzchar(key))) {
    stop("build_issue_id(): missing key for issue_type='", issue_type, "' - uuid required for interview-level types, cluster_id for missing_hh_listing.")
  }
  paste0(issue_type, "::", key)
}

# Registers newly-detected issues from a fresh generation pass. `new_issues`
# is a data frame with columns: issue_type, org_id, cluster_id, strata_id
# (may be NA), uuid (NA for missing_hh_listing), listing_number (NA unless
# idp_listing_duplicate), batch_date (the date of the workbook run
# producing this row - usually Sys.Date() at call time), notes (optional).
#
# Behaviour (this is what makes reruns idempotent and non-re-flagging):
#   - issue_id not seen before          -> insert as status="pending"
#   - issue_id exists, status is        -> bump last_batch_date, leave
#     pending/sent/rejected                status alone (still open, just
#                                          seen again in this pass)
#   - issue_id exists, status is        -> SKIPPED (not re-inserted, not
#     confirmed/contested (terminal)       modified) - this is the actual
#                                          "don't re-flag what's resolved"
#                                          behaviour a caller relies on.
#
# Returns the full updated tracker invisibly, AND (as the visible return
# value's `to_include` column via attr) tells the caller which of the
# INPUT rows are still open and should actually go into the new workbook -
# use this to filter new_issues before building a sheet, e.g.:
#   result <- register_issues(new_issues)
#   sheet_rows <- new_issues[result$still_open, ]
register_issues <- function(new_issues, batch_date = as.character(Sys.Date())) {
  stopifnot(all(c("issue_type", "org_id", "uuid", "cluster_id") %in% names(new_issues)))
  if (!"strata_id" %in% names(new_issues)) new_issues$strata_id <- NA_character_
  if (!"listing_number" %in% names(new_issues)) new_issues$listing_number <- NA_character_
  if (!"deletion_reason" %in% names(new_issues)) new_issues$deletion_reason <- NA_character_
  if (!"notes" %in% names(new_issues)) new_issues$notes <- NA_character_

  new_issues$issue_id <- mapply(
    build_issue_id, new_issues$issue_type, new_issues$uuid, new_issues$cluster_id, new_issues$listing_number
  )

  tracker <- read_tracker()
  today <- as.character(Sys.Date())

  still_open <- rep(TRUE, nrow(new_issues))
  n_new <- 0L
  n_reseen <- 0L
  n_skipped <- 0L
  for (i in seq_len(nrow(new_issues))) {
    existing_row <- which(tracker$issue_id == new_issues$issue_id[i])
    if (length(existing_row) == 0) {
      tracker <- bind_rows(tracker, tibble(
        issue_id = new_issues$issue_id[i], issue_type = new_issues$issue_type[i],
        deletion_reason = new_issues$deletion_reason[i],
        org_id = new_issues$org_id[i], cluster_id = new_issues$cluster_id[i],
        strata_id = new_issues$strata_id[i], uuid = new_issues$uuid[i],
        listing_number = new_issues$listing_number[i], status = "pending",
        detected_date = today, first_batch_date = batch_date, last_batch_date = batch_date,
        rounds_outstanding = "0",
        resolution = NA_character_, resolution_date = NA_character_,
        confirmed_by = NA_character_, recovery_type = NA_character_, notes = new_issues$notes[i]
      ))
      n_new <- n_new + 1L
    } else if (tracker$status[existing_row] %in% TERMINAL_STATUSES) {
      still_open[i] <- FALSE # already resolved - don't re-flag, don't touch the row
      n_skipped <- n_skipped + 1L
    } else {
      tracker$last_batch_date[existing_row] <- batch_date
      # rounds_outstanding: visibility only (see schema note above) - counts
      # how many batches this still-open issue has now appeared in.
      prior_rounds <- suppressWarnings(as.integer(tracker$rounds_outstanding[existing_row]))
      tracker$rounds_outstanding[existing_row] <- as.character(coalesce(prior_rounds, 0L) + 1L)
      n_reseen <- n_reseen + 1L
    }
  }

  write_tracker(tracker)
  cat(sprintf(
    "register_issues(): %d new, %d already-open (re-seen), %d already-resolved (skipped) of %d input rows.\n",
    n_new, n_reseen, n_skipped, nrow(new_issues)
  ))
  invisible(list(tracker = tracker, still_open = still_open))
}

# Transitions pending -> sent for the given issue_ids (call once a workbook
# has actually been emailed - generation alone does not mean sent).
mark_batch_sent <- function(issue_ids, batch_date = as.character(Sys.Date())) {
  tracker <- read_tracker()
  hit <- tracker$issue_id %in% issue_ids & tracker$status == "pending"
  tracker$status[hit] <- "sent"
  tracker$last_batch_date[hit] <- batch_date
  write_tracker(tracker)
  invisible(sum(hit))
}

# Records a resolution against one issue_id - called from ingestion
# (eventually verify_data_recovery_response.py, via issue_tracker.py) once
# a partner's response for that row has passed verification.
# new_status must be one of confirmed/rejected/contested.
#
# confirmed_by/recovery_type (added 2026-09-06): required in practice
# whenever new_status == "confirmed" (Jack: never leave who-confirmed to
# infer from a timeout - every confirmation traces to either "partner" or
# "internal_team" explicitly) or when resolving as a recovery rather than a
# confirmed deletion (recovery_type = false_positive | justified_exception).
# Not validated here as a hard stopifnot() - callers differ enough (partner
# appeal vs. internal_team no-appeal vs. a recovery) that enforcing a single
# required-argument shape at this shared layer would be more restrictive
# than helpful; pass what applies to the calling context.
#
# allow_reopen (added 2026-09-11): every real caller of this function used
# to independently re-derive its own "don't touch an already-terminal row"
# check before calling (verify_data_recovery_response.py's explicit guard,
# review_recovery_response.py's already_resolved(), etc.) - reimplemented
# 3+ times instead of living once here. Centralized: by default this
# function now REFUSES to overwrite a row already at a TERMINAL_STATUS
# (same warn-and-return-FALSE shape as the not-found case below), closing
# the actual gap that let an early version of register_deletion_log_issues.R
# clobber 10 partner-contested rows (see that incident's own history).
# Genuinely re-deciding an already-terminal row (e.g. moving a contested
# row to confirmed once a dispute is settled - a real, allowed transition
# per this file's schema notes above) requires the caller to explicitly
# pass allow_reopen = TRUE, so that path is visible at the call site rather
# than silently possible by default.
#
# resolution_date (fixed 2026-09-11): now NA-guarded like confirmed_by/
# recovery_type instead of unconditionally defaulting to Sys.Date() on
# every call. Previously, calling apply_resolution() a second time for the
# same issue_id on a different day silently advanced resolution_date even
# when no caller explicitly asked for that - a real audit-trail integrity
# gap. Now: an explicitly-passed resolution_date always wins; otherwise
# today's date is only written on a row's FIRST resolution (existing value
# NA) and a later call preserves whatever date is already there unless the
# caller opts in with an explicit value.
apply_resolution <- function(issue_id, new_status, resolution = NA_character_,
                              resolution_date = NULL,
                              confirmed_by = NA_character_, recovery_type = NA_character_,
                              allow_reopen = FALSE) {
  stopifnot(new_status %in% c("confirmed", "rejected", "contested"))
  tracker <- read_tracker()
  hit <- tracker$issue_id == issue_id
  if (!any(hit)) {
    warning("apply_resolution(): issue_id not found in tracker: ", issue_id)
    return(invisible(FALSE))
  }
  if (tracker$status[hit] %in% TERMINAL_STATUSES && !allow_reopen) {
    warning(
      "apply_resolution(): issue_id ", issue_id, " is already at a terminal status ('",
      tracker$status[hit], "') - refusing to overwrite. Pass allow_reopen = TRUE if this ",
      "is a deliberate re-decision (e.g. settling a contested row to confirmed)."
    )
    return(invisible(FALSE))
  }
  tracker$status[hit] <- new_status
  tracker$resolution[hit] <- resolution
  if (!is.null(resolution_date)) {
    tracker$resolution_date[hit] <- resolution_date
  } else {
    needs_date <- hit & is.na(tracker$resolution_date)
    tracker$resolution_date[needs_date] <- as.character(Sys.Date())
  }
  if (!is.na(confirmed_by)) tracker$confirmed_by[hit] <- confirmed_by
  if (!is.na(recovery_type)) tracker$recovery_type[hit] <- recovery_type
  write_tracker(tracker)
  invisible(TRUE)
}

# The set of issue_ids NOT yet resolved (pending/sent/rejected) - what a
# new generation run should still include on a sheet, scoped optionally to
# one partner and/or one issue type.
get_unresolved_issue_ids <- function(org_id = NULL, issue_type = NULL) {
  tracker <- read_tracker()
  if (!is.null(org_id)) tracker <- tracker %>% filter(.data$org_id == !!org_id)
  if (!is.null(issue_type)) tracker <- tracker %>% filter(.data$issue_type == !!issue_type)
  tracker %>% filter(!.data$status %in% TERMINAL_STATUSES) %>% pull(issue_id)
}
