# Standalone report builder — NOT a dashboard feature. Deliberately kept
# out of any tab/module: this is a workbook you (Jack) generate yourself
# and send directly to FACT, not something exposed to whoever has the
# live dashboard open. (An earlier version of this wired it up as a
# "Download partner digest" button on the Data Quality tab — corrected
# 2026-08-17d per your steer; see the README's 2026-08-17b/2026-08-17d
# entries for that history.)
#
# Lives under R/ (not top-level) so global.R's own source(f) loop picks it
# up like every other file here — that's what makes build_fact_quality_
# digest_excel() available both to generate_fact_digest.R (project root)
# and to tests/smoke_test.R (which sources global.R at the top) with no
# extra wiring. It plays no part in the deployed app itself: nothing in
# app.R/ui.R ever calls it, so it costs nothing at runtime beyond the
# negligible cost of parsing a few dozen extra lines at startup, same as
# any unused function would.
#
# Meant to be regenerated daily — see generate_fact_digest.R at the
# project root for the actual "run this" entry point and the daily
# workflow (it's exactly the dashboard's own daily data-refresh step,
# nothing extra to maintain for the digest itself).
#
# Cumulative to date, same convention as the Partner Report exports (see
# mod_partner_report.R) — a report handed off for follow-up should reflect
# everything so far, not whatever date window happened to be selected in
# the sidebar when it was generated. Never filtered by filtered_subs().
#
# Three sheets:
#   - "Summary" — headline numbers + the same "hasn't started" list as the
#     ad hoc one given verbally on 2026-08-17, so FACT doesn't have to ask
#     for that separately each time.
#   - "By partner" — one row per partner *with at least one submission*,
#     sorted worst-flag-rate-first so the priority follow-ups are
#     immediately visible without FACT having to sort it themselves.
#   - "Flagged submissions" — full row-level detail (PII-stripped, see
#     strip_row_level_pii() in global.R) across every partner, for the
#     cases where "which one" not just "how many" is needed. Same flag
#     columns/Yes-No convention as the Data Quality tab's own flagged
#     table, plus Off-hours (tracked dashboard-wide but normally surfaced
#     on the separate Data Integrity Checks tab) since it's a legitimate
#     thing to raise with a partner directly.
#
# Regression-tested in tests/smoke_test.R — covers sheet structure, the
# "other" catch-all exclusion (see note below), and PII exclusion.

build_fact_quality_digest_excel <- function(file) {
  achieved_flag <- is_achieved(submissions_raw)

  by_partner <- submissions_raw %>%
    mutate(achieved_flag = achieved_flag) %>%
    group_by(org_id) %>%
    summarise(
      submissions = n(),
      completed = sum(interview_outcome == "completed"),
      consent_refused = sum(interview_outcome == "consent_refused"),
      achieved = sum(achieved_flag),
      flagged = sum(any_quality_flag),
      flag_rate = mean(any_quality_flag),
      gps_outliers = sum(flag_gps_outlier),
      duration_outliers = sum(flag_duration_outlier),
      hh_size_mismatches = sum(flag_hh_size_mismatch),
      duplicates = sum(is_duplicate),
      off_hours = sum(flag_off_hours),
      .groups = "drop"
    ) %>%
    mutate(Partner = unname(ORG_LABELS[org_id])) %>%
    arrange(desc(flag_rate)) %>%
    transmute(
      Partner, Submissions = submissions, Completed = completed, `Consent refused` = consent_refused,
      Achieved = achieved, `Flagged for review` = flagged, `Flag rate` = flag_rate,
      `GPS outliers` = gps_outliers, `Duration outliers` = duration_outliers,
      `HH size mismatches` = hh_size_mismatches, Duplicates = duplicates, `Off-hours` = off_hours
    )

  # assigned-but-zero-submissions partners, for the same "hasn't started"
  # follow-up FACT would otherwise have to ask for separately — excludes
  # org codes with no LGA assignment at all (e.g. "jrs"), and "other",
  # which isn't a real organisation but global.R's coalesce() fallback for
  # the one LGA with no confirmed partner match (see filter_base) — not
  # someone FACT can actually follow up with.
  assigned <- setdiff(names(partner_adm2)[lengths(partner_adm2) > 0], "other")
  not_started <- setdiff(assigned, submissions_raw$org_id)

  yn <- function(x) factor(ifelse(x, "Yes", "No"), levels = c("Yes", "No"))
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

  wb <- createWorkbook()

  addWorksheet(wb, "Summary")
  writeData(
    wb, "Summary",
    data.frame(
      Field = c("Report", "Generated", "Total submissions", "Total flagged for review", "Overall flag rate",
                "Partners with zero submissions so far"),
      Value = c(
        "MSNA N-WEC 2026 — Partner Data Quality Digest (for FACT)", format(Sys.time(), "%d %b %Y %H:%M"),
        comma(nrow(submissions_raw)), comma(sum(submissions_raw$any_quality_flag)),
        fmt_pct(mean(submissions_raw$any_quality_flag)),
        if (length(not_started) == 0) "None" else paste(unname(ORG_LABELS[not_started]), collapse = ", ")
      )
    ),
    colNames = FALSE
  )
  setColWidths(wb, "Summary", cols = 1:2, widths = c(30, 60))
  addStyle(wb, "Summary", createStyle(textDecoration = "bold"), rows = 1:6, cols = 1)
  addStyle(wb, "Summary", createStyle(wrapText = TRUE), rows = 1:6, cols = 2, stack = TRUE)

  sheet2 <- "By partner"
  addWorksheet(wb, sheet2)
  writeDataTable(wb, sheet2, by_partner, tableStyle = "TableStyleLight9")
  pct_col <- which(names(by_partner) == "Flag rate")
  addStyle(wb, sheet2, createStyle(numFmt = "0%"), rows = 2:(nrow(by_partner) + 1), cols = pct_col, gridExpand = TRUE, stack = TRUE)
  setColWidths(wb, sheet2, cols = 1:ncol(by_partner), widths = "auto")
  freezePane(wb, sheet2, firstRow = TRUE)

  sheet3 <- "Flagged submissions"
  addWorksheet(wb, sheet3)
  writeDataTable(wb, sheet3, flagged_detail, tableStyle = "TableStyleLight9")
  setColWidths(wb, sheet3, cols = 1:ncol(flagged_detail), widths = "auto")
  freezePane(wb, sheet3, firstRow = TRUE)

  saveWorkbook(wb, file, overwrite = TRUE)
}
