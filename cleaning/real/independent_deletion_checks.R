################################################################################
# independent_deletion_checks.R - deletion-log reasons computed entirely on
# 2_monitoring's own side, built 2026-09-10/11.
################################################################################
# WHY THIS EXISTS
# ------------------------------------------------------------------------------
# Jack, 2026-09-10/11: stop depending on the data officer's deletion log
# pipeline at all, for every reason, not just duration (see audit_duration.R,
# built first). Found and quantified real, substantial under-flagging across
# multiple reasons tonight - no_consent alone missed 11 of 31 real
# consent-refused interviews (35%), a reason with zero judgment call
# involved, so there's no "different methodology" explanation available.
#
# The DEEPER reason this happens, found while tracing deletion_log.R's own
# report_dates logic: each day's deletion-log file is a PERMANENT, NEVER
# REGENERATED snapshot, filtered to rows whose OWN submission date matches
# that day. If a given day's run doesn't fully complete (errors, a partial
# data pull, whatever), that day's flags are gone forever - no LATER day's
# run ever goes back and fills in what an earlier day's run missed, because
# every later run only ever looks at its OWN day's rows for the OUTPUT filter
# (the underlying checks that need full-dataset context, like duplicate_point
# and percentage_missing, DO look at the whole history every time - it's
# specifically the day-snapshot OUTPUT step that's fragile). This script
# avoids that failure mode entirely by never filtering to "today" at all -
# every run recomputes fresh against the CURRENT full dataset and registers
# via issue_tracker.R's own idempotent register_issues(), so a submission
# can never permanently fall through a single bad day.
#
# ---- Build order (Jack's agreed sequence) -----------------------------------
#   1. no_consent (this file, DONE) - already 100% independently computed by
#      prep_real_submissions.R itself (interview_outcome is derived directly
#      from the raw KoBo consent answer, not from anything DO-sourced) - zero
#      new computation needed, just register it from OUR OWN data instead of
#      reading the DO's deletion log for it. NO-APPEAL, auto-confirmed as of
#      2026-09-11 (Jack, confirmed directly: "these are the only two
#      automatic deletion/removal records which don't need further
#      verification or approval", alongside duration_under_20) - this
#      REVERSES the original build decision (kept appealable, matching how
#      no_consent had always been handled project-wide) per an explicit,
#      separate policy call, not implied by "compute it ourselves instead of
#      trusting the DO's copy of it".
#   2. duration_under_20 (this file, DONE) - reuses cleaning/real/
#      audit_duration.R's compute_our_audit_durations() (same cleaningtools
#      method the DO uses, run independently against our own audit.zip read,
#      cached separately). NO-APPEAL, auto-confirmed - same policy as
#      before, just no longer dependent on the DO's execution/cache
#      reliability for whether a genuinely-short interview ever gets caught.
#   3. duplicate_point - KEY-BASED HALF DONE (this file), 2026-09-11. Reuses
#      prep_real_submissions.R's own is_duplicate (dup_key: non_idp_point_id,
#      or idp_cluster_id+listing/walk-slot for IDP; dup_rank>1 = later
#      submission to an already-used slot) - the SAME identifier logic as the
#      DO's own check_duplicate_cluster_visits() check #1 (gps_cluster_checks.R,
#      "same_assigned_point"), just computed on our own side instead of
#      trusting their per-day report_dates output. Verified gap before
#      building: 1,232 completed rows are key-based duplicates on our side;
#      only 707 had ANY duplicate_point tracker row (698 matching ours + 109
#      correctly deferred to duration_under_20 by priority order), leaving 415
#      real duplicates the DO's pipeline had never flagged at all. (4 uuids run
#      the other way - DO flagged duplicate_point, our key logic doesn't
#      reproduce them - left as-is, not investigated further, too small to
#      matter next to the 415.) Appealable, NOT auto-confirmed - matches how
#      duplicate_point has always been handled (never in
#      NO_APPEAL_DELETION_REASONS).
#
#      GPS-proximity matching (checks #2/#3 of gps_cluster_checks.R,
#      "different_point_proximity"/"possible_same_household") is DELIBERATELY
#      NOT built here - two real blockers found 2026-09-11, not a skipped step:
#        (a) Data: raw _geopoint_latitude/_geopoint_longitude does not exist
#            anywhere in 2_monitoring's own anonymised export - the ONLY
#            source is the DO's own cleaning/MSNA_Data_Cleaning/output/
#            checking/internal_audit/spatial_duplicate_audit_<date>.xlsx
#            files, which are THEMSELVES permanent per-day snapshots (same
#            report_dates structural flaw as deletion_log.R - see
#            Ak_data_cleaning_msna.R:723-724). Only 24 of ~31 possible days
#            exist on disk; missing exactly the same 2026-08-29/09-05 gap
#            already found via duration/duplicate_point, plus 08-22, 09-01,
#            09-02, 09-10. Unioning all 24 gets close to full historical
#            coverage but can't close those gap-day blind spots.
#        (b) Methodology: the DO's OWN pipeline deliberately excludes both
#            proximity checks from automatic deletion and the field log
#            entirely (Ak_data_cleaning_msna.R:730-742) - in their own words,
#            "191 of 209 [possible_same_household] rows were IDP, where
#            households inside one cluster legitimately sit a median of 8.5m
#            apart" - kept as an internal-only signal, not actionable. Spot-
#            checked the 2026-09-09 file directly: possible_same_household is
#            2,530 of 2,778 rows (91%) - the same high-noise ratio the DO's
#            own comment describes. Building this as an automatic-deletion
#            signal would go further than the DO's own validated methodology
#            ever has, with a known, quantified false-positive rate - Jack's
#            call, not assumed.
#      Jack's decision (2026-09-11): skip GPS-proximity for now. Revisit only
#      if a real raw-GPS source becomes available - not worth inheriting a
#      known ~91% false-positive rate the DO themselves avoid for the same
#      reason.
#   4. percentage_missing - DONE (this file), 2026-09-11. Reuses cleaning/
#      real/audit_missingness.R's compute_our_missingness() (same
#      cleaningtools::add_percentage_missing()/check_percentage_missing()
#      methodology the DO uses, strongness_factor=8, a statistical-outlier
#      flag not a literal cutoff - confirmed by reading deletion_log.R's own
#      comment at that call site - run against our own read of the raw
#      anonymised export + the DO's kobo tool XLSForm). Checked before
#      building: only 31 rows are flagged as outliers on the current dataset
#      at all, and EVERY one of them is a consent_refused row (~95% missing,
#      as expected - a refused interview barely answers anything), already
#      covered by no_consent at higher priority. Zero completed rows are
#      currently affected - this check closes no gap today, but is wired up
#      anyway (idempotent, cheap, matches the "never depend on the DO's
#      execution reliability" reasoning for the others) so a genuinely-
#      completed high-missingness row (e.g. a real device-sync issue) would
#      get caught the moment it exists, not only if/when someone remembers to
#      check. Appealable, NOT auto-confirmed (matches existing policy - never
#      in NO_APPEAL_DELETION_REASONS).
#   5. missing_hh_listing (was mistakenly built as listing_missing) - DONE,
#      corrected 2026-09-11 same night. Reuses the SAME identifier logic as
#      the DO's check_listing_linkage() L1 check (listing_link_checks.R): an
#      IDP interview's matched_cluster_id has ZERO submissions at all in the
#      raw HH Listing tool export (cleaning/MSNA_Data_Cleaning/Kobo Downloads/
#      hh_listing_tool/hh_listing.xlsx, already read read-only elsewhere by
#      reports/partner_data_recovery/scripts/real_hh_listing.R).
#
#      CORRECTION (Coordinator's independent review + reconciled directly):
#      this condition ("cluster has zero listing submissions") is a CLUSTER-
#      LEVEL process gap - no single interview from that cluster is
#      individually at fault - so it registers as issue_type=
#      "missing_hh_listing" (cluster-keyed, uuid=NA, zero Achieved impact),
#      NOT as confirmed_deletion/listing_missing (interview-level,
#      Achieved-impacting). Originally built the wrong shape earlier the same
#      night (one confirmed_deletion/listing_missing row per INTERVIEW,
#      518 of them) before this was caught and fixed - see run_independent_
#      listing_missing_check()'s own comment for the corrected logic.
#
#      There is genuinely NO current check anywhere (ours or the DO's) for
#      "cluster HAS a listing but this specific interview's household number
#      isn't among the drawn set" - that would be the DO's own L4 check
#      (listing_link_checks.R), REMOVED 20 Aug 2026, confirmed by reading
#      that file's own header. So every listing_missing-flavored row, ours or
#      the DO's historical ones, has only ever meant one thing: zero listing
#      for the whole cluster.
#
#      Reconciliation numbers (2026-09-11): 780 rows (518 ours + 262 from the
#      DO's historical listing_missing registrations, pre-dating this file,
#      still zero-listing today) across 62 distinct clusters converted to
#      62 missing_hh_listing rows. A separate 113 rows (17 clusters, mostly
#      FACT=63/NRC=31) were flagged zero-listing on 2026-09-06 by the OLD
#      DO-log path but have SINCE gained a listing submission - Jack's
#      decision: leave these 113 exactly as they are (confirmed_deletion/
#      listing_missing, appealable) rather than convert them - the cluster-
#      level gap closed, but whether each specific interview's claimed
#      household actually matches the now-existing listing can't be verified
#      without rebuilding the DO's removed L4 check, so they stay in the
#      normal per-interview appeal flow rather than being silently resolved
#      or silently converted.
#
#   6. date_outlier - DONE, 2026-09-11. Was never a DO reason at all - a
#      2026-08-27 finding of ours (a device clock wrong at the START of an
#      interview, e.g. reading 2022 instead of 2026). Previously EXCLUDED
#      the row entirely in prep_real_submissions.R (no tracker row, no
#      appeal path, worse than a no-appeal deletion - the interview just
#      vanished with no trace). Fixed 2026-09-11: prep_real_submissions.R
#      now keeps the row (nulling only submission_date/start_datetime, the
#      genuinely-corrupted absolute-clock fields - duration_min is left
#      alone, since it's audit-log-derived, a relative measure unaffected
#      by an absolute clock offset) and sets flag_date_outlier so this check
#      can find it. Appealable, NOT auto-confirmed (same policy as
#      duplicate_point/pct_missing_flagged/crs_unmatched below - a data
#      quality issue with a real judgment call, not a validated methodology
#      threshold).
#   7. crs_unmatched - DONE, 2026-09-11. A completed interview that never
#      matched to any pre-assigned sample point at all
#      (match_quality=="unmatched_no_point_id" - already computed by
#      prep_real_submissions.R, just never independently checked/tracked
#      before). 27 such rows currently exist, all CRS, all missing
#      matched_cluster_id/pop_type too (a real, more fundamental matching
#      gap than the other reasons - worth knowing when reviewing these, not
#      just "GPS didn't quite line up"). Appealable, NOT auto-confirmed.
#
# register_deletion_log_issues.R (the DO-log-reading script) has had
# no_consent removed from what it ingests from the DO's file, to avoid two
# competing sources of truth for the same reason - see that file's own
# comment at the removal point.
#
# Usage: Rscript cleaning/real/independent_deletion_checks.R
#    or: source("cleaning/real/independent_deletion_checks.R")
################################################################################
suppressPackageStartupMessages({library(dplyr); library(readr)})
source("reports/partner_data_recovery/scripts/issue_tracker.R")

DURATION_FLOOR_MINUTES <- 20 # matches the DO's own DELETION_DURATION_FLOOR (deletion_log.R) - same policy number, independent computation
# BUG FIX 2026-09-11: DATE_OUTLIER_MIN is prep_real_submissions.R's own
# constant, not in scope here when this script runs standalone (Rscript,
# not sourced from that file) - run_independent_date_outlier_check()'s notes
# text needs its own copy, same duplication pattern as DURATION_FLOOR_MINUTES
# above. Keep in sync with prep_real_submissions.R's own value if it ever
# changes - this copy is display-text only, not the actual flagging logic
# (that's flag_date_outlier, already computed by prep_real_submissions.R).
DATE_OUTLIER_MIN <- as.Date("2026-08-01")

run_independent_duration_check <- function() {
  source("cleaning/real/audit_duration.R")
  subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE, guess_max = 100000)
  completed <- subs %>% filter(interview_outcome == "completed")

  # Full-dataset call - the cache (cleaning/real/audit_duration_cache.csv)
  # means this only actually parses uuids not already cached, so repeat runs
  # are fast. verbose=FALSE here - the per-500 progress messages are useful
  # for a slow first build, just noise on every subsequent daily run.
  durations <- compute_our_audit_durations(verbose = FALSE)

  short <- completed %>%
    inner_join(durations, by = c("submission_uuid" = "uuid")) %>%
    filter(!is.na(duration_audit_sum_all_minutes), duration_audit_sum_all_minutes < DURATION_FLOOR_MINUTES)

  n_no_audit <- sum(!completed$submission_uuid %in% durations$uuid)
  if (n_no_audit > 0) {
    cat(sprintf(
      "independent_deletion_checks(): duration - %d completed submission(s) have no audit.csv in the ZIP yet (device not synced, or a genuinely older/edge-case record) - left unflagged, not treated as short.\n",
      n_no_audit
    ))
  }

  new_issues <- short %>%
    transmute(
      issue_type = "confirmed_deletion",
      deletion_reason = "duration_under_20",
      org_id = org_id,
      cluster_id = matched_cluster_id,
      strata_id = matched_strata_id,
      uuid = submission_uuid,
      listing_number = NA_character_,
      notes = paste0(
        "Interview duration was ", round(duration_audit_sum_all_minutes, 1), " minutes, under the ",
        DURATION_FLOOR_MINUTES, "-minute floor. Computed independently via cleaning/real/audit_duration.R ",
        "(same cleaningtools::create_duration_from_audit_sum_all() method the data officer's own pipeline uses, ",
        "run against our own read of the raw audit trail) - not sourced from the data officer's deletion log."
      )
    )

  result <- register_issues(new_issues)

  # Auto-confirm (no-appeal, matches NO_APPEAL_DELETION_REASONS) - same bulk
  # pattern as register_deletion_log_issues.R's own no-appeal block: only
  # touch rows still genuinely open, never overwrite a human decision
  # (confirmed OR contested) that already exists.
  n_auto_confirmed <- 0L
  if (nrow(new_issues) > 0) {
    ids <- mapply(build_issue_id, new_issues$issue_type, new_issues$uuid, new_issues$cluster_id, new_issues$listing_number)
    current <- read_tracker()
    already_terminal <- current$status %in% TERMINAL_STATUSES
    hit <- current$issue_id %in% ids & !already_terminal
    current$status[hit] <- "confirmed"
    current$resolution[hit] <- "validated methodology threshold, no appeal (independently computed)"
    current$resolution_date[hit] <- as.character(Sys.Date())
    current$confirmed_by[hit] <- "internal_team"
    n_auto_confirmed <- sum(hit)
    if (n_auto_confirmed > 0) write_tracker(current)
  }

  cat(sprintf(
    "independent_deletion_checks(): duration_under_20 - %d completed row(s) under %d min (of %d with a real audit duration available), %d newly auto-confirmed this run.\n",
    nrow(new_issues), DURATION_FLOOR_MINUTES, nrow(durations), n_auto_confirmed
  ))
  invisible(new_issues)
}

run_independent_no_consent_check <- function() {
  subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE, guess_max = 100000)

  no_consent_rows <- subs %>% filter(interview_outcome == "consent_refused")

  new_issues <- no_consent_rows %>%
    transmute(
      issue_type = "confirmed_deletion",
      deletion_reason = "no_consent",
      org_id = org_id,
      cluster_id = matched_cluster_id,
      strata_id = matched_strata_id,
      uuid = submission_uuid,
      listing_number = NA_character_,
      notes = "Household did not consent to the interview - computed independently from real_submissions.csv's own interview_outcome (derived directly from the raw KoBo consent answer), not sourced from the data officer's deletion log."
    )

  result <- register_issues(new_issues)

  # Auto-confirm, no-appeal - policy change 2026-09-11 (Jack, via Coordinator
  # session, confirmed directly with Jack in this session before executing):
  # "these are the only two automatic deletion/removal records which don't
  # need further verification or approval" (no_consent + duration_under_20).
  # Reverses this file's own earlier reasoning (see header comment for build
  # order item 1) that no_consent should stay appealable "matching how every
  # no_consent item has actually been handled all along this project" - that
  # was true until this explicit policy decision superseded it. Same bulk
  # pattern as run_independent_duration_check()'s own auto-confirm block:
  # only touches rows not already at a TERMINAL_STATUS, never overwrites a
  # human decision.
  n_auto_confirmed <- 0L
  if (nrow(new_issues) > 0) {
    ids <- mapply(build_issue_id, new_issues$issue_type, new_issues$uuid, new_issues$cluster_id, new_issues$listing_number)
    current <- read_tracker()
    already_terminal <- current$status %in% TERMINAL_STATUSES
    hit <- current$issue_id %in% ids & !already_terminal
    current$status[hit] <- "confirmed"
    current$resolution[hit] <- "validated methodology threshold, no appeal (independently computed)"
    current$resolution_date[hit] <- as.character(Sys.Date())
    current$confirmed_by[hit] <- "internal_team"
    n_auto_confirmed <- sum(hit)
    if (n_auto_confirmed > 0) write_tracker(current)
  }

  cat(sprintf(
    "independent_deletion_checks(): no_consent - %d real consent-refused row(s) checked, %d newly auto-confirmed this run (no-appeal as of 2026-09-11).\n",
    nrow(new_issues), n_auto_confirmed
  ))
  invisible(new_issues)
}

run_independent_duplicate_check <- function() {
  subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE, guess_max = 100000)

  # completed only - a consent_refused row sharing a dup_key is already
  # covered by no_consent (higher priority, and registers first in the run
  # order below), and a non-completed row was never in Achieved to begin
  # with, so flagging it here would add tracker noise for nothing it changes.
  dup_rows <- subs %>% filter(interview_outcome == "completed", is_duplicate == TRUE)

  new_issues <- dup_rows %>%
    transmute(
      issue_type = "confirmed_deletion",
      deletion_reason = "duplicate_point",
      org_id = org_id,
      cluster_id = matched_cluster_id,
      strata_id = matched_strata_id,
      uuid = submission_uuid,
      listing_number = NA_character_,
      notes = paste0(
        "Later submission to an already-used assigned point/slot (dup_key), computed independently ",
        "via prep_real_submissions.R's own is_duplicate (same identifier logic as the data officer's ",
        "check_duplicate_cluster_visits() check #1, gps_cluster_checks.R) - not sourced from the data ",
        "officer's deletion log."
      )
    )

  result <- register_issues(new_issues)
  cat(sprintf(
    "independent_deletion_checks(): duplicate_point (key-based) - %d completed row(s) checked, registered/re-seen in tracker for all of them (idempotent - no change for ones already there). Left appealable, not auto-confirmed.\n",
    nrow(new_issues)
  ))
  invisible(new_issues)
}

run_independent_listing_missing_check <- function() {
  HH_LISTING_PATH <- "cleaning/MSNA_Data_Cleaning/Kobo Downloads/hh_listing_tool/hh_listing.xlsx"
  suppressPackageStartupMessages(library(readxl))

  subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE, guess_max = 100000)
  idp_completed <- subs %>% filter(interview_outcome == "completed", pop_type == "idp")

  listing <- read_excel(HH_LISTING_PATH, sheet = excel_sheets(HH_LISTING_PATH)[[1]], col_types = "text")
  # Same "has ANY submission at all" test as the DO's own L1 check
  # (listing_link_checks.R: is.na(n_listings) after grouping by
  # cluster_select) - deliberately not filtered to a "usable"/complete
  # submission the way real_hh_listing.R's pools are (that filter serves a
  # different purpose, the recovery-workbook dropdown pool, not this
  # existence check).
  listed_clusters <- unique(listing$cluster_select[!is.na(listing$cluster_select) & trimws(listing$cluster_select) != ""])

  no_listing <- idp_completed %>% filter(!matched_cluster_id %in% listed_clusters)

  # ISSUE-TYPE FIXED 2026-09-11 (Jack, via Coordinator's review + reconciled
  # directly here - see this function's git history / independent_deletion_
  # checks.R's own changelog for the full trace): this condition ("cluster
  # has ZERO listing submissions at all") is a CLUSTER-LEVEL process gap, not
  # a per-interview deletion reason - no single interview from that cluster
  # is individually at fault for the listing never having been submitted.
  # Registers as issue_type="missing_hh_listing" (cluster-keyed, uuid=NA,
  # zero Achieved impact - deletion_status is joined by uuid, so a uuid=NA
  # row structurally can never exclude any interview) rather than
  # confirmed_deletion/listing_missing. Still visible in the recovery
  # workbook (review_missing_hh_listings() in review_recovery_response.py
  # already has the handling for this issue_type) so partners can actually
  # go fix the listing gap - a re-route to the right existing mechanism, not
  # a drop.
  #
  # Originally built (2026-09-11, earlier same night) registering this same
  # condition as confirmed_deletion/listing_missing, one row per INTERVIEW -
  # wrong shape, corrected same night before any dashboard numbers were
  # reported externally. One-time migration of the rows that version already
  # wrote (plus historical DO-log-sourced listing_missing rows sharing the
  # exact same zero-listing condition) handled separately - see this file's
  # git history / the migration this comment accompanies, not repeated here
  # on every run.
  by_cluster <- no_listing %>%
    distinct(matched_cluster_id, org_id, matched_strata_id)

  new_issues <- by_cluster %>%
    transmute(
      issue_type = "missing_hh_listing",
      org_id = org_id,
      cluster_id = matched_cluster_id,
      strata_id = matched_strata_id,
      uuid = NA_character_,
      listing_number = NA_character_,
      notes = paste0(
        "No Household Listing submission found on the server for cluster '", matched_cluster_id,
        "' - computed independently against the raw HH Listing tool export, same identifier logic ",
        "as the data officer's check_listing_linkage() L1 check (listing_link_checks.R). Cluster-level ",
        "process gap, not an individual interview's fault - does not exclude any interview from Achieved."
      )
    )

  result <- register_issues(new_issues)
  cat(sprintf(
    "independent_deletion_checks(): missing_hh_listing - %d completed IDP row(s) across %d cluster(s) with no listing submission at all, registered/re-seen as cluster-level issues (idempotent - no change for ones already there). Zero Achieved impact by construction (uuid=NA).\n",
    nrow(no_listing), nrow(new_issues)
  ))
  invisible(new_issues)
}

run_independent_percentage_missing_check <- function() {
  source("cleaning/real/audit_missingness.R")
  pct <- compute_our_missingness(verbose = FALSE)
  subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE, guess_max = 100000)
  completed <- subs %>% filter(interview_outcome == "completed")

  outlier_rows <- completed %>%
    inner_join(pct %>% filter(is_outlier == TRUE), by = c("submission_uuid" = "uuid"))

  new_issues <- outlier_rows %>%
    transmute(
      issue_type = "confirmed_deletion",
      deletion_reason = "pct_missing_flagged",
      org_id = org_id,
      cluster_id = matched_cluster_id,
      strata_id = matched_strata_id,
      uuid = submission_uuid,
      listing_number = NA_character_,
      notes = paste0(
        "Flagged by cleaningtools::check_percentage_missing() as a statistical outlier for missingness ",
        "(strongness_factor = 8, this household's proportion of unanswered applicable questions is ",
        round(percentage_missing * 100, 1), "%) - computed independently via cleaning/real/audit_missingness.R, ",
        "not sourced from the data officer's deletion log."
      )
    )

  result <- register_issues(new_issues)
  cat(sprintf(
    "independent_deletion_checks(): pct_missing_flagged - %d completed row(s) flagged as a missingness statistical outlier (of %d outliers total, most already covered by no_consent - a refused interview is almost always the highest-missingness case), registered/re-seen in tracker for all of them. Left appealable, not auto-confirmed.\n",
    nrow(new_issues), sum(pct$is_outlier)
  ))
  invisible(new_issues)
}

run_independent_date_outlier_check <- function() {
  subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE, guess_max = 100000)

  # completed only - a consent_refused row with a bad clock is already
  # covered by no_consent at higher priority; flag_date_outlier itself is
  # computed in prep_real_submissions.R from the ORIGINAL start value,
  # before submission_date/start_datetime get nulled for these rows - see
  # that script's own "7b" step for why the row is kept instead of dropped.
  outlier_rows <- subs %>% filter(interview_outcome == "completed", flag_date_outlier == TRUE)

  new_issues <- outlier_rows %>%
    transmute(
      issue_type = "confirmed_deletion",
      deletion_reason = "date_outlier",
      org_id = org_id,
      cluster_id = matched_cluster_id,
      strata_id = matched_strata_id,
      uuid = submission_uuid,
      listing_number = NA_character_,
      notes = paste0(
        "Implausible submission_date (before ", format(DATE_OUTLIER_MIN, "%d %b %Y"), " or after today) - ",
        "almost always a device clock wrong at the start of the interview, not a real fielding date. ",
        "submission_date/start_datetime nulled in real_submissions.csv to avoid corrupting fielding-window/",
        "pace calculations; duration_min (audit-log-derived) is unaffected and left as-is. Previously this ",
        "row was silently excluded entirely (no tracker row, no appeal path) - now flagged and appealable."
      )
    )

  result <- register_issues(new_issues)
  cat(sprintf(
    "independent_deletion_checks(): date_outlier - %d completed row(s) with an implausible submission_date, registered/re-seen in tracker for all of them. Left appealable, not auto-confirmed.\n",
    nrow(new_issues)
  ))
  invisible(new_issues)
}

run_independent_unmatched_check <- function() {
  subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE, guess_max = 100000)

  # completed only, same reasoning as the other checks above. match_quality
  # is already computed by prep_real_submissions.R (case_when: "matched" /
  # "matched_gps_outlier" / "unmatched_no_point_id") - reused directly
  # rather than re-deriving is.na(matched_survey_id) by hand.
  unmatched_rows <- subs %>% filter(interview_outcome == "completed", match_quality == "unmatched_no_point_id")

  new_issues <- unmatched_rows %>%
    transmute(
      issue_type = "confirmed_deletion",
      deletion_reason = "crs_unmatched",
      org_id = org_id,
      # cluster_id genuinely NA for every row of this type as of 2026-09-11
      # (checked directly - all 27 current cases, all CRS, have no
      # matched_cluster_id or pop_type at all, a more fundamental matching
      # gap than a GPS-proximity miss) - register_issues()/the tracker
      # schema tolerate this; a reviewer will need to work out cluster
      # identity from other context (org_id, strata_id, raw submission) when
      # this comes up in the recovery workbook.
      cluster_id = matched_cluster_id,
      strata_id = matched_strata_id,
      uuid = submission_uuid,
      listing_number = NA_character_,
      notes = "Completed interview never matched to any pre-assigned sample point at all (match_quality == \"unmatched_no_point_id\") - could not be tied to a specific building/listing slot by GPS or claimed identity. Computed independently from real_submissions.csv's own match_quality column."
    )

  result <- register_issues(new_issues)
  cat(sprintf(
    "independent_deletion_checks(): crs_unmatched - %d completed row(s) with no sample-point match at all, registered/re-seen in tracker for all of them. Left appealable, not auto-confirmed.\n",
    nrow(new_issues)
  ))
  invisible(new_issues)
}

if (sys.nframe() == 0) {
  # Order matters: register_issues() only sets deletion_reason on a row's
  # FIRST insert, never on a re-seen one (issue_tracker.R) - so this order
  # must match the DO's own priority (no_consent > duration_under_20 >
  # duplicate_point > listing_missing > pct_missing_flagged) for any uuid
  # that happens to trip more than one check, or a lower-priority reason
  # could win the race and misclassify it. date_outlier/crs_unmatched
  # (added 2026-09-11) were never DO reasons, so they're appended at the
  # end rather than inserted into that existing priority order - a uuid
  # that also trips one of the original 5 keeps that reason, matching the
  # established "more specific/established reason wins" pattern.
  run_independent_no_consent_check()
  run_independent_duration_check()
  run_independent_duplicate_check()
  run_independent_listing_missing_check()
  run_independent_percentage_missing_check()
  run_independent_date_outlier_check()
  run_independent_unmatched_check()
}
