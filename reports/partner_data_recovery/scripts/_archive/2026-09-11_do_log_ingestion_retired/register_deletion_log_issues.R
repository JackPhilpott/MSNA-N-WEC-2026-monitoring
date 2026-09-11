# ==============================================================================
# RETIRED 2026-09-11 (Jack, explicit decision): moved here from
# reports/partner_data_recovery/scripts/register_deletion_log_issues.R.
# By this date, every one of the six reasons deletion_log.R could emit had
# already been independently replaced by cleaning/real/
# independent_deletion_checks.R (see 2_monitoring/CLAUDE.md's "Independent
# deletion checks" section) - this script's daily-ingestion path had become
# a structural no-op (its own filter, lines ~147 below, dropped all six
# reasons before anything reached register_issues()), and its one genuinely
# live job, the CONFIRMED_QUALITY_EXCLUSIONS.csv one-time legacy bridge
# (lines ~218-266 below), had already fully executed - verified 2026-09-11
# that all 578 legacy uuids are already present in
# recovery_issue_tracker.csv, so nothing is lost by retiring this. Jack's
# broader call, not specific to this one script: the DO's deletion-log
# pipeline can no longer be trusted as an input, and this project should
# stop depending on it entirely rather than keep an inert bridge script
# live and risk it being mistaken for still-running. Kept here (not
# deleted) so the mechanism can be revived if ever needed - see git
# history / this file's own prior header below for the full original
# design and incident history. deploy_dashboard.R's source() call and
# 2_monitoring/CLAUDE.md's reference to this script were both updated to
# match at the same time.
# ==============================================================================
#
# ==============================================================================
# Wires the data officer's daily automatic deletion log (deletion_log.R /
# build_deletion_log(), in cleaning/MSNA_Data_Cleaning/ - NOT modified here,
# see this workspace's standing rule: build data-quality fixes in
# 2_monitoring's own scripts, not upstream) into the tracker's
# register_issues(), replacing the one-time 2026-09-03 pilot with continuous
# population. Read-only against the data officer's pipeline: this script only
# reads their already-written daily output files.
#
# ---- Sources (read-only) ----------------------------------------------------
# - cleaning/MSNA_Data_Cleaning/output/checking/db/deletion/
#     *_deletion_log_full_dataset.xlsx - one file per day the data officer's
#     Ak_data_cleaning_msna.R has run, written by writexl::write_xlsx() (not
#     openxlsx - no dangling-drawing-reference repair needed here). Columns:
#     uuid, org_id, enum_id, admin1, admin2, today, reason, all_reasons,
#     Data_Feedback, change_type. ALL files are processed every run, not just
#     the latest - register_issues() is idempotent (re-seeing the same
#     uuid+reason just bumps last_batch_date/rounds_outstanding), so this is
#     the safe way to backfill on a first-ever run without a separate
#     one-time script.
# - data/real_submissions.csv - joined by uuid (their column) ==
#     submission_uuid (ours) purely to attach matched_cluster_id/
#     matched_strata_id, which the data officer's own file doesn't carry
#     (their admin1/admin2 are raw submitted pcodes, not our post-hoc
#     GPS-matched cluster/strata - see prep_real_submissions.R's header for
#     why that matching has to happen on our side at all).
#
# ---- What this registers -----------------------------------------------------
# One issue_type="confirmed_deletion" tracker row per uuid (matching
# build_deletion_log()'s own one-row-per-uuid dedup - its `reason` column is
# already the priority-selected root cause, not a list), with `deletion_reason`
# set to that same reason code (no_consent | duration_under_20 |
# duplicate_point | listing_missing | pct_missing_flagged | fcs_zero - the
# ACTUAL values build_deletion_log() emits, confirmed by reading that file
# directly rather than assumed).
#
# duration_under_20/fcs_zero (NO_APPEAL_DELETION_REASONS, issue_tracker.R) are
# validated methodology thresholds, not partner judgment calls (Jack,
# 2026-09-06 refinement) - registered same as everything else, then
# IMMEDIATELY resolved as confirmed/internal_team, never left at pending. This
# is applied to every no-appeal row every run (not just freshly-inserted
# ones) - apply_resolution() is idempotent (re-confirming an already-confirmed
# row is a harmless no-op), so this stays correct even if the wiring is run
# more than once against the same file, or against a row that predates this
# script's first run.
#
# Usage: Rscript reports/partner_data_recovery/scripts/register_deletion_log_issues.R
# ==============================================================================
suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(readr)
  library(purrr)
})

source("reports/partner_data_recovery/scripts/issue_tracker.R")

DELETION_LOG_DIR <- "cleaning/MSNA_Data_Cleaning/output/checking/db/deletion"

deletion_files <- list.files(DELETION_LOG_DIR, pattern = "_deletion_log_full_dataset\\.xlsx$", full.names = TRUE)
if (length(deletion_files) == 0) {
  stop("register_deletion_log_issues(): no deletion log files found in ", DELETION_LOG_DIR)
}

# org_id renamed on read (submission_org_id): all_del below already carries
# its own org_id (from the deletion log's own meta join) - joining this
# object against it unrenamed would collide and force dplyr to suffix BOTH
# into org_id.x/org_id.y, breaking that block's own `org_id = org_id`
# reference (hit exactly this while adding the legacy-exclusions bridge
# below, which needs org_id from here since CONFIRMED_QUALITY_EXCLUSIONS.csv
# doesn't carry one of its own).
submissions <- read_csv("data/real_submissions.csv", show_col_types = FALSE,
                         col_types = cols_only(submission_uuid = "c", org_id = "c", matched_cluster_id = "c", matched_strata_id = "c")) %>%
  rename(submission_org_id = org_id)

all_del <- map_dfr(deletion_files, function(f) {
  df <- read_excel(f)
  if (nrow(df) == 0) return(tibble())
  df$source_file <- basename(f)
  df
})

if (nrow(all_del) == 0) {
  cat("register_deletion_log_issues(): every deletion log file was empty - nothing to register.\n")
  quit(save = "no", status = 0)
}

# BUG FIX 2026-09-06 19:20: this used to be arrange(uuid, source_file) (source
#_file ascending), and distinct() keeps the FIRST row per group - i.e. the
# EARLIEST file, the opposite of "most recently-seen" as this comment always
# claimed. Didn't cause visible damage via this exact path in the one case
# checked (no uuid's `reason` was found to flip across files in the sample
# traced), but it's still backwards and a live risk for the next uuid whose
# classification genuinely changes between two files. desc(source_file) keeps
# the LATEST file per uuid, matching the intent below.
#
# duration_under_30 filtered out here (2026-09-06 19:20, real bug found by
# the coordinating session + 8d): it's a RETIRED reason string, not a current
# rule - deletion_log.R's duration floor moved from 30 to 20 minutes on
# 2026-09-01, and every uuid ever labeled duration_under_30 across all 27
# files on disk comes from files dated before that change, with zero of them
# reappearing under any reason afterward. That means the data officer's
# current rules no longer consider these interviews flagged at all (most are
# likely candidates for the still-unbuilt 20-30min "evaluate/contest" band,
# tomorrow's separate work - not an automatic no-appeal deletion). Dropping
# entirely rather than registering-as-pending: registering them would put
# them in front of partners as an appeal item for a rule that no longer
# exists, which is its own kind of wrong.
# fcs_zero DROPPED 2026-09-10 (Jack): downgraded from an automatic no-appeal
# deletion to a plain logical-error flag, doing nothing in the deletion
# pipeline any more - the interview is kept as long as it clears every OTHER
# criterion. Same drop-at-ingestion treatment as duration_under_30 below
# (never registered under any status, not even pending) rather than left in
# the tracker as a live reason nobody acts on.
#
# no_consent / duration_under_20 / duplicate_point DROPPED 2026-09-10/11
# (Jack: stop depending on the DO's pipeline entirely, reason by reason) -
# moved to cleaning/real/independent_deletion_checks.R. no_consent computes
# directly from real_submissions.csv's own interview_outcome (already derived
# straight from the raw KoBo consent answer, zero DO dependency needed) -
# found the DO's log missed 11 of 31 real consent-refused interviews (35%), a
# reason with zero judgment call involved. duration_under_20 reuses
# audit_duration.R's independent recompute (same cleaningtools method, our
# own audit.zip read, not the DO's cache/execution). duplicate_point (KEY-
# BASED half only - see independent_deletion_checks.R's header for the still-
# open GPS-proximity question) reuses prep_real_submissions.R's own
# is_duplicate, the same identifier logic as the DO's own check_duplicate_
# cluster_visits() check #1 - found 415 completed key-based duplicates the
# DO's pipeline had never flagged at all, on top of the 707 it already had.
# percentage_missing / listing_missing ALSO DROPPED 2026-09-11, completing
# the reason-by-reason replacement: listing_missing reuses the same raw HH
# Listing tool export the DO's own check_listing_linkage() L1 check reads
# (found 518 completed IDP rows with no listing submission for their cluster
# that the DO's pipeline had never flagged); percentage_missing reuses the
# same cleaningtools statistical-outlier method (strongness_factor=8) against
# our own read of the raw anonymised export + kobo XLSForm - closes zero
# additional gap TODAY (every current outlier is a consent_refused row
# already caught by no_consent) but stays live for whatever a future dataset
# might surface. All six deletion_log.R reasons are now independently
# recomputed on 2_monitoring's own side - this script's ONLY remaining job is
# the one-time legacy CONFIRMED_QUALITY_EXCLUSIONS.csv bridge below, which is
# itself a permanent no-op once absorbed. Dropped here rather than left
# dual-sourced, to avoid two mechanisms ever disagreeing about the same
# reason - run independent_deletion_checks.R ALONGSIDE this script (order
# doesn't matter between the two scripts, both idempotent).
uuids_before <- unique(all_del$uuid)
all_del <- all_del %>% filter(!reason %in% c("duration_under_30", "fcs_zero", "no_consent", "duration_under_20", "duplicate_point", "listing_missing", "pct_missing_flagged"))
n_stale_dropped <- length(setdiff(uuids_before, unique(all_del$uuid)))
if (n_stale_dropped > 0) {
  cat(sprintf("register_deletion_log_issues(): dropped %d uuid(s) whose only classification across all files was a retired/downgraded/independently-replaced reason (duration_under_30, fcs_zero, no_consent, duration_under_20, duplicate_point, listing_missing, or pct_missing_flagged).\n", n_stale_dropped))
}

new_issues <- all_del %>%
  arrange(uuid, desc(source_file)) %>%
  distinct(uuid, .keep_all = TRUE) %>%
  left_join(submissions, by = c("uuid" = "submission_uuid")) %>%
  transmute(
    issue_type = "confirmed_deletion",
    deletion_reason = reason,
    org_id = org_id,
    cluster_id = matched_cluster_id,
    strata_id = matched_strata_id,
    uuid = uuid,
    listing_number = NA_character_,
    notes = Data_Feedback
  )

n_unmatched <- sum(is.na(new_issues$cluster_id))
if (n_unmatched > 0) {
  cat(sprintf(
    "register_deletion_log_issues(): %d of %d flagged uuid(s) had no matching row in real_submissions.csv - registered with cluster_id/strata_id = NA (still usable for appeal/workbook purposes, just without cluster attribution).\n",
    n_unmatched, nrow(new_issues)
  ))
}

result <- register_issues(new_issues)

# CAUTION (bug found + fixed 2026-09-06, real data affected - see git history/
# session log): apply_resolution() unconditionally overwrites whatever row it
# finds - unlike register_issues(), which explicitly refuses to touch a row
# already at a TERMINAL_STATUS. An earlier version of this loop called
# apply_resolution() for every no-appeal-reason row in TODAY's deletion log
# data regardless of the TRACKER's current status, which clobbered 10 rows a
# partner had contested and Jack had already reviewed and rejected -
# replacing their detailed contest-review resolution text with a generic
# auto-confirm note. An automated rule must never overwrite a status a human
# already set, by any path (confirmed OR contested) - only ever act on a row
# still genuinely open. Re-checking the CURRENT tracker state (not
# new_issues' own re-derived-from-today's-file value) before each call.
no_appeal_rows <- new_issues %>% filter(deletion_reason %in% NO_APPEAL_DELETION_REASONS)
n_auto_confirmed <- 0L
n_already_decided <- 0L
if (nrow(no_appeal_rows) > 0) {
  ids <- mapply(build_issue_id, no_appeal_rows$issue_type, no_appeal_rows$uuid, no_appeal_rows$cluster_id, no_appeal_rows$listing_number)
  # Single read + single write for the whole batch, not one apply_resolution()
  # round-trip per row (that was the whole file's read+write, per row - with
  # ~1,700 rows this took minutes for what should be under a second).
  # apply_resolution() itself stays the single-row API for its real callers
  # (a human reviewing one workbook row at a time) - this bulk path is
  # specific to this script's genuinely-bulk need.
  current <- read_tracker()
  already_terminal <- current$status %in% TERMINAL_STATUSES
  hit <- current$issue_id %in% ids & !already_terminal
  current$status[hit] <- "confirmed"
  current$resolution[hit] <- "validated methodology threshold, no appeal"
  current$resolution_date[hit] <- as.character(Sys.Date())
  current$confirmed_by[hit] <- "internal_team"
  n_auto_confirmed <- sum(hit)
  n_already_decided <- sum(current$issue_id %in% ids & already_terminal)
  if (n_auto_confirmed > 0) write_tracker(current)
}

cat(sprintf(
  "register_deletion_log_issues(): processed %d deletion log file(s), %d unique uuid(s); %d auto-confirmed, %d already had a human decision and were left untouched (no-appeal reasons: %s).\n",
  length(deletion_files), nrow(new_issues), n_auto_confirmed, n_already_decided, paste(NO_APPEAL_DELETION_REASONS, collapse = ", ")
))

# ---- one-time bridge: absorb data/CONFIRMED_QUALITY_EXCLUSIONS.csv's legacy
# rows (2026-09-06) -----------------------------------------------------------
# Found while building the overlay this feeds (see cleaning/real/
# build_confirmed_deletions_overlay.R): 82 real, still-live uuids in the old
# static exclusions file are NOT covered by deletion_log.R's daily output
# (that file's own audit-based duration computation predates/differs from
# what the 27 daily files above cover) - cutting the overlay over to the
# tracker alone, without this, would have silently un-excluded 82
# legitimately-excluded submissions back into Achieved. This block is a
# ONE-TIME bridge: it registers whatever's still uncovered, then (thanks to
# register_issues()'s own de-dup) becomes a permanent no-op on every future
# run once everything's absorbed - CONFIRMED_QUALITY_EXCLUSIONS.csv itself is
# not deleted (harmless to leave; nothing reads it any more after this).
legacy_path <- "data/CONFIRMED_QUALITY_EXCLUSIONS.csv"
if (file.exists(legacy_path)) {
  legacy <- read_csv(legacy_path, show_col_types = FALSE) %>% distinct(uuid, .keep_all = TRUE)
  legacy_issues <- legacy %>%
    left_join(submissions, by = c("uuid" = "submission_uuid")) %>%
    transmute(
      issue_type = "confirmed_deletion", deletion_reason = reason, org_id = submission_org_id,
      cluster_id = matched_cluster_id, strata_id = matched_strata_id, uuid = uuid,
      listing_number = NA_character_,
      notes = paste0("Absorbed from legacy data/CONFIRMED_QUALITY_EXCLUSIONS.csv (", detail, ", computed ", date_computed, ")")
    )
  legacy_result <- register_issues(legacy_issues)
  legacy_ids <- mapply(build_issue_id, legacy_issues$issue_type, legacy_issues$uuid, legacy_issues$cluster_id, legacy_issues$listing_number)
  current2 <- read_tracker()
  # BUG FIX 2026-09-06 19:20: matching by issue_id (uuid) alone isn't enough -
  # confirmed_deletion identity is one row per UUID, not per (uuid, reason)
  # (build_issue_id() never includes deletion_reason), so a uuid legitimately
  # in the legacy file under duration_under_20/fcs_zero can ALSO be the same
  # uuid as an unrelated, still-open issue in the live tracker under a
  # completely different reason (e.g. duplicate_point) - register_issues()
  # above does not overwrite an existing row's deletion_reason, so
  # current2$deletion_reason still correctly reflects whichever reason is
  # actually live for that uuid. Found 2026-09-06: this exact gap had
  # auto-confirmed 4 duplicate_point issues as "validated methodology
  # threshold, no appeal" - a reason they never carried. Requiring the
  # TRACKER's own current deletion_reason (not the legacy file's) to be a
  # genuine no-appeal reason closes this.
  hit2 <- current2$issue_id %in% legacy_ids & !current2$status %in% TERMINAL_STATUSES & current2$deletion_reason %in% NO_APPEAL_DELETION_REASONS
  current2$status[hit2] <- "confirmed"
  current2$resolution[hit2] <- "validated methodology threshold, no appeal (legacy exclusions file)"
  current2$resolution_date[hit2] <- as.character(Sys.Date())
  current2$confirmed_by[hit2] <- "internal_team"
  if (sum(hit2) > 0) write_tracker(current2)
  cat(sprintf("register_deletion_log_issues(): legacy exclusions bridge - %d row(s) from CONFIRMED_QUALITY_EXCLUSIONS.csv, %d newly confirmed.\n",
              nrow(legacy_issues), sum(hit2)))
}
