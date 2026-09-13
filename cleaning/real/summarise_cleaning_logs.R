# Reads the cleaning team's check-flag logs and turns them into the
# enumerator/partner-level rollups the FACT digest needs (see
# dashboard_app/R/reports_fact_digest.R for how these feed the workbook, and
# generate_fact_digest.R at the project root for the actual "run this daily"
# entry point). Read-only against cleaning/ — never writes or modifies
# anything there.
#
# ---- FORMAT CHANGE 2026-09-13: the DO now publishes ONE cumulative master
# log instead of a dated per-day file ---------------------------------------
# cleaning/MSNA_Data_Cleaning/output/checking/master_log/all_orgs/
# master_log_main.xlsx replaces the old daily
# checking/<date>/all_orgs/*_cleaning_log_main.xlsx files entirely -
# checking/db/ (the pre-2026-09-13 dated-folder location) stopped receiving
# new dates after 2026-09-09, confirmed directly (no 09-10 through 09-13
# folders exist there). The new file carries its own per-row check_date
# column (confirmed clean: character "YYYY-MM-DD", 0 NAs across 11,198 rows)
# instead of one date per file, and IS the cumulative reissue the old format
# explicitly wasn't - no combining across files needed any more. Old
# per-date files, when they existed, each covered only that day's
# newly-checked batch (confirmed empirically then: zero uuid+check_id
# overlap between e.g. the 08-16 and 08-17 logs) - the discover-and-combine-
# every-dated-folder logic below is kept ONLY as a fallback for reading that
# historical layout if it's ever needed again, not for normal operation.
#
# ---- The "main" log is the only one with real content ----------------------
# Each date also has roster/edu_ind/health_ind/nut_ind/prot_ind cleaning
# logs alongside main, but as of 2026-08-18 those are 4 boilerplate
# "value_placeholder" rows each, nothing analysable — only main is read
# here. Worth re-checking if that ever changes.
#
# ---- Severity tiers (the judgement call at the centre of this file) --------
# change_type (no_action / change_response / remove_survey) looks like it
# should be the severity signal the cleaning script already computes, but
# it's populated for the most recent log date only (and even there,
# incompletely — e.g. flag_zero_fcs, arguably the single worst check_id,
# is left unclassified rather than auto-marked remove_survey). It can't be
# used as the sole basis for severity across the full history, so
# CHECK_TIER below is our own consistent classification applied uniformly
# to every date, informed by (a) change_type where it exists, (b) the
# MSNA_data_quality_evidence.xlsx duration/FSL-all-zero analysis, and (c)
# which checks are structurally unrecoverable vs a judgement call vs only
# meaningful as an enumerator-level rate. Confirmed with Jack 2026-08-18 —
# revisit this table first if the tiering ever looks wrong in the digest.
#
#   A - recommend deletion: structurally invalid / unrecoverable response
#   B - needs a human review before deciding (plausible but ambiguous)
#   C - fine as a one-off; only a concern as an enumerator-level RATE
#   D - not a partner data-quality issue (self-resolving or statistical)
#
# Any check_id not in this table defaults to tier B (needs review) with a
# message — safer than silently dropping a check type the cleaning script
# adds in future, or silently recommending deletion for something we've
# never actually assessed.

CHECK_TIER <- c(
  # A - recommend deletion
  flag_zero_fcs = "A", flag_lcsi_all_na = "A", duration_rushed = "A", check_1 = "A",
  # A - no_consent (added 2026-09-04, confirmed with Jack): the cleaning
  # team's own change_type for this check_id is "remove_survey" - their
  # clearest, most decisive signal ("...this record cannot be used"), same
  # standing as duration_rushed/flag_zero_fcs above. Checked against
  # real_submissions.csv: every no_consent/flag_no_consent row already has
  # interview_outcome=="consent_refused", so both are already fully
  # excluded from Collected AND Achieved regardless of tier - this only
  # affects how they're labelled in the digest's Common Errors/tier
  # breakdown, not any counted total.
  no_consent = "A",
  # A - aliases/near-duplicates found once every dated log got read (2026-08-18):
  # earlier logs (08-12/08-16) spell the all-zero FSL check "flag_fcs_zero", not
  # "flag_zero_fcs" - same underlying issue text, treated as the same check.
  # flag_full_fcs is new: household reports the MAXIMUM possible FCS (112) every
  # day for 7 days - as structurally implausible as the all-zero case, just the
  # mirror image, so tiered the same. Both confirmed via each check's own
  # "issue" text before adding here, not guessed from the name alone.
  flag_fcs_zero = "A", flag_full_fcs = "A",
  # B - needs review
  duration_low = "B", duration_high = "B", gps_possible_duplicate = "B",
  duplicate_sample_point = "B", listing_missing = "B", listing_hh_not_drawn = "B",
  listing_duplicate_draw = "B", listing_method_mismatch = "B", outlier = "B", value_placeholder = "B",
  # B - flag_gps_distance (>500m from assigned point / location unconfirmed):
  # same family as gps_possible_duplicate - could be a genuine device/drift
  # issue, not automatically fabrication, so B not A.
  flag_gps_distance = "B",
  # B - flag_no_consent (added 2026-09-04): the preliminary/softer flag
  # version of no_consent above - mostly blank or "no_action" change_type
  # (the cleaning team hasn't itself treated these as decided), unlike
  # no_consent's own "remove_survey". Same duration_low/duration_high vs.
  # duration_rushed pattern already established in this table.
  flag_no_consent = "B",
  # B - synthetic check_ids from recover_check_id_from_issue() below, for
  # rows where check_id itself is blank (see that function's header).
  # missing_cluster_id is a real, recurring, nameable pattern (not a true
  # catch-all) - a submission with no cluster_id can't be traced back to
  # any sampling draw at all, same family as listing_missing.
  duration_unspecified = "B", missing_cluster_id = "B", unspecified_issue = "B",
  # C - pattern-only (individually plausible)
  flag_low_oil = "C", flag_low_cereal = "C", flag_high_protein = "C", flag_low_fcs = "C",
  flag_high_fcs = "C", flag_high_rcsi = "C", flag_fcsrcsi_box = "C", flag_protein_rcsi = "C",
  flag_fcs_rcsi = "C", flag_meat_cereal_ratio = "C", flag_severe_hhs = "C",
  # D - not a partner issue
  flag_no_child_rcsi = "D", percentage_missing = "D"
)

# Roughly a quarter to nearly half of rows in the four earliest logs
# (2026-08-12/14/15/16) have a completely blank check_id - confirmed this
# isn't junk: the issue/question/check_binding columns are still populated
# and match recognisable patterns, check_id just wasn't consistently
# written by the cleaning script yet at that point. Dropping these would
# silently discard a large share of the early history, so they're
# recovered by matching the issue TEXT instead. Deliberately conservative:
# everything recovered this way lands at tier B, never A - e.g. the
# recovered "duration is lower or higher than thresholds" text alone can't
# say which side of the threshold (or how extreme), unlike the properly
# check_id-labelled duration_rushed/duration_low/duration_high rows can.
recover_check_id_from_issue <- function(check_id, issue) {
  dplyr::case_when(
    # "unclassified" (seen 2026-09-04, CRS only) treated the same as blank -
    # the cleaning script started explicitly writing this literal value for
    # rows that used to just have a blank check_id, which meant this
    # function's own !is.na() branch returned "unclassified" verbatim
    # instead of ever reaching the issue-text rules below. Confirmed via the
    # actual issue text (identical to the missing_cluster_id pattern) that
    # these are genuinely the same case, not a new distinct check type - so
    # they land on the SAME tier (B) either way, this only fixes the label.
    !is.na(check_id) & check_id != "unclassified" ~ check_id,
    grepl("^Duration is lower or higher", issue) ~ "duration_unspecified",
    grepl("within 50m of another submission assigned to a different point", issue) ~ "duplicate_sample_point",
    grepl("within 20m of another submission", issue) ~ "gps_possible_duplicate",
    grepl("has more than one completed submission", issue) ~ "duplicate_sample_point",
    grepl("^outlier \\(", issue) ~ "outlier",
    grepl("^Possible value to be changed to NA", issue) ~ "value_placeholder",
    grepl("^No cluster_id recorded", issue) ~ "missing_cluster_id",
    grepl("^Percentages of missing values", issue) ~ "percentage_missing",
    TRUE ~ "unspecified_issue"
  )
}

TIER_LABEL <- c(
  A = "A - recommend deletion", B = "B - needs review",
  C = "C - pattern only", D = "D - not an issue"
)

# The data officer's output layout has moved twice now (2026-08-30: per-date
# folders to output/checking/db/; 2026-09-13: db/'s dated folders to one
# cumulative output/checking/master_log/) with no advance notice either
# time — see feedback_dont_touch_data_officer_pipeline: their layout can
# change without warning, so this resolution has to be tolerant of all
# three generations, not just corrected once again. CLEANING_LOG_LAYOUT
# records which generation was actually found, since master_log's own
# internal shape (one file, not a dated-folder glob) is genuinely different,
# not just a different path to the same shape - summarise_cleaning_logs()
# below branches on it.
CLEANING_LOG_LAYOUT <- "master_log"
CLEANING_LOG_ROOT <- if (dir.exists("cleaning/MSNA_Data_Cleaning/output/checking/master_log")) {
  "cleaning/MSNA_Data_Cleaning/output/checking/master_log" # called from the project root (generate_fact_digest.R)
} else if (dir.exists("../cleaning/MSNA_Data_Cleaning/output/checking/master_log")) {
  "../cleaning/MSNA_Data_Cleaning/output/checking/master_log" # called from dashboard_app/ (tests/smoke_test.R)
} else if (dir.exists("cleaning/MSNA_Data_Cleaning/output/checking/db")) {
  CLEANING_LOG_LAYOUT <- "dated_db"
  "cleaning/MSNA_Data_Cleaning/output/checking/db" # pre-2026-09-13 layout, in case master_log/ is ever renamed/removed
} else if (dir.exists("../cleaning/MSNA_Data_Cleaning/output/checking/db")) {
  CLEANING_LOG_LAYOUT <- "dated_db"
  "../cleaning/MSNA_Data_Cleaning/output/checking/db"
} else if (dir.exists("cleaning/MSNA_Data_Cleaning/output/checking")) {
  CLEANING_LOG_LAYOUT <- "dated_flat"
  "cleaning/MSNA_Data_Cleaning/output/checking" # pre-2026-08-30 layout, in case a future restructure reverts it
} else {
  CLEANING_LOG_LAYOUT <- "dated_flat"
  "../cleaning/MSNA_Data_Cleaning/output/checking"
}

assign_tier <- function(check_id) {
  tier <- unname(CHECK_TIER[check_id])
  unmapped <- is.na(tier)
  if (any(unmapped)) {
    message(
      "summarise_cleaning_logs(): unrecognised check_id(s) defaulted to tier B (needs review): ",
      paste(unique(check_id[unmapped]), collapse = ", ")
    )
    tier[unmapped] <- "B"
  }
  tier
}

read_one_cleaning_log <- function(f) {
  raw <- readxl::read_excel(f, sheet = "cleaning_log", guess_max = 3000)
  raw %>%
    transmute(
      # check_date (added to the sheet itself in the 2026-09-13 master_log
      # format) is a real per-ROW date, more accurate than the old
      # per-FILE filename date it replaces - use it when present. Falls
      # back to the filename date for the legacy dated-folder layout,
      # which never had a check_date column at all.
      log_date = if ("check_date" %in% names(raw)) as.Date(check_date) else as.Date(stringr::str_extract(basename(f), "\\d{4}-\\d{2}-\\d{2}")),
      uuid, enum_id, org_id, admin1 = as.character(admin1), admin2 = as.character(admin2),
      # cluster_id only exists in the schema from 2026-08-17 onward (25 cols
      # vs 16 before, confirmed 2026-08-24) — NA for earlier dates rather
      # than erroring; the Ward lookup below just comes back blank for
      # those older rows instead of failing the whole digest.
      cluster_id = if ("cluster_id" %in% names(raw)) as.character(cluster_id) else NA_character_,
      check_id, issue, question,
      old_value = as.character(old_value), new_value = as.character(new_value),
      change_type
    )
}

# Requires global.R to already be sourced (needs ORG_LABELS, adm2_name_lookup,
# submissions_raw, is_achieved()) — called from generate_fact_digest.R after
# that source() step, same convention as build_fact_quality_digest_excel().
summarise_cleaning_logs <- function() {
  # master_log/ is one cumulative file, not a dated-folder glob - see
  # CLEANING_LOG_LAYOUT above. Only fall back to the dated-folder glob (and
  # its "combine every date" reasoning) for the legacy layout.
  files <- if (CLEANING_LOG_LAYOUT == "master_log") {
    file.path(CLEANING_LOG_ROOT, "all_orgs", "master_log_main.xlsx")
  } else {
    Sys.glob(file.path(CLEANING_LOG_ROOT, "*", "all_orgs", "*_cleaning_log_main.xlsx"))
  }
  stopifnot(all(file.exists(files)), length(files) > 0)

  # admin1/admin2 in the cleaning log are already STATE/LGA NAMES (e.g.
  # "Benue", "Agatu"), not pcodes — confirmed 2026-08-24 after Jack
  # reported State/LGA showing blank on the Priority follow-up / Cleaning
  # log detail sheets. The previous version of this lookup matched them
  # against adm2_name_lookup's *pcode* columns (adm1_pcode/adm2_pcode),
  # which never matches a name string against a pcode string — admin1_name/
  # admin2_name came back NA on every single row, on every digest, since
  # this sheet existed. Matched on the combined (state, LGA) pair, not LGA
  # name alone, since LGA names aren't guaranteed unique nationally.
  admin_lookup <- adm2_name_lookup %>%
    distinct(adm1_name, adm2_name) %>%
    mutate(admin_key = paste0(stringr::str_to_lower(adm1_name), "|", stringr::str_to_lower(adm2_name)))

  # Ward isn't a raw column in the cleaning log, but cluster_id is — and
  # household_frame (global.R) already carries adm3_name per row, so the
  # modal (most common) ward per cluster_id gives a real ward without
  # needing anything new from the cleaning team. Same pattern
  # cleaning/prep/prep_psu_geometries.R already uses for the same purpose.
  cluster_ward_lookup <- household_frame %>%
    filter(!is.na(adm3_name), adm3_name != "NA") %>%
    count(cluster_id, adm3_name, sort = TRUE) %>%
    distinct(cluster_id, .keep_all = TRUE) %>%
    select(cluster_id, adm3_name)

  combined <- bind_rows(lapply(files, read_one_cleaning_log)) %>%
    mutate(
      check_id = recover_check_id_from_issue(check_id, issue),
      tier = assign_tier(check_id),
      Partner = unname(ORG_LABELS[org_id]),
      admin_key = paste0(stringr::str_to_lower(admin1), "|", stringr::str_to_lower(admin2)),
      admin1_name = admin_lookup$adm1_name[match(admin_key, admin_lookup$admin_key)],
      admin2_name = admin_lookup$adm2_name[match(admin_key, admin_lookup$admin_key)],
      admin3_name = cluster_ward_lookup$adm3_name[match(cluster_id, cluster_ward_lookup$cluster_id)]
    )

  unmatched_admin <- combined %>% filter(is.na(admin1_name)) %>% distinct(admin1, admin2)
  if (nrow(unmatched_admin) > 0) {
    message(
      "summarise_cleaning_logs(): ", nrow(unmatched_admin), " (state, LGA) pair(s) in the cleaning log didn't ",
      "match the sampling frame, State/LGA will show blank for these rows: ",
      paste(paste0(unmatched_admin$admin1, "/", unmatched_admin$admin2), collapse = ", ")
    )
  }

  dates_covered <- sort(unique(combined$log_date))
  expected_dates <- seq(min(dates_covered), max(dates_covered), by = "day")
  missing_dates <- as.Date(setdiff(as.character(expected_dates), as.character(dates_covered)))

  # one row per (submission, check_id) - collapses the module checks that
  # fire once per question (e.g. flag_lcsi_all_na fires once per LCSI
  # question, all on the same household) down to a single instance, so
  # submission-level counts below aren't inflated by question count.
  flags_by_submission_check <- combined %>%
    distinct(uuid, enum_id, org_id, Partner, admin1_name, admin2_name, check_id, tier)

  by_submission <- combined %>%
    group_by(uuid) %>%
    summarise(
      org_id = dplyr::first(org_id), Partner = dplyr::first(Partner), enum_id = dplyr::first(enum_id),
      admin1_name = dplyr::first(admin1_name), admin2_name = dplyr::first(admin2_name),
      admin3_name = dplyr::first(admin3_name),
      log_date = min(log_date),
      checks = paste(sort(unique(check_id)), collapse = "; "),
      issues = paste(unique(issue), collapse = " | "),
      worst_tier = min(tier), # "A" < "B" < "C" < "D" - alphabetical is worst-first here by design
      any_remove_survey = any(change_type == "remove_survey", na.rm = TRUE),
      .groups = "drop"
    )

  # ---- priority follow-up: tier A, or already auto-marked remove_survey,
  # cross-checked against the live dashboard data - this is the concrete
  # "still counting toward your achieved total" gap found 2026-08-18 -------
  priority <- by_submission %>%
    filter(worst_tier == "A" | any_remove_survey) %>%
    mutate(
      in_dataset = uuid %in% submissions_raw$submission_uuid,
      counts_as_achieved = uuid %in% submissions_raw$submission_uuid[is_achieved(submissions_raw)]
    ) %>%
    arrange(desc(counts_as_achieved), desc(in_dataset), Partner, enum_id)

  # ---- issue-list + instance-count helper --------------------------------------
  # "Flagged issues" / "Total flag instances" (2026-08-20, per Jack's review of
  # the first draft): flag_instances counts each (submission, check_type) pair
  # once - a submission that trips 3 different check types contributes 3
  # instances, but a check that fires multiple raw log rows per submission
  # (e.g. flag_zero_fcs, once per food-group question) still counts as one,
  # same de-duplication as flags_by_submission_check itself. Deliberately
  # DIFFERENT from tier_a+tier_b+tier_c (which double-counts any submission
  # with issues in more than one tier) - this is the flat, non-overlapping
  # total, i.e. the direct answer to "how many flags in total", spelled out
  # in the Read me sheet so the distinction from the tier columns is explicit
  # rather than left for the reader to guess at.
  format_issue_list <- function(check_ids) {
    tab <- sort(table(check_ids), decreasing = TRUE)
    paste0(names(tab), " (", as.integer(tab), ")", collapse = "; ")
  }
  issue_summary_by <- function(df, group_var) {
    df %>%
      group_by(.data[[group_var]]) %>%
      summarise(flag_instances = n(), flagged_issues = format_issue_list(check_id), .groups = "drop")
  }

  # ---- by enumerator - FULL ROSTER, UNION of submissions_raw AND the
  # cleaning logs (2026-08-20: every enumerator with >=1 submission OR >=1
  # cleaning-log flag, not just flagged ones and not just submissions_raw
  # alone, so a genuinely clean enumerator shows zeros rather than being
  # invisible, AND an enumerator whose submissions haven't been pulled into
  # submissions_raw yet still shows their cleaning-log flags rather than
  # being silently dropped).
  #
  # That second case is a real gap the smoke test caught: cleaning logs and
  # submissions_raw refresh on independent schedules, and it's not just
  # that a known enumerator's COUNT can be ahead (handled by pmax() below)
  # - a whole enumerator can appear in a cleaning log before their first
  # pulled submission exists in submissions_raw at all. A left_join
  # anchored on submissions_raw alone drops that enumerator's row (and
  # their tier-A/B/C flags with it) entirely, not just under-counts them -
  # confirmed 2026-08-20 via the enumerator-vs-partner tier_a
  # reconciliation test failing (61 vs 63: si_zam_msna_015 had 2 tier-A
  # flags and zero rows in submissions_raw yet). Building the roster as a
  # union of both sources' enum_ids, preferring submissions_raw's org_id
  # when both agree (the normal case), fixes this at the source rather
  # than patching around it downstream. -----------------------------------
  enum_roster <- bind_rows(
    submissions_raw %>% distinct(enum_id, org_id),
    flags_by_submission_check %>% distinct(enum_id, org_id)
  ) %>%
    distinct(enum_id, .keep_all = TRUE) %>%
    mutate(Partner = unname(ORG_LABELS[org_id]))

  total_by_enum <- submissions_raw %>% count(enum_id, name = "total_submissions")

  enum_tiers <- flags_by_submission_check %>%
    group_by(enum_id) %>%
    summarise(
      submissions_flagged = n_distinct(uuid),
      tier_a = n_distinct(uuid[tier == "A"]),
      tier_b = n_distinct(uuid[tier == "B"]),
      tier_c = n_distinct(uuid[tier == "C"]),
      .groups = "drop"
    )
  enum_issues <- issue_summary_by(flags_by_submission_check, "enum_id")

  by_enumerator <- enum_roster %>%
    left_join(total_by_enum, by = "enum_id") %>%
    left_join(enum_tiers, by = "enum_id") %>%
    left_join(enum_issues, by = "enum_id") %>%
    mutate(
      across(c(submissions_flagged, tier_a, tier_b, tier_c, flag_instances), ~coalesce(.x, 0L)),
      flagged_issues = coalesce(flagged_issues, "None"),
      # pmax(), not just coalesce(): cleaning logs and submissions_raw
      # refresh on independent schedules (cleaning logs are read live off
      # disk every run; submissions_raw is only as fresh as the last
      # prep_real_submissions.R pull) - caught 2026-08-19 when a new dated
      # cleaning log appeared referencing more of an enumerator's work than
      # that day's submissions_raw yet contained, so submissions_flagged
      # briefly exceeded total_submissions for a few enumerators. Flooring
      # the denominator at submissions_flagged keeps flag_rate <= 100% and
      # the invariant "flagged <= total" true regardless of which source is
      # momentarily ahead, rather than erroring or showing a >100% rate.
      # coalesce(total_submissions, 0L) first: an enumerator sourced only
      # from the cleaning logs (see above) has NO row in total_by_enum at
      # all, not just a low one.
      total_submissions = pmax(coalesce(total_submissions, 0L), submissions_flagged),
      flag_rate = ifelse(total_submissions > 0, submissions_flagged / total_submissions, NA_real_),
      priority = case_when(
        tier_a > 0 ~ "HIGH",
        tier_b >= 5 ~ "HIGH",
        tier_b >= 2 ~ "MEDIUM",
        !is.na(flag_rate) & flag_rate >= 0.5 ~ "MEDIUM",
        TRUE ~ "LOW"
      )
    ) %>%
    arrange(factor(priority, levels = c("HIGH", "MEDIUM", "LOW")), desc(tier_a), desc(tier_b))

  # ---- by partner - same full-roster (union) convention -------------------------
  high_by_partner <- by_enumerator %>% filter(priority == "HIGH") %>% count(org_id, name = "enumerators_high_priority")
  org_roster <- bind_rows(
    submissions_raw %>% distinct(org_id),
    flags_by_submission_check %>% distinct(org_id)
  ) %>%
    distinct(org_id) %>%
    mutate(Partner = unname(ORG_LABELS[org_id]))

  total_by_org <- submissions_raw %>%
    group_by(org_id) %>%
    summarise(total_submissions = n(), total_enumerators = n_distinct(enum_id), .groups = "drop")

  org_tiers <- flags_by_submission_check %>%
    group_by(org_id) %>%
    summarise(
      submissions_flagged = n_distinct(uuid),
      enumerators_flagged = n_distinct(enum_id),
      tier_a = n_distinct(uuid[tier == "A"]),
      tier_b = n_distinct(uuid[tier == "B"]),
      tier_c = n_distinct(uuid[tier == "C"]),
      .groups = "drop"
    )
  org_issues <- issue_summary_by(flags_by_submission_check, "org_id")

  by_partner <- org_roster %>%
    left_join(total_by_org, by = "org_id") %>%
    left_join(org_tiers, by = "org_id") %>%
    left_join(org_issues, by = "org_id") %>%
    left_join(high_by_partner, by = "org_id") %>%
    mutate(
      across(
        c(submissions_flagged, enumerators_flagged, tier_a, tier_b, tier_c, flag_instances, enumerators_high_priority),
        ~coalesce(.x, 0L)
      ),
      total_enumerators = coalesce(total_enumerators, 0L),
      flagged_issues = coalesce(flagged_issues, "None"),
      # see the matching pmax() note in by_enumerator above - same
      # refresh-timing skew (including a whole partner missing from
      # submissions_raw so far) can happen at the partner level too.
      total_submissions = pmax(coalesce(total_submissions, 0L), submissions_flagged),
      flag_rate = ifelse(total_submissions > 0, submissions_flagged / total_submissions, NA_real_)
    ) %>%
    arrange(desc(tier_a), desc(flag_rate))

  # ---- common errors (check-type rollup) ---------------------------------------
  by_check <- combined %>%
    group_by(check_id) %>%
    summarise(
      tier = dplyr::first(tier), issue = dplyr::first(issue),
      rows = n(), submissions = n_distinct(uuid),
      enumerators = n_distinct(enum_id), partners = n_distinct(org_id),
      .groups = "drop"
    ) %>%
    arrange(factor(tier, levels = c("A", "B", "C", "D")), desc(submissions))

  # ---- row-level detail ---------------------------------------------------------
  detail <- combined %>%
    transmute(
      Date = log_date, Partner, Enumerator = enum_id, State = admin1_name, LGA = admin2_name, Ward = admin3_name,
      `Check type` = check_id, Tier = unname(TIER_LABEL[tier]), Issue = issue, Question = question,
      `Old value` = old_value, `New value` = new_value,
      `Auto-classified action` = coalesce(change_type, "not yet classified")
    ) %>%
    arrange(match(substr(Tier, 1, 1), c("A", "B", "C", "D")), Partner, desc(Date))

  list(
    dates_covered = dates_covered,
    missing_dates = missing_dates,
    by_check = by_check,
    by_enumerator = by_enumerator,
    by_partner = by_partner,
    priority = priority,
    detail = detail
  )
}
