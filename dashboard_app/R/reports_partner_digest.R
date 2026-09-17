# Standalone report builder — NOT a dashboard feature. Deliberately kept
# out of any tab/module: this is a workbook you (Jack) generate yourself,
# primarily for IMPACT's own internal review — not something exposed to
# whoever has the live dashboard open. Renamed from "...for_FACT"
# 2026-08-21d: this is IMPACT's internal data-quality review first; what
# (if anything) gets shared onward with FACT — as a close field partner,
# not the primary audience — or disseminated further is a separate
# decision made after reviewing it, not baked into the report's identity.
# (An earlier version of this wired it up as a "Download partner digest"
# button on the Data Quality tab — corrected 2026-08-17d per your steer;
# see the README's 2026-08-17b/2026-08-17d entries for that history.)
#
# Lives under R/ (not top-level) so global.R's own source(f) loop picks it
# up like every other file here — that's what makes build_partner_quality_
# digest_excel() available both to generate_partner_digest.R (project
# root) and to tests/smoke_test.R (which sources global.R at the top)
# with no extra wiring. It plays no part in the deployed app itself:
# nothing in app.R/ui.R ever calls it, so it costs nothing at runtime
# beyond the negligible cost of parsing a few dozen extra lines at
# startup, same as any unused function would.
#
# Integrated into deploy_dashboard.R 2026-08-21d — the report and the
# dashboard are both downstream of the same daily data refresh, and
# Jack's steer was that they're "inherently linked" and should be
# generated together rather than as two things to remember separately.
# generate_partner_digest.R (project root) is still a standalone entry
# point too, for regenerating just the report without redeploying.
#
# Cumulative to date, same convention as the Partner Report exports (see
# mod_partner_report.R) — a report handed off for follow-up should reflect
# everything so far, not whatever date window happened to be selected in
# the sidebar when it was generated. Never filtered by filtered_subs().
#
# ---- Restructured 2026-08-20, per Jack's review of the first draft --------
# Two changes drove this:
#  1. Too many tabs, and the two "by partner" sheets (dashboard-flag vs
#     cleaning-log) were genuinely confusing side by side — which one do
#     you look at? Consolidated by ENTITY instead: one "Partners" sheet
#     and one "Enumerators" sheet, each a full roster (every partner/
#     enumerator with a submission, not just flagged ones) carrying BOTH
#     families of metric as one wide table. Confirmed with Jack this beats
#     the alternative (grouping by analysis-type instead of entity) mainly
#     because it keeps one consistent row-grain per sheet — works as a
#     real sortable/filterable Excel Table, which a mixed partner+
#     enumerator sheet couldn't.
#  2. Nothing was flagging oversampled clusters (achieved > target) even
#     though that's a real resourcing problem — wasted fieldwork days, and
#     likely surplus data that needs deleting. Added as its own sheet,
#     computed straight from the same target_households the Coverage Map
#     itself uses (psu_hexagons_sf/psu_sites_sf), not from the cleaning
#     logs — this is a sampling-design question, not a response-quality
#     one, so it doesn't go through the tier system below.
#
# Nine sheets, in three families:
#
# Navigation:
#   - "Read me" — what everything below actually replaces the old
#     "Summary" sheet: a sheet-by-sheet guide, the severity-tier
#     definitions, an explanation of "Total flag instances" vs the tier
#     columns (a real point of confusion in the first draft), and the
#     same headline numbers "Summary" used to hold alone.
#
# Dashboard-flag half (submissions_raw's own GPS/duration/hh-size/
# off-hours/duplicate flags — sample-vs-submission MATCHING integrity,
# not response content):
#   - Feeds into "Partners"/"Enumerators" below (merged with the
#     cleaning-log half) and:
#   - "Flagged submissions" — full row-level detail (PII-stripped, see
#     strip_row_level_pii() in global.R), same Yes/No convention as the
#     Data Quality tab's own flagged table, plus Off-hours.
#
# Cleaning-log half (from cleaning/real/summarise_cleaning_logs.R —
# response-CONTENT checks: FSL plausibility, survey duration, listing/
# sampling integrity. Complementary to the dashboard-flag half above, not
# a replacement — neither system checks what the other one does):
#   - Feeds into "Partners"/"Enumerators" below and:
#   - "Priority follow-up" — submissions with a tier-A (recommend
#     deletion) issue, or already auto-marked remove_survey by the
#     cleaning script, cross-checked against submissions_raw so it's clear
#     at a glance which of these are STILL counting toward the
#     achieved total right now. This is the "needs resampling" action
#     list — the whole reason this section exists.
#   - "Common errors" — per check_id rollup (tier, plain-English issue
#     text, submissions/enumerators/partners affected) — "what common
#     errors are we having problems with," independent of who caused them.
#   - "Cleaning log detail" — row-level drill-down, tier-annotated.
#
# Merged entity sheets:
#   - "Partners" / "Enumerators" — one row per entity, full roster.
#     Columns: submission/achieved counts, sample-integrity flags, then
#     cleaning-log flags (tier A/B/C + "Flagged issues" list + "Total
#     flag instances"), then (Partners only) how many of their
#     enumerators are HIGH priority and how many clusters they've
#     oversampled.
#
# Sampling-design (separate concern from response quality — no tier):
#   - "Oversampled clusters" — target vs achieved per cluster, wherever
#     achieved > target. Assigned partner (from Partnerscoverage.xlsx) vs
#     actual submitting partner(s) shown separately, since a mismatch
#     there is its own signal worth seeing.
#
# Severity tiers (A = recommend deletion .. D = not a partner issue) are
# CHECK_TIER in summarise_cleaning_logs.R — a judgement call, not derived
# from the cleaning script's own change_type column (which is only
# populated for the most recent log date, and inconsistently even there).
# See that file's header for the full reasoning; revisit CHECK_TIER first
# if a tiering ever looks wrong here.
#
# Regression-tested in tests/smoke_test.R — covers sheet structure, the
# "other" catch-all exclusion (see note below), and PII exclusion.

# ---- shared styling (navy/black, 2026-08-20 per Jack's request) -------------
DIGEST_NAVY <- "#1F3864"
DIGEST_NAVY_LIGHT <- "#D9E2F3"

digest_header_style <- function(wb, sheet, ncol, row = 1) {
  addStyle(
    wb, sheet,
    createStyle(fgFill = DIGEST_NAVY, fontColour = "white", textDecoration = "bold", wrapText = TRUE, valign = "center"),
    rows = row, cols = 1:ncol, gridExpand = TRUE, stack = TRUE
  )
}

# thick left border marking where a new column group starts, for the wide
# Partners/Enumerators tables — cheaper and safer to get right (blind, with
# no way to render the actual .xlsx) than a merged two-row super-header.
digest_section_divider <- function(wb, sheet, col, n_data_rows) {
  addStyle(
    wb, sheet,
    createStyle(border = "left", borderStyle = "medium", borderColour = DIGEST_NAVY),
    rows = 1:(n_data_rows + 1), cols = col, gridExpand = TRUE, stack = TRUE
  )
}

build_partner_quality_digest_excel <- function(file, cleaning_log) {
  achieved_flag <- is_achieved(submissions_raw)

  yn <- function(x) factor(ifelse(x, "Yes", "No"), levels = c("Yes", "No"))

  # ---- Achieved, capped at cluster level, attributed by partner (added
  # 2026-08-24 — see is_collected()/is_achieved()/cluster_targets in
  # global.R). If a cluster's achieved submissions come from more than one
  # org (rare — clusters usually belong to one partner's assigned LGA),
  # EACH org with a submission there gets the cluster's full capped total
  # counted, same non-splitting convention partner_progress_by_lga()
  # already uses for jointly-covered LGAs ("shared_with") — not divided
  # proportionally, deliberately: inventing a split rule adds complexity
  # for a case that's rare in practice and doesn't change which partners
  # need follow-up. Enumerator-level Achieved (below) is deliberately NOT
  # capped this way — confirmed with Jack 2026-08-24: enumerators don't
  # have individual targets to cap against, and that sheet's job is
  # quality-rate patterns, not coverage tracking.
  achieved_rows <- submissions_raw[achieved_flag & !is.na(submissions_raw$matched_cluster_id), ]
  # FIX 2026-09-16 (Jack, via cross-session flag - the 94-interview national
  # undercount smoke_test.R's sum(partners$Achieved) >= sum(progress_by_
  # stratum$achieved_n) assertion caught): this cluster-level cap never
  # picked up the 2026-09-14 stranded-achieved-credit policy compute_
  # progress_by_stratum() already applies (global.R) - a cluster retired
  # from cluster_targets (target_households NA, coalesced to 0 below) was
  # still being pmin()'d to 0 here instead of passed through uncapped. Same
  # stranded branch, ported verbatim from global.R's achieved_by_cluster.
  cluster_capped <- achieved_rows %>%
    count(matched_cluster_id, name = "cluster_achieved_n") %>%
    left_join(cluster_targets, by = c("matched_cluster_id" = "cluster_id")) %>%
    mutate(
      stranded = is.na(target_households),
      target_households = coalesce(target_households, 0),
      capped_achieved_n = if_else(stranded, cluster_achieved_n, pmin(cluster_achieved_n, target_households))
    )
  achieved_capped_by_org <- achieved_rows %>%
    distinct(matched_cluster_id, org_id) %>%
    left_join(cluster_capped %>% select(matched_cluster_id, capped_achieved_n), by = "matched_cluster_id") %>%
    group_by(org_id) %>%
    summarise(achieved_capped = sum(capped_achieved_n), .groups = "drop")

  # ---- dashboard-flag (sample-integrity) rollups, by partner AND by
  # enumerator — the by-enumerator one is new 2026-08-20, didn't exist
  # before since only the cleaning-log half had enumerator-level detail ---
  integrity_by_partner <- submissions_raw %>%
    mutate(achieved_flag = achieved_flag) %>%
    group_by(org_id) %>%
    summarise(
      submissions = n(), collected = sum(interview_outcome == "completed"),
      consent_refused = sum(interview_outcome == "consent_refused"), achieved = sum(achieved_flag),
      integrity_flagged = sum(any_quality_flag), integrity_flag_rate = mean(any_quality_flag),
      gps_outliers = sum(flag_gps_outlier), duration_outliers = sum(flag_duration_outlier),
      hh_size_mismatches = sum(flag_hh_size_mismatch), duplicates = sum(is_duplicate),
      off_hours = sum(flag_off_hours), .groups = "drop"
    ) %>%
    left_join(achieved_capped_by_org, by = "org_id") %>%
    mutate(achieved = coalesce(achieved_capped, 0L)) %>%
    select(-achieved_capped)

  integrity_by_enum <- submissions_raw %>%
    mutate(achieved_flag = achieved_flag) %>%
    group_by(enum_id) %>%
    summarise(
      submissions = n(), collected = sum(interview_outcome == "completed"), achieved = sum(achieved_flag),
      integrity_flagged = sum(any_quality_flag), integrity_flag_rate = mean(any_quality_flag),
      gps_outliers = sum(flag_gps_outlier), duration_outliers = sum(flag_duration_outlier),
      hh_size_mismatches = sum(flag_hh_size_mismatch), duplicates = sum(is_duplicate),
      off_hours = sum(flag_off_hours), .groups = "drop"
    )

  # assigned-but-zero-submissions partners — PARTNERS_NOT_STARTED (global.R,
  # moved there 2026-08-27 so the dashboard's Home page can show the same
  # rollup) already excludes org codes with no LGA assignment at all (e.g.
  # "jrs") and "other" (global.R's coalesce() fallback for the one LGA with
  # no confirmed partner match — not a partner anyone can actually follow
  # up with).
  not_started <- PARTNERS_NOT_STARTED

  flagged_detail <- submissions_raw %>%
    strip_row_level_pii() %>%
    filter(any_quality_flag) %>%
    mutate(Partner = unname(ORG_LABELS[org_id])) %>%
    transmute(
      Partner, Date = submission_date, State = admin1, LGA = admin2_submitted, Enumerator = enum_id,
      `Duration (min)` = duration_min, `GPS dist. (m)` = dist_to_matched_point_m,
      `Match quality` = match_quality,
      `GPS outlier` = yn(flag_gps_outlier), `Duration outlier` = yn(flag_duration_outlier),
      `HH size mismatch` = yn(flag_hh_size_mismatch), `Off-hours` = yn(flag_off_hours),
      Duplicate = yn(is_duplicate)
    ) %>%
    arrange(Partner, desc(Date))

  # ---- oversampled clusters (compute_oversampled_clusters(), global.R —
  # moved there 2026-08-27, same reasoning as PARTNERS_NOT_STARTED above) --
  oversampled <- oversampled_clusters
  oversampled_by_org <- oversampled %>%
    tidyr::separate_rows(submitting_org_ids, sep = ", ") %>%
    filter(submitting_org_ids != "") %>%
    count(submitting_org_ids, name = "n_oversampled_clusters") %>%
    rename(org_id = submitting_org_ids)

  # ---- merged Partners / Enumerators (dashboard-flag + cleaning-log) --------
  # cleaning_log$by_partner/by_enumerator can now include entities with NO
  # row in submissions_raw yet (see the union-roster note in
  # summarise_cleaning_logs.R) — full_join() keeps them rather than
  # dropping their cleaning-log flags, but the dashboard-flag columns
  # (Submissions/Collected/Achieved/GPS outliers/...) are genuinely unknown
  # for them until their data is pulled in, so those coalesce to 0 rather
  # than showing NA/blank, consistent with how a "hasn't started" partner
  # is already shown elsewhere in this workbook.
  integrity_cols_p <- c(
    "collected", "consent_refused", "achieved", "integrity_flagged",
    "gps_outliers", "duration_outliers", "hh_size_mismatches", "duplicates", "off_hours"
  )
  partners_merged <- integrity_by_partner %>%
    full_join(cleaning_log$by_partner, by = "org_id", suffix = c("", "_cl")) %>%
    left_join(oversampled_by_org, by = "org_id") %>%
    mutate(
      Partner = coalesce(Partner, unname(ORG_LABELS[org_id])),
      # submissions falls back to the cleaning-log roster's own total
      # (itself pmax-protected, see summarise_cleaning_logs.R) BEFORE the
      # other integrity columns coalesce to 0, so a true phantom partner
      # (no submissions_raw row at all) shows what the cleaning log
      # actually knows about their volume rather than a contradictory
      # "0 submissions, N flagged."
      submissions = coalesce(submissions, total_submissions),
      across(any_of(integrity_cols_p), ~coalesce(.x, 0L)),
      integrity_flag_rate = ifelse(submissions > 0, integrity_flagged / submissions, NA_real_),
      n_oversampled_clusters = coalesce(n_oversampled_clusters, 0L)
    ) %>%
    arrange(desc(tier_a), desc(integrity_flag_rate)) %>%
    transmute(
      Partner, Submissions = submissions, Collected = collected, `Consent refused` = consent_refused, Achieved = achieved,
      `Integrity flagged` = integrity_flagged, `Integrity flag rate` = integrity_flag_rate,
      `GPS outliers` = gps_outliers, `Duration outliers` = duration_outliers,
      `HH size mismatches` = hh_size_mismatches, Duplicates = duplicates, `Off-hours` = off_hours,
      `Cleaning-log flagged` = submissions_flagged, `Cleaning-log flag rate` = flag_rate,
      `Tier A (likely delete)` = tier_a, `Tier B (needs review)` = tier_b, `Tier C (pattern)` = tier_c,
      `Total flag instances` = flag_instances, `Flagged issues` = flagged_issues,
      `Enumerators (total)` = total_enumerators, `Enumerators flagged` = enumerators_flagged,
      `Enumerators at HIGH priority` = enumerators_high_priority,
      `Oversampled clusters` = n_oversampled_clusters
    )

  integrity_cols_e <- c("collected", "achieved", "integrity_flagged", "gps_outliers", "duration_outliers", "hh_size_mismatches", "duplicates", "off_hours")
  enumerators_merged <- integrity_by_enum %>%
    full_join(cleaning_log$by_enumerator, by = "enum_id", suffix = c("", "_cl")) %>%
    mutate(
      # see the matching note on partners_merged above — same fallback
      # order (submissions before the other integrity columns), same
      # reason (a union-rostered enumerator can have no submissions_raw
      # row at all).
      submissions = coalesce(submissions, total_submissions),
      across(any_of(integrity_cols_e), ~coalesce(.x, 0L)),
      integrity_flag_rate = ifelse(submissions > 0, integrity_flagged / submissions, NA_real_)
    ) %>%
    arrange(factor(priority, levels = c("HIGH", "MEDIUM", "LOW")), desc(tier_a), desc(integrity_flag_rate)) %>%
    transmute(
      Partner, Enumerator = enum_id, Submissions = submissions, Collected = collected, Achieved = achieved,
      `Integrity flagged` = integrity_flagged, `Integrity flag rate` = integrity_flag_rate,
      `GPS outliers` = gps_outliers, `Duration outliers` = duration_outliers,
      `HH size mismatches` = hh_size_mismatches, Duplicates = duplicates, `Off-hours` = off_hours,
      `Cleaning-log flagged` = submissions_flagged, `Cleaning-log flag rate` = flag_rate,
      `Tier A (likely delete)` = tier_a, `Tier B (needs review)` = tier_b, `Tier C (pattern)` = tier_c,
      `Total flag instances` = flag_instances, `Flagged issues` = flagged_issues,
      Priority = priority
    )

  # ---- headline numbers, shared by Read me + used to build it ---------------
  cl_period <- if (length(cleaning_log$missing_dates) == 0) {
    sprintf("%s to %s", format(min(cleaning_log$dates_covered), "%d %b"), format(max(cleaning_log$dates_covered), "%d %b"))
  } else {
    sprintf(
      "%s to %s (missing: %s)",
      format(min(cleaning_log$dates_covered), "%d %b"), format(max(cleaning_log$dates_covered), "%d %b"),
      paste(format(cleaning_log$missing_dates, "%d %b"), collapse = ", ")
    )
  }
  # Each "...of which" line must be scoped to its OWN preceding row's subset
  # (tier-A rows vs remove_survey-marked rows) rather than the whole
  # priority table — the two subsets overlap heavily in practice (every
  # remove_survey-marked row happens to also be tier-A in the data seen so
  # far) but aren't guaranteed identical, so summing across all of
  # cleaning_log$priority for both would silently mislabel counts the day
  # that stops being true (caught 2026-08-18 reviewing the first real run:
  # remove_survey=27 but a same-scope in_dataset sum of 41 is impossible).
  is_tier_a <- cleaning_log$priority$worst_tier == "A"
  is_remove_survey <- cleaning_log$priority$any_remove_survey
  n_tier_a <- sum(is_tier_a)
  n_tier_a_still_achieved <- sum(cleaning_log$priority$counts_as_achieved[is_tier_a])
  n_remove_survey <- sum(is_remove_survey)
  n_remove_survey_still_present <- sum(cleaning_log$priority$in_dataset[is_remove_survey])
  n_oversampled_clusters <- nrow(oversampled)
  n_surplus_submissions <- sum(oversampled$surplus)

  summary_fields <- c(
    "Report", "Generated", "Total submissions", "Total flagged for review (sample integrity)",
    "Overall integrity flag rate", "Partners with zero submissions so far", "Cleaning-log period covered",
    "Submissions with a tier-A cleaning-log issue (recommend deletion)",
    "...of which still counting toward the achieved total",
    "Submissions already marked \"remove_survey\" by the cleaning script",
    "...of which still present in the dataset",
    "Oversampled clusters (achieved > target)", "...surplus submissions across those clusters"
  )
  summary_values <- c(
    "MSNA N-WEC 2026 — Partner Data Quality Digest", format(Sys.time(), "%d %b %Y %H:%M"),
    comma(nrow(submissions_raw)), comma(sum(submissions_raw$any_quality_flag)),
    fmt_pct(mean(submissions_raw$any_quality_flag)),
    if (length(not_started) == 0) "None" else paste(unname(ORG_LABELS[not_started]), collapse = ", "),
    cl_period, comma(n_tier_a), comma(n_tier_a_still_achieved),
    comma(n_remove_survey), comma(n_remove_survey_still_present),
    comma(n_oversampled_clusters), comma(n_surplus_submissions)
  )

  wb <- createWorkbook()

  # ============================================================================
  # Read me — navigation guide + tier definitions + headline numbers. Replaces
  # the old "Summary" sheet, which was just the headline numbers alone.
  # ============================================================================
  sheetR <- "Read me"
  addWorksheet(wb, sheetR)
  r <- 1
  write_title <- function(text, size = 18, colour = DIGEST_NAVY) {
    writeData(wb, sheetR, text, startRow = r, colNames = FALSE)
    addStyle(wb, sheetR, createStyle(fontSize = size, textDecoration = "bold", fontColour = colour), rows = r, cols = 1)
    r <<- r + 1
  }
  write_section <- function(title, span = 6) {
    writeData(wb, sheetR, title, startRow = r, colNames = FALSE)
    addStyle(
      wb, sheetR, createStyle(fontSize = 13, textDecoration = "bold", fontColour = "white", fgFill = DIGEST_NAVY),
      rows = r, cols = 1:span, gridExpand = TRUE
    )
    r <<- r + 1
  }
  write_para <- function(text, height = 60) {
    writeData(wb, sheetR, text, startRow = r, colNames = FALSE)
    addStyle(wb, sheetR, createStyle(wrapText = TRUE), rows = r, cols = 1:6, gridExpand = TRUE, stack = TRUE)
    mergeCells(wb, sheetR, cols = 1:6, rows = r)
    setRowHeights(wb, sheetR, rows = r, heights = height)
    r <<- r + 1
  }
  write_table <- function(df) {
    writeDataTable(wb, sheetR, df, startRow = r, tableStyle = "TableStyleLight1")
    digest_header_style(wb, sheetR, ncol(df), row = r)
    setColWidths(wb, sheetR, cols = seq_len(ncol(df)), widths = "auto")
    r <<- r + nrow(df) + 2
  }

  write_title("MSNA N-WEC 2026 — Partner Data Quality Digest")
  write_title(
    paste0("Internal IMPACT review — generated ", format(Sys.time(), "%d %b %Y %H:%M"),
           " — what (if anything) to share with FACT or other partners is a decision made after reviewing this, not assumed"),
    size = 11, colour = "black"
  )
  r <- r + 1

  write_section("How to use this workbook")
  write_table(data.frame(
    Sheet = c(
      "Priority follow-up", "Partners", "Enumerators", "Oversampled clusters",
      "Common errors", "Flagged submissions", "Cleaning log detail"
    ),
    `What it shows` = c(
      "Submissions with a serious (tier A) issue, or already marked for removal by the cleaning script, cross-checked against whether they're still counted in your live achieved total.",
      "One row per partner: Collected vs. Achieved (capped, see \"A note on the numbers\" below) progress, sample-integrity flags (GPS/duration/roster/off-hours/duplicates), cleaning-log flags (tier A/B/C, which issues, how many), and how many clusters they've oversampled.",
      "Same as Partners, one row per enumerator — the individual-level view. Achieved here is NOT capped the way Partners' is (see \"A note on the numbers\").",
      "Clusters that have received MORE completed interviews than their target. Wasted fieldwork effort, and likely surplus data that will need a deletion decision.",
      "Which check TYPES are most common overall, independent of who caused them — for spotting tool-level or systemic issues vs individual behaviour.",
      "Row-level detail behind the sample-integrity numbers (GPS/duration/roster/off-hours/duplicates) — find the exact record.",
      "Row-level detail behind the cleaning-log numbers (FSL/duration/listing), tier-annotated — find the exact record."
    ),
    `Start here if...` = c(
      "You want to know what needs action today",
      "You're prepping for a partner check-in",
      "You need to name specific enumerators for retraining",
      "You're deciding whether to send a team back to a cluster",
      "You want the pattern, not the individual",
      "A Partners/Enumerators number needs a specific record",
      "A Partners/Enumerators number needs a specific record"
    ),
    check.names = FALSE
  ))

  write_section("Severity tiers (cleaning-log issues)")
  write_table(data.frame(
    Tier = c("A - Recommend deletion", "B - Needs review", "C - Pattern only", "D - Not a partner issue"),
    Meaning = c(
      "Structurally invalid or unrecoverable response (e.g. every food group reported as zero for a week, an entire module left blank, a survey completed implausibly fast).",
      "Flagged but ambiguous — a human needs to look at the specific case (e.g. GPS very close to another submission, borderline duration, a listing/sampling mismatch).",
      "Individually plausible on a single survey. Only becomes a concern if ONE enumerator has an unusually high RATE of it across many of their surveys.",
      "Self-correcting (the cleaning script already auto-fixes it) or a statistical signal — not a data-quality defect attributable to the partner."
    ),
    `What to do` = c(
      "Review for removal; resample if deleted.",
      "Check the specific record on the detail sheets.",
      "Only chase if the Enumerators sheet shows a high rate for one person, not a one-off.",
      "No action needed."
    ),
    check.names = FALSE
  ))

  write_section("A note on the numbers")
  write_para(paste(
    "\"Collected\" vs \"Achieved\" (Partners/Enumerators sheets): Collected is every completed interview,",
    "full stop — includes oversampled surplus, i.e. total field effort. Achieved is what",
    "actually counts toward the sample frame — completed, matched interviews that are not a SETTLED",
    "(confirmed/contested) tracker deletion — capped at each CLUSTER's",
    "own target before being summed up, so a partner can't inflate their Achieved by overshooting an",
    "easy cluster while another goes unmet. Policy changed 2026-09-11: a pending/unresolved flag no",
    "longer excludes an interview here, only a confirmed deletion does — same figure resampling now",
    "uses too. A big Collected-vs-Achieved gap on the Partners sheet is now genuine oversampling —",
    "wasted operational resource, not real progress. Enumerators' \"Achieved\" is deliberately NOT capped the",
    "same way (no individual per-enumerator target exists to cap against) — read it as their own",
    "completed/matched/not-a-settled-deletion count, not a coverage figure."
  ))
  write_para(paste(
    "On the Partners/Enumerators sheets: \"Tier A/B/C\" are counts of DISTINCT SUBMISSIONS with an issue in",
    "that tier — a submission with issues in two tiers is counted in both, so these three columns can add up",
    "to MORE than \"Cleaning-log flagged\" (which is the distinct-submission count, no double-counting).",
    "\"Total flag instances\" is a different number again: every (submission, issue-type) pair counted once,",
    "flat, not grouped by tier — the direct answer to \"how many flags in total.\" \"Flagged issues\" lists",
    "which issue types made up that total, most frequent first. \"Submissions\" is this partner/enumerator's",
    "true total as of the last dashboard data refresh; the cleaning logs update on their own daily schedule",
    "and can occasionally get slightly AHEAD of that — if \"Cleaning-log flagged\" ever looks larger than",
    "\"Submissions\" for someone, that's why, not a data error."
  ))

  write_section("Top-level summary")
  write_table(data.frame(Field = summary_fields, Value = summary_values, check.names = FALSE))
  setColWidths(wb, sheetR, cols = 1:3, widths = c(42, 70, 40))

  # ============================================================================
  sheetP <- "Priority follow-up"
  addWorksheet(wb, sheetP)
  priority_sheet <- cleaning_log$priority %>%
    transmute(
      Partner, Enumerator = enum_id, State = admin1_name, LGA = admin2_name, Ward = admin3_name,
      `First flagged` = log_date, `Issue(s)` = issues, `Check type(s)` = checks,
      `Marked for removal by cleaning script` = yn(any_remove_survey),
      `Still in dataset` = yn(in_dataset), `Counting as achieved` = yn(counts_as_achieved)
    )
  writeDataTable(wb, sheetP, priority_sheet, tableStyle = "TableStyleLight1")
  digest_header_style(wb, sheetP, ncol(priority_sheet))
  setColWidths(wb, sheetP, cols = 1:ncol(priority_sheet), widths = "auto")
  freezePane(wb, sheetP, firstRow = TRUE)

  # ============================================================================
  sheetPartners <- "Partners"
  addWorksheet(wb, sheetPartners)
  writeDataTable(wb, sheetPartners, partners_merged, tableStyle = "TableStyleLight1")
  digest_header_style(wb, sheetPartners, ncol(partners_merged))
  n_p <- nrow(partners_merged)
  for (col_name in c("Integrity flag rate", "Cleaning-log flag rate")) {
    pc <- which(names(partners_merged) == col_name)
    addStyle(wb, sheetPartners, createStyle(numFmt = "0%"), rows = 2:(n_p + 1), cols = pc, gridExpand = TRUE, stack = TRUE)
  }
  digest_section_divider(wb, sheetPartners, which(names(partners_merged) == "Integrity flagged"), n_p)
  digest_section_divider(wb, sheetPartners, which(names(partners_merged) == "Cleaning-log flagged"), n_p)
  digest_section_divider(wb, sheetPartners, which(names(partners_merged) == "Oversampled clusters"), n_p)
  setColWidths(wb, sheetPartners, cols = 1:ncol(partners_merged), widths = "auto")
  freezePane(wb, sheetPartners, firstActiveRow = 2, firstActiveCol = 3)

  # ============================================================================
  sheetEnum <- "Enumerators"
  addWorksheet(wb, sheetEnum)
  writeDataTable(wb, sheetEnum, enumerators_merged, tableStyle = "TableStyleLight1")
  digest_header_style(wb, sheetEnum, ncol(enumerators_merged))
  n_e <- nrow(enumerators_merged)
  for (col_name in c("Integrity flag rate", "Cleaning-log flag rate")) {
    ec <- which(names(enumerators_merged) == col_name)
    addStyle(wb, sheetEnum, createStyle(numFmt = "0%"), rows = 2:(n_e + 1), cols = ec, gridExpand = TRUE, stack = TRUE)
  }
  digest_section_divider(wb, sheetEnum, which(names(enumerators_merged) == "Integrity flagged"), n_e)
  digest_section_divider(wb, sheetEnum, which(names(enumerators_merged) == "Cleaning-log flagged"), n_e)
  setColWidths(wb, sheetEnum, cols = 1:ncol(enumerators_merged), widths = "auto")
  freezePane(wb, sheetEnum, firstActiveRow = 2, firstActiveCol = 3)

  # ============================================================================
  sheetOver <- "Oversampled clusters"
  addWorksheet(wb, sheetOver)
  oversampled_sheet <- oversampled %>%
    transmute(
      `Cluster ID` = cluster_id, State = adm1_name, LGA = adm2_name,
      `Population type` = ifelse(pop_type == "idp", "IDP", "Non-IDP"),
      `Target HH` = target_households, Achieved = achieved_n, Surplus = surplus,
      `% over target` = pct_over_target,
      `Assigned partner(s)` = vapply(adm2_pcode, partner_coverage_label, character(1)),
      `Submitting partner(s)` = vapply(
        strsplit(submitting_org_ids, ", "), function(ids) paste(unname(ORG_LABELS[ids]), collapse = ", "),
        character(1)
      )
    )
  writeDataTable(wb, sheetOver, oversampled_sheet, tableStyle = "TableStyleLight1")
  digest_header_style(wb, sheetOver, ncol(oversampled_sheet))
  pct_col_o <- which(names(oversampled_sheet) == "% over target")
  addStyle(wb, sheetOver, createStyle(numFmt = "0%"), rows = 2:(nrow(oversampled_sheet) + 1), cols = pct_col_o, gridExpand = TRUE, stack = TRUE)
  setColWidths(wb, sheetOver, cols = 1:ncol(oversampled_sheet), widths = "auto")
  freezePane(wb, sheetOver, firstRow = TRUE)

  # ============================================================================
  sheetC <- "Common errors"
  addWorksheet(wb, sheetC)
  by_check_sheet <- cleaning_log$by_check %>%
    transmute(
      Tier = unname(TIER_LABEL[tier]), `Check type` = check_id, Issue = issue,
      Submissions = submissions, Rows = rows, Enumerators = enumerators, Partners = partners
    )
  writeDataTable(wb, sheetC, by_check_sheet, tableStyle = "TableStyleLight1")
  digest_header_style(wb, sheetC, ncol(by_check_sheet))
  setColWidths(wb, sheetC, cols = 1:ncol(by_check_sheet), widths = "auto")
  freezePane(wb, sheetC, firstRow = TRUE)

  # ============================================================================
  sheetF <- "Flagged submissions"
  addWorksheet(wb, sheetF)
  writeDataTable(wb, sheetF, flagged_detail, tableStyle = "TableStyleLight1")
  digest_header_style(wb, sheetF, ncol(flagged_detail))
  setColWidths(wb, sheetF, cols = 1:ncol(flagged_detail), widths = "auto")
  freezePane(wb, sheetF, firstRow = TRUE)

  # ============================================================================
  sheetD <- "Cleaning log detail"
  addWorksheet(wb, sheetD)
  writeDataTable(wb, sheetD, cleaning_log$detail, tableStyle = "TableStyleLight1")
  digest_header_style(wb, sheetD, ncol(cleaning_log$detail))
  setColWidths(wb, sheetD, cols = 1:ncol(cleaning_log$detail), widths = "auto")
  freezePane(wb, sheetD, firstRow = TRUE)

  saveWorkbook(wb, file, overwrite = TRUE)
}
