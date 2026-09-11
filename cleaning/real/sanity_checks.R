# Sanity checks on the daily real-data pipeline (2026-08-21) — added after
# an audit found essentially no purposeful data validation anywhere in the
# prep_real_submissions.R -> global.R -> dashboard chain: two existence-
# only file checks, a set of per-row quality FLAGS that never alert
# anyone, and a test suite that verifies the app's own arithmetic, not the
# incoming data's plausibility. The concrete risk: the data officer's
# upstream export changes shape or has a mistake, and it either silently
# degrades into a plausible-looking wrong number, or crashes with a
# generic/confusing R error - neither tells you what actually went wrong.
#
# Deliberately WARN, never hard-stop (confirmed with Jack 2026-08-21): a
# monitoring pipeline that can block itself from refreshing on a false
# positive is worse than one that flags a concern but still produces
# today's data. But a warning that only prints to a console and scrolls
# away is nearly as bad as no warning at all - so these write to a
# PERSISTENT file (data/SANITY_WARNINGS.txt) that every entry point in the
# daily workflow (this script, generate_partner_digest.R, deploy_dashboard.R,
# and — new 2026-08-21 — prep_partner_lga_assignment.R)
# checks and loudly re-announces for as long as it exists. It is never
# auto-cleared by a subsequent clean run - see clear_sanity_warnings.R at
# the project root. That's the "can't move past without acknowledging"
# behaviour without an actual blocking prompt (which would break running
# any of these non-interactively).
#
# Thresholds below are deliberately conservative - they're meant to catch
# obvious data errors (a negative duration, a household of 200), not to
# enforce eligibility/plausibility rules that are the cleaning team's job.
# Adjust freely if they prove too noisy or too loose in practice.

SANITY_WARNINGS_FILE <- "data/SANITY_WARNINGS.txt"

# Columns prep_real_submissions.R actually reads from the raw `main`
# sheet - keep in sync with that file if its own column usage changes.
# The two dynamic families (per-state repair columns) are checked by
# pattern, not by exact name, since their names vary by state.
REQUIRED_MAIN_COLUMNS <- c(
  "uuid", "meta.rootUuid", "org_id", "enum_id", "enum_gender", "enum_age",
  "admin1", "admin2", "admin3", "setting", "resp_gender", "resp_age",
  "resp_hoh_yn", "hoh_gender", "hoh_age", "hh_size", "consent", "start", "end",
  "_submission_time", "sample_pop_type_filter", "sample_status_filter",
  "non_idp_point_id", "idp_cluster_id", "idp_hh_number_from_listing",
  "idp_walk_position", "dist_btn_sample_collected", "instance_name"
)

run_sanity_checks <- function(out, main, roster, prev_meta, known_org_ids, household_frame) {
  issues <- character(0)
  add <- function(...) issues <<- c(issues, paste0(...))

  # ---- 1. schema: did the raw export lose/rename a column we depend on? ----
  missing_cols <- setdiff(REQUIRED_MAIN_COLUMNS, names(main))
  if (length(missing_cols) > 0) {
    add(
      "SCHEMA: ", length(missing_cols), " expected column(s) missing from the raw export's 'main' sheet: ",
      paste(missing_cols, collapse = ", "),
      " — the anonymised export's column names may have changed."
    )
  }
  if (length(grep("^sample_point_NG\\d+_non_idp$", names(main))) == 0) {
    add("SCHEMA: no 'sample_point_NG###_non_idp' repair columns found at all — the NG037 tool-bug repair (see this script's header) may silently do nothing.")
  }
  if (!"parent_instance_name" %in% names(roster)) {
    add("SCHEMA: roster sheet has no 'parent_instance_name' column — the household-roster join (hh_size vs roster_count check) will produce all-NA and silently stop firing.")
  }

  # ---- 2. row count: cumulative data should only grow ------------------------
  if (!is.null(prev_meta) && !is.null(prev_meta$n_rows)) {
    if (nrow(out) < prev_meta$n_rows) {
      add(
        "ROW COUNT DECREASED: ", nrow(out), " rows today vs ", prev_meta$n_rows, " previously — ",
        "submissions are cumulative and should only grow. Check today's export is complete, not a partial/truncated pull."
      )
    } else if (prev_meta$n_rows > 0 && nrow(out) > prev_meta$n_rows * 2) {
      add(
        "ROW COUNT JUMPED: ", nrow(out), " rows today vs ", prev_meta$n_rows, " previously (more than doubled) — ",
        "worth a quick look in case the export was duplicated."
      )
    }
  }

  # ---- 3. dates: a broken date field breaks FIELDING_START downstream --------
  na_dates <- sum(is.na(out$submission_date))
  if (nrow(out) > 0 && na_dates == nrow(out)) {
    add("DATES: submission_date is NA for EVERY row — FIELDING_START and every days-elapsed/ETA figure on the dashboard will be garbage.")
  } else if (nrow(out) > 0 && na_dates / nrow(out) > 0.1) {
    add("DATES: submission_date is NA for ", na_dates, " of ", nrow(out), " rows (>10%) — higher than expected.")
  }

  # ---- 4. numeric parse failures (was silent via suppressWarnings()) ---------
  parse_failures <- function(raw, label) {
    raw_chr <- as.character(raw)
    had_value <- !is.na(raw_chr) & str_squish(raw_chr) != ""
    failed <- had_value & is.na(suppressWarnings(as.numeric(raw_chr)))
    if (sum(failed) > 0) {
      add(
        "PARSE: ", sum(failed), " '", label, "' value(s) present in the raw export but not numeric-parseable ",
        "(e.g. text where a number was expected) — now silently NA in the dashboard data."
      )
    }
  }
  parse_failures(main$resp_age, "resp_age")
  parse_failures(main$hoh_age, "hoh_age")
  parse_failures(main$enum_age, "enum_age")
  parse_failures(main$hh_size, "hh_size")

  # ---- 5. duplicate raw uuids (export glitch, distinct from the
  # methodology-aware is_duplicate flag which is about repeat HOUSEHOLD
  # visits, not repeat EXPORT rows) --------------------------------------------
  raw_uuids <- main$uuid[!is.na(main$uuid)]
  n_dup_uuid <- sum(duplicated(raw_uuids))
  if (n_dup_uuid > 0) {
    add(
      "DUPLICATE UUID: ", n_dup_uuid, " raw submission uuid(s) appear more than once in the export ",
      "(distinct from the normal duplicate-household flag) — likely an export glitch that would double-count in every total."
    )
  }

  # ---- 6. unknown org_id ------------------------------------------------------
  unknown_orgs <- setdiff(unique(out$org_id[!is.na(out$org_id)]), known_org_ids)
  if (length(unknown_orgs) > 0) {
    add(
      "UNKNOWN ORG_ID: ", length(unknown_orgs), " org_id value(s) not found in partner_lga_assignment.csv: ",
      paste(unknown_orgs, collapse = ", "),
      " — check for a typo, or a new partner not yet added to Partnerscoverage.xlsx."
    )
  }

  # ---- 7. roster join health: did it silently go dark? -----------------------
  if (nrow(out) > 0) {
    roster_na_rate <- mean(is.na(out$roster_count))
    if (roster_na_rate > 0.95) {
      add(
        "ROSTER JOIN: roster_count is NA for ", fmt_pct_local(roster_na_rate), " of rows — ",
        "the household-roster join may have broken (join-key rename?), silently disabling the hh_size-vs-roster check."
      )
    }
  }

  # ---- 8. implausible values (conservative bounds - data-entry errors,
  # not eligibility rules) ------------------------------------------------------
  bound_check <- function(x, lo, hi, label) {
    bad <- !is.na(x) & (x < lo | x > hi)
    if (sum(bad) > 0) {
      add("RANGE: ", sum(bad), " '", label, "' value(s) outside [", lo, ", ", hi, "] — check for data-entry errors.")
    }
  }
  bound_check(out$resp_age, 5, 100, "resp_age")
  bound_check(out$hoh_age, 5, 100, "hoh_age")
  bound_check(out$enum_age, 15, 90, "enum_age")
  bound_check(out$hh_size, 1, 30, "hh_size")
  if (sum(!is.na(out$duration_min) & out$duration_min < 0) > 0) {
    add("RANGE: ", sum(!is.na(out$duration_min) & out$duration_min < 0), " row(s) have a NEGATIVE duration_min — end time before start time.")
  }

  # ---- 9. matched IDs must exist in the CURRENT sampling frame, not just
  # be non-missing (added 2026-08-21, ahead of an expected resampling
  # event). matched_survey_id/matched_cluster_id/matched_strata_id are
  # built by string manipulation on the raw KoBo ID (see prep_real_
  # submissions.R step 3) with no existence check against the frame at
  # build time — harmless while the frame is stable, but the moment it
  # changes (new cluster_ids, a resampled strata layout), a well-formed,
  # non-NA ID could easily point at nothing real. Every downstream join
  # (compute_progress_by_stratum, the Coverage Map's cluster view, the
  # partner digest's oversampled-clusters sheet) would then silently read
  # 0/empty for that row rather than error — this check is what makes that
  # loud instead. ------------------------------------------------------------
  id_exists_check <- function(matched_ids, frame_ids, label) {
    present <- !is.na(matched_ids)
    unknown <- sum(present & !(matched_ids %in% frame_ids))
    if (unknown > 0) {
      add(
        "FRAME DRIFT: ", unknown, " row(s) have a non-missing ", label, " that doesn't exist in the ",
        "current sampling frame (input_data/sampling_frame/..._WORKING.csv) — either a broken match, ",
        "or the frame has changed since these were matched. Achieved/oversampled figures built from ",
        label, " will silently undercount these rows."
      )
    }
  }
  # matched_survey_id is only checkable against the frame for non-IDP,
  # which gets a real, pre-assigned per-household point ID (checkable
  # against household_frame$survey_id). IDP is checked here for non_idp
  # rows ONLY — since 2026-08-22, IDP's matched_survey_id is cluster_id +
  # the on-site listing/walk position (see prep_real_submissions.R step 3),
  # a real per-household identity but not one the sampling frame has any
  # record of: the frame's own idp survey_id rows are just numbered
  # placeholder slots ("..._HH01".."..._R06") generated for bookkeeping,
  # never tied to a real listing number, so there's nothing meaningful to
  # check IDP's matched_survey_id against here. (An EARLIER version of this
  # check compared both pop_types against $survey_id uniformly — before
  # IDP's matched_survey_id held the cluster id alone — and flagged every
  # single IDP row as "unknown", a false positive caught before it shipped.
  # IDP's frame membership is still covered: matched_cluster_id below
  # checks the cluster part for both pop_types.)
  n_survey_unknown <- sum(out$pop_type == "non_idp" & !is.na(out$matched_survey_id) & !(out$matched_survey_id %in% household_frame$survey_id))
  if (n_survey_unknown > 0) {
    add(
      "FRAME DRIFT: ", n_survey_unknown, " row(s) have a non-missing matched_survey_id that doesn't exist in the ",
      "current sampling frame — either a broken match, or the frame has changed since these were matched. ",
      "Achieved/oversampled figures built from matched_survey_id will silently undercount these rows."
    )
  }
  id_exists_check(out$matched_cluster_id, household_frame$cluster_id, "matched_cluster_id")
  id_exists_check(out$matched_strata_id, household_frame$strata_id, "matched_strata_id")

  issues
}

fmt_pct_local <- function(x) paste0(round(x * 100), "%")

# ---- frame freshness: is our local copy of the sampling frame still
# current? (added 2026-08-22, after finding 2_monitoring's copy of the
# WORKING frame was 13 days stale — missing a whole column — with no
# mechanism that would ever have surfaced it, alongside a design-frame
# archive path in prep_psu_geometries.R that was two real revisions
# behind). Compares the local copied _frame_version.txt (written by
# 1_sampling/scripts/stamp_frame_version.R, copied in alongside the frame
# files themselves — see that script for the marker format) against
# 1_sampling's LIVE marker, read directly. This is a read-only metadata
# comparison, not a computational dependency — the same spirit as
# prep_psu_geometries.R already reading the design-frame archive directly;
# the actual frame DATA used for every computation still only ever comes
# from the local static copy, per the "copy in, don't read live" rule in
# 1_sampling/CLAUDE.md. Silently skips (not even a warning) if the sibling
# project isn't reachable from this machine — this check is a nice-to-have
# where both projects are checked out side by side, not a hard requirement.
LIVE_FRAME_VERSION_FILE <- "../1_sampling/output/data/data_collection/_frame_version.txt"
LOCAL_FRAME_VERSION_FILE <- "input_data/sampling_frame/_frame_version.txt"

read_frame_version <- function(path) {
  if (!file.exists(path)) return(NULL)
  lines <- readLines(path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  keys <- sub("^([^:]+): .*$", "\\1", lines)
  vals <- sub("^[^:]+: (.*)$", "\\1", lines)
  setNames(vals, keys)
}

check_frame_freshness <- function() {
  live <- read_frame_version(LIVE_FRAME_VERSION_FILE)
  if (is.null(live)) return(character(0)) # sibling project not reachable from this machine - skip
  local <- read_frame_version(LOCAL_FRAME_VERSION_FILE)
  if (is.null(local)) {
    return(paste0(
      "FRAME STALE: no local input_data/sampling_frame/_frame_version.txt found, but 1_sampling has one ",
      "(stamped ", live[["stamped_at"]], ") — copy input_data/sampling_frame/ files fresh from ",
      "1_sampling/output/data/data_collection/, including _frame_version.txt."
    ))
  }
  if (!identical(local[["working_csv_md5"]], live[["working_csv_md5"]]) ||
      !identical(local[["strata_working_csv_md5"]], live[["strata_working_csv_md5"]])) {
    return(paste0(
      "FRAME STALE: local sampling-frame copy (stamped ", local[["stamped_at"]], ") doesn't match 1_sampling's ",
      "current output (stamped ", live[["stamped_at"]], ") — re-copy input_data/sampling_frame/*_WORKING.csv ",
      "and _frame_version.txt from 1_sampling/output/data/data_collection/."
    ))
  }
  character(0)
}

# ---- accessibility layer freshness: is our local copy of the resampling
# team's ward-level accessibility status still current? (added 2026-08-25,
# alongside first integrating the layer). Unlike check_frame_freshness()
# above, 1_sampling/resampling/ doesn't (yet) stamp its own live version
# marker for this output, so there's no pre-computed "live" side to compare
# against — instead this reads the md5 recorded at copy time (written by
# cleaning/prep/prep_accessibility_layer.R into
# input_data/accessibility/_accessibility_version.txt) and recomputes the
# CURRENT live file's md5 directly. Same "silently skip if the sibling
# project isn't reachable" spirit as check_frame_freshness() — this data is
# expected to be refreshed repeatedly as more partner reports land over the
# course of the assessment (see prep_accessibility_layer.R header), so a
# stale copy here would silently understate the current inaccessible extent
# rather than just being mildly out of date.
LIVE_ACCESSIBILITY_WARD_CSV <- "../1_sampling/resampling/output/master_accessibility_status_ward_level.csv"
LIVE_ACCESSIBILITY_LGA_CSV <- "../1_sampling/resampling/output/master_accessibility_status_lga_level.csv"
LIVE_ACCESSIBILITY_WORKBOOK <- "../1_sampling/resampling/output/NGA_MSNA_2026_accessibility_impact_workbook.xlsx"
LIVE_ACCESSIBILITY_SHP <- "../1_sampling/resampling/output/gis/accessible_area_lga_ward_portions.shp"
LOCAL_ACCESSIBILITY_VERSION_FILE <- "input_data/accessibility/_accessibility_version.txt"

check_accessibility_freshness <- function() {
  if (!file.exists(LIVE_ACCESSIBILITY_WARD_CSV)) return(character(0)) # sibling project not reachable - skip
  local <- read_frame_version(LOCAL_ACCESSIBILITY_VERSION_FILE)
  if (is.null(local)) {
    return(paste0(
      "ACCESSIBILITY LAYER STALE: no local input_data/accessibility/_accessibility_version.txt found, but ",
      "1_sampling/resampling/output/ has accessibility data — run cleaning/prep/prep_accessibility_layer.R."
    ))
  }
  live_md5 <- function(path) if (file.exists(path)) unname(tools::md5sum(path)) else NA_character_
  live_mtime <- function(path) if (file.exists(path)) format(file.info(path)$mtime, "%Y-%m-%d %H:%M:%S") else NA_character_
  # 2026-09-09: local is a plain named character vector from read_frame_
  # version() - `[[` on that throws "subscript out of bounds" for a name
  # that isn't present, rather than returning NA like a list would. Started
  # happening once sync_accessibility_mirrors.R (1_sampling, wired into
  # deploy_dashboard.R the same night) began writing this same stamp file
  # too, with only ward_csv_*/lga_csv_* fields - no workbook_mtime/shp_md5,
  # which only prep_accessibility_layer.R's fuller stamp includes. Safe
  # lookup so a missing field reads as NA (→ correctly flags STALE below)
  # instead of crashing every unattended run of this script, deploy_
  # dashboard.R included. Which script should own this stamp is a separate,
  # not-mechanical question - flagged to 2-monitoring-2d, not decided here.
  vget <- function(v, k) if (k %in% names(v)) v[[k]] else NA_character_
  mismatched <- !identical(vget(local, "ward_csv_md5"), live_md5(LIVE_ACCESSIBILITY_WARD_CSV)) ||
    !identical(vget(local, "lga_csv_md5"), live_md5(LIVE_ACCESSIBILITY_LGA_CSV)) ||
    !identical(vget(local, "workbook_mtime"), live_mtime(LIVE_ACCESSIBILITY_WORKBOOK)) ||
    !identical(vget(local, "shp_md5"), live_md5(LIVE_ACCESSIBILITY_SHP))
  if (mismatched) {
    return(paste0(
      "ACCESSIBILITY LAYER STALE: local copy (stamped ", local[["stamped_at"]], ") doesn't match 1_sampling/",
      "resampling/output/'s current files — likely new partner reports have landed since this copy was made. ",
      "Re-run cleaning/prep/prep_accessibility_layer.R to refresh input_data/accessibility/."
    ))
  }
  character(0)
}

# ---- target revision log: has the sampling frame's TOTAL target_sample
# changed since the last thing we logged? (added 2026-08-30, ahead of the
# resampling/exclusion-area changes Jack expects to start within a day or
# two). The dashboard needs to show partners a stable "31,506 at fielding
# start" baseline even as the live total moves, plus a dated note on what
# changed and why — this is the write side of that: append-only log at
# data/TARGET_REVISION_LOG.csv (date, total_target, reason), read by
# dashboard_app/global.R. Deliberately only fires on a change to the TOTAL
# — routine point-level reshuffling that leaves the sum untouched (the
# everyday kind of frame refresh) must NOT create a log entry, or the log
# stops meaning anything.
#
# Reason-sourcing is explicitly not automatic: "why did the target change"
# is a judgement call, not something inferable from the frame data alone
# (confirmed with Jack). Two channels feed it, in priority order:
#   1. data/PENDING_TARGET_REVISION_REASON.txt — a one-line reason, meant
#      to eventually be written directly by the resampling workflow itself
#      (or manually by Jack) BEFORE/alongside the frame change landing.
#      If present and non-empty when a shift is detected, it's consumed
#      (logged, then the file is cleared back to empty) — never left
#      sitting there to accidentally get reused for a later, different
#      change.
#   2. Nothing: the shift is real but unexplained. Per Jack: "if no reason
#      is provided then prompt/question for one" — an actual interactive
#      terminal prompt would break every unattended run of this script
#      (deploy_dashboard.R included), so this is implemented as a loud,
#      repeating sanity warning instead — the same "keeps re-announcing
#      until acknowledged" mechanism as every other check here. No log
#      row is written yet in this case, deliberately: better an obviously
#      incomplete dashboard baseline (still showing the last-known total)
#      than a permanent log entry with a placeholder reason nobody goes
#      back to fix.
TARGET_REVISION_LOG_FILE <- "data/TARGET_REVISION_LOG.csv"
PENDING_TARGET_REVISION_REASON_FILE <- "data/PENDING_TARGET_REVISION_REASON.txt"
# 2026-09-09: was hardcoded to "_v5_" - same class of bug fixed elsewhere in
# the 2026-09-08 rebuild (global.R's latest_frame_file()), just missed here.
# This one didn't crash outright (file.exists() guard below silently
# skipped the check instead once v5 was archived away) but that's a check
# quietly going dark, not really a save - fixed the same way as
# prep_real_submissions.R's identical issue.
STRATA_FRAME_FOR_TARGET_CHECK <- local({
  dir <- "input_data/sampling_frame"
  pat <- "^NGA_MSNA_2026_strata_level_sampling_frame_v([0-9]+)_WORKING\\.csv$"
  candidates <- list.files(dir, pattern = pat)
  if (length(candidates) == 0) return(file.path(dir, "NGA_MSNA_2026_strata_level_sampling_frame_v5_WORKING.csv")) # preserves prior not-found behavior
  versions <- as.integer(sub(pat, "\\1", candidates))
  file.path(dir, candidates[which.max(versions)])
})

check_target_revision <- function() {
  if (!file.exists(STRATA_FRAME_FOR_TARGET_CHECK) || !file.exists(TARGET_REVISION_LOG_FILE)) return(character(0))

  current_total <- suppressMessages(sum(readr::read_csv(STRATA_FRAME_FOR_TARGET_CHECK, show_col_types = FALSE)$target_sample, na.rm = TRUE))
  log <- suppressMessages(readr::read_csv(TARGET_REVISION_LOG_FILE, show_col_types = FALSE))
  last_logged_total <- tail(log$total_target, 1)

  if (identical(current_total, last_logged_total) || (is.numeric(current_total) && is.numeric(last_logged_total) && current_total == last_logged_total)) {
    return(character(0))
  }

  pending_reason <- if (file.exists(PENDING_TARGET_REVISION_REASON_FILE)) trimws(paste(readLines(PENDING_TARGET_REVISION_REASON_FILE, warn = FALSE), collapse = " ")) else ""

  if (nzchar(pending_reason)) {
    new_row <- data.frame(date = as.character(Sys.Date()), total_target = current_total, reason = pending_reason)
    readr::write_csv(new_row, TARGET_REVISION_LOG_FILE, append = TRUE)
    writeLines("", PENDING_TARGET_REVISION_REASON_FILE) # consumed -- clear so it can't be reused for a later change
    return(character(0))
  }

  paste0(
    "TARGET REVISION UNEXPLAINED: sampling frame's total target_sample changed from ", last_logged_total,
    " to ", current_total, " but no reason has been recorded. Add a one-line reason to ",
    PENDING_TARGET_REVISION_REASON_FILE, " (or a row directly to ", TARGET_REVISION_LOG_FILE,
    ") and re-run this refresh to log it — the dashboard's baseline/revision note won't update until it is."
  )
}

# ---- persistence + the loud, repeated re-announcement -----------------------

write_sanity_warnings <- function(issues, source_label = "prep_real_submissions.R") {
  if (length(issues) == 0) return(invisible())
  entry <- paste0(
    "==== ", format(Sys.time(), "%Y-%m-%d %H:%M"), " (", source_label, ") ====\n",
    paste0("  - ", issues, collapse = "\n"), "\n\n"
  )
  dir.create(dirname(SANITY_WARNINGS_FILE), showWarnings = FALSE)
  cat(entry, file = SANITY_WARNINGS_FILE, append = TRUE)
}

# Called at the START of every entry point in the daily workflow (this
# script, generate_partner_digest.R, deploy_dashboard.R) so an unacknowledged
# warning resurfaces every single time, not just once when first found.
print_sanity_banner_if_present <- function() {
  if (!file.exists(SANITY_WARNINGS_FILE)) return(invisible())
  bar <- strrep("!", 78)
  cat("\n", bar, "\n", sep = "")
  cat("!! UNACKNOWLEDGED DATA SANITY WARNINGS EXIST — see ", SANITY_WARNINGS_FILE, "\n", sep = "")
  cat("!! Review, then run clear_sanity_warnings.R (project root) once actioned.\n")
  cat(bar, "\n\n", sep = "")
  cat(readLines(SANITY_WARNINGS_FILE), sep = "\n")
  cat("\n", bar, "\n\n", sep = "")
}
