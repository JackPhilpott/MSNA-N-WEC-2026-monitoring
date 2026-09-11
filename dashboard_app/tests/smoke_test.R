# Run from the dashboard_app/ directory (or via `source("tests/smoke_test.R")`
# with working directory already set to dashboard_app/). Exercises every
# module's server logic via shiny::testServer, without needing a browser —
# catches data/reactive-wiring errors fast during development.
if (basename(getwd()) == "tests") setwd("..")
source("global.R")

cat("=== mod_progress_server ===\n")
testServer(mod_progress_server, args = list(
  filtered_subs = reactive(submissions_raw),
  filtered_stratum = reactive(progress_by_stratum)
), {
  session$flushReact()
  cat("kpi_achieved:", output$kpi_achieved, "\n")
  cat("kpi_pct:", output$kpi_pct, "\n")
  cat("kpi_collected:", output$kpi_collected, "\n")
  cat("kpi_followup:", output$kpi_followup, "\n")
  cat("kpi_days_remaining:", output$kpi_days_remaining, "\n")
  cat("kpi_days_required:", output$kpi_days_required, "\n")
  cat("trend_plot class ok:", !is.null(output$trend_plot), "\n")
  cat("region_plot class ok:", !is.null(output$region_plot), "\n")
})

cat("\n=== mod_map_server ===\n")
testServer(mod_map_server, args = list(
  filtered_stratum = reactive(progress_by_stratum),
  filtered_subs = reactive(submissions_raw)
), {
  session$flushReact()
  cat("map rendered ok:", !is.null(output$map), "\n")
  session$setInputs(map_view = "cluster")
  session$flushReact()
  cat("map switched to cluster view ok:", !is.null(output$map), "\n")
})

cat("\n=== mod_table_server ===\n")
testServer(mod_table_server, args = list(filtered_stratum = reactive(progress_by_stratum)), {
  session$flushReact()
  cat("table rendered ok:", !is.null(output$table), "\n")
})

cat("\n=== mod_quality_server ===\n")
testServer(mod_quality_server, args = list(filtered_subs = reactive(submissions_raw)), {
  session$flushReact()
  cat("kpi_flagged:", output$kpi_flagged, "\n")
  cat("kpi_gps:", output$kpi_gps, "\n")
  cat("kpi_duration:", output$kpi_duration, "\n")
  cat("kpi_dup:", output$kpi_dup, "\n")
  cat("flag_plot rendered ok:", !is.null(output$flag_plot), "\n")
  cat("flagged_table rendered ok:", !is.null(output$flagged_table), "\n")
})

cat("\n=== Partner data quality digest (build_partner_quality_digest_excel, R/reports_partner_digest.R) ===\n")
# Regression test for the recurring (daily) digest added 2026-08-17 — this
# is a standalone report (generate_partner_digest.R at the project root,
# now also integrated into deploy_dashboard.R — 2026-08-21d), NOT a
# dashboard feature (corrected 2026-08-17d, see README), but it's still
# meant to be re-generated every day as submissions_raw refreshes, so it
# needs a permanent test the same as any other daily-driven output, not
# just a one-time manual check. Renamed from "FACT" digest 2026-08-21d:
# it's IMPACT's internal review first, not something branded for/sent to
# FACT by default — see reports_partner_digest.R's header.
#
# Extended 2026-08-18 for the cleaning-log half (cleaning/real/
# summarise_cleaning_logs.R), and restructured 2026-08-20 (Read me sheet,
# Partners/Enumerators merged full-roster sheets, Oversampled clusters) —
# runs against whatever real cleaning logs/submissions exist on disk right
# now (same convention as the rest of this file), so assertions below
# check structural/reconciliation properties rather than hardcoded counts
# that would go stale as new daily logs are added.
source("../cleaning/real/summarise_cleaning_logs.R")
cleaning_log <- summarise_cleaning_logs()

digest_tmp <- tempfile(fileext = ".xlsx")
build_partner_quality_digest_excel(digest_tmp, cleaning_log)
digest_sheets <- getSheetNames(digest_tmp)
cat("Sheets:", paste(digest_sheets, collapse = ", "), "\n")
stopifnot(setequal(digest_sheets, c(
  "Read me", "Priority follow-up", "Partners", "Enumerators", "Oversampled clusters",
  "Common errors", "Flagged submissions", "Cleaning log detail"
)))

priority_sheet <- read.xlsx(digest_tmp, sheet = "Priority follow-up")
cat("Priority follow-up rows:", nrow(priority_sheet), "of", nrow(cleaning_log$priority), "expected\n")
stopifnot(nrow(priority_sheet) == nrow(cleaning_log$priority))
achieved_rows <- priority_sheet$`Counting.as.achieved` == "Yes"
cat("Priority rows counting as achieved that are also still in dataset:", sum(achieved_rows & priority_sheet$`Still.in.dataset` == "Yes"), "of", sum(achieved_rows), "\n")
stopifnot(all(priority_sheet$`Still.in.dataset`[achieved_rows] == "Yes")) # achieved implies present

# ---- Partners: full roster (every partner with a submission, not just
# flagged ones), dashboard-flag + cleaning-log columns merged into one
# wide table (2026-08-20, replacing the old separate "By partner"/"By
# partner (cleaning log)" sheets per Jack's steer) --------------------------
partners <- read.xlsx(digest_tmp, sheet = "Partners")
cat("Partners rows:", nrow(partners), "of", dplyr::n_distinct(submissions_raw$org_id), "active partners (full roster)\n")
# >= not ==: the roster is a UNION of submissions_raw's org_ids and the
# cleaning logs' org_ids (see summarise_cleaning_logs.R, 2026-08-20) - a
# partner can appear in a cleaning log before their first submission is
# pulled into submissions_raw, so the roster (and the Submissions sum,
# which falls back to the cleaning log's own count for such a partner) can
# legitimately be larger than submissions_raw alone, never smaller.
stopifnot(nrow(partners) >= dplyr::n_distinct(submissions_raw$org_id))
stopifnot(sum(partners$Submissions) >= nrow(submissions_raw))
# Not == (2026-08-24): Partners$Achieved is now CAPPED at each cluster's
# own target before summing (see reports_partner_digest.R, same
# is_collected()/is_achieved() split as global.R's
# compute_progress_by_stratum()). Compare instead against
# progress_by_stratum's own (correctly deduplicated, one row per cluster)
# capped national total — Partners$Achieved can legitimately be >= that,
# never <, since a cluster shared by more than one org has its full capped
# total attributed to EACH org present (deliberate non-splitting
# convention, same as partner_progress_by_lga's "shared_with" handling)
# rather than divided between them. NOT asserting an upper bound against
# the raw is_achieved() total — capping usually pulls the sum down, but
# that same shared-cluster double-counting could in principle push it back
# above the raw figure if enough clusters are genuinely multi-org, so no
# safe upper bound exists to assert here.
stopifnot(sum(partners$Achieved) >= sum(progress_by_stratum$achieved_n))
stopifnot(sum(partners$Integrity.flagged) == sum(submissions_raw$any_quality_flag))
# each tier is a SUBSET of "flagged" (documented as such in Read me — the
# three tiers can jointly exceed Cleaning-log.flagged since one submission
# can carry issues in more than one tier, but no single tier ever can)
stopifnot(all(partners$`Tier.A.(likely.delete)` <= partners$`Cleaning-log.flagged`))
stopifnot(all(partners$`Tier.B.(needs.review)` <= partners$`Cleaning-log.flagged`))
stopifnot(all(partners$`Tier.C.(pattern)` <= partners$`Cleaning-log.flagged`))
# NOT asserting Cleaning-log.flagged <= Submissions here: "Submissions" is
# the TRUE submissions_raw count (deliberately not pmax-inflated, so it's
# honest), but cleaning logs and submissions_raw refresh on independent
# schedules (see summarise_cleaning_logs.R's pmax() note) - when the
# cleaning team's logs are ahead of the last data pull, Cleaning-log.flagged
# can legitimately exceed Submissions, and that's informative (a real
# refresh-timing signal), not a bug to hide. The RATE stays safely bounded
# regardless, since it's computed inside summarise_cleaning_logs.R against
# its own pmax-protected denominator, not against this merged Submissions
# column - that's the invariant actually worth asserting.
stopifnot(all(partners$Integrity.flag.rate >= 0 & partners$Integrity.flag.rate <= 1, na.rm = TRUE))
stopifnot(all(partners$`Cleaning-log.flag.rate` >= 0 & partners$`Cleaning-log.flag.rate` <= 1, na.rm = TRUE))
cat("Partners totals reconcile with submissions_raw: achieved", sum(partners$Achieved), ", integrity-flagged", sum(partners$Integrity.flagged), "\n")

# ---- Enumerators: same full-roster convention, individual grain -----------
enumerators <- read.xlsx(digest_tmp, sheet = "Enumerators")
cat("Enumerators rows:", nrow(enumerators), "of", dplyr::n_distinct(submissions_raw$enum_id), "enumerators (full roster)\n")
# see the matching >= note in the Partners block above - same union-roster
# reasoning applies at enumerator grain (this is in fact where it was
# caught: si_zam_msna_015 and 32 others exist in the cleaning logs with
# zero rows in submissions_raw so far).
stopifnot(nrow(enumerators) >= dplyr::n_distinct(submissions_raw$enum_id))
stopifnot(sum(enumerators$Submissions) >= nrow(submissions_raw))
stopifnot(sum(enumerators$Achieved) == sum(is_achieved(submissions_raw)))
stopifnot(all(enumerators$`Tier.A.(likely.delete)` <= enumerators$`Cleaning-log.flagged`))
# see the matching note in the Partners block above - not asserting
# Cleaning-log.flagged <= Submissions here for the same reason.
stopifnot(all(enumerators$`Cleaning-log.flag.rate` >= 0 & enumerators$`Cleaning-log.flag.rate` <= 1, na.rm = TRUE))
stopifnot(all(enumerators$Priority %in% c("HIGH", "MEDIUM", "LOW")))
cat("Enumerators totals reconcile with submissions_raw: submissions", sum(enumerators$Submissions), ", achieved", sum(enumerators$Achieved), "\n")

# Tier-A submissions reconcile between the two merged sheets (same
# underlying flags_by_submission_check, grouped two different ways)
cat("Tier-A submissions reconcile enumerator vs partner rollup:", sum(enumerators$`Tier.A.(likely.delete)`), "==", sum(partners$`Tier.A.(likely.delete)`), "\n")
stopifnot(sum(enumerators$`Tier.A.(likely.delete)`) == sum(partners$`Tier.A.(likely.delete)`))

# ---- Oversampled clusters (new 2026-08-20) - achieved > target_households,
# same target the Coverage Map itself uses -----------------------------------
oversampled <- read.xlsx(digest_tmp, sheet = "Oversampled clusters")
cat("Oversampled clusters rows:", nrow(oversampled), ", total surplus:", sum(oversampled$Surplus), "\n")
stopifnot(all(oversampled$Achieved > oversampled$Target.HH))
stopifnot(all(oversampled$Surplus == oversampled$Achieved - oversampled$Target.HH))
stopifnot(all(oversampled$`%.over.target` > 0))

common_errors <- read.xlsx(digest_tmp, sheet = "Common errors")
cat("Common errors: check types =", nrow(common_errors), ", all tier-labelled:", all(grepl("^[ABCD] - ", common_errors$Tier)), "\n")
stopifnot(all(grepl("^[ABCD] - ", common_errors$Tier)))
stopifnot(nrow(common_errors) == dplyr::n_distinct(cleaning_log$detail$`Check type`))

cat("Partner digest cleaning-log/merged-entity sheets regression test passed.\n")

flagged_detail <- read.xlsx(digest_tmp, sheet = "Flagged submissions")
cat("Flagged submissions rows:", nrow(flagged_detail), "of", sum(submissions_raw$any_quality_flag), "expected\n")
stopifnot(nrow(flagged_detail) == sum(submissions_raw$any_quality_flag))
still_present_digest <- intersect(ROW_LEVEL_PII_COLUMNS, names(flagged_detail))
cat("PII columns in digest's flagged-submissions sheet:", if (length(still_present_digest) == 0) "none" else paste(still_present_digest, collapse = ", "), "\n")
stopifnot(length(still_present_digest) == 0)

# ---- Read me (2026-08-20, replaces the old "Summary" sheet) - the
# headline-numbers table now sits partway down the sheet after the
# navigation guide and tier definitions, so search column 1 for the field
# label rather than assuming a fixed row (robust to the guide content
# above it changing length) --------------------------------------------------
readme_sheet <- read.xlsx(digest_tmp, sheet = "Read me", colNames = FALSE)
get_readme_field <- function(field) readme_sheet[which(readme_sheet$X1 == field), "X2"]
not_started_cell <- get_readme_field("Partners with zero submissions so far")
cat("Not-started list excludes the 'other' catch-all:", !grepl("Other / unassigned", not_started_cell), "\n")
stopifnot(!grepl("Other / unassigned", not_started_cell))
stopifnot(length(get_readme_field("Priority follow-up")) > 0) # nav guide row present

# Regression test for a real bug caught 2026-08-18 reviewing the first run:
# the Read me sheet's (then "Summary" sheet's) two "...of which" lines were
# summed across the whole priority table instead of their own preceding
# row's subset, so remove_survey=27 could show a same-scope "still present"
# count of 41 - impossible, since 41 > 27. Each "of which" figure must
# never exceed the total it's a subset of.
get_readme_num <- function(field) as.numeric(gsub(",", "", get_readme_field(field)))
n_tier_a <- get_readme_num("Submissions with a tier-A cleaning-log issue (recommend deletion)")
n_tier_a_achieved <- get_readme_num("...of which still counting toward the achieved total")
n_remove_survey <- get_readme_num("Submissions already marked \"remove_survey\" by the cleaning script")
n_remove_survey_present <- get_readme_num("...of which still present in the dataset")
cat("Read me 'of which' figures stay within their own subset: tier-A", n_tier_a_achieved, "<=", n_tier_a, "| remove_survey", n_remove_survey_present, "<=", n_remove_survey, "\n")
stopifnot(n_tier_a_achieved <= n_tier_a, n_remove_survey_present <= n_remove_survey)

# Read me's oversampling headline reconciles with the actual sheet
n_over_readme <- get_readme_num("Oversampled clusters (achieved > target)")
n_surplus_readme <- get_readme_num("...surplus submissions across those clusters")
cat("Read me oversampling headline reconciles with sheet:", n_over_readme, "==", nrow(oversampled), "|", n_surplus_readme, "==", sum(oversampled$Surplus), "\n")
stopifnot(n_over_readme == nrow(oversampled), n_surplus_readme == sum(oversampled$Surplus))

cat("Partner data quality digest regression test passed.\n")

cat("\n=== mod_home_server ===\n")
testServer(mod_home_server, args = list(), {
  session$flushReact()
  cat("glance rendered ok:", !is.null(output$glance), "\n")
})

cat("\n=== mod_partner_report_server ===\n")
testServer(mod_partner_report_server, args = list(selected_partners = reactive(NULL)), {
  session$setInputs(report_partner = "fact")
  session$flushReact()
  cat("kpi_target:", output$kpi_target, "\n")
  cat("kpi_achieved:", output$kpi_achieved, "\n")
  cat("kpi_pct:", output$kpi_pct, "\n")
  cat("kpi_flagged:", output$kpi_flagged, "\n")
  cat("lga_table rendered ok:", !is.null(output$lga_table), "\n")

  xlsx_tmp <- tempfile(fileext = ".xlsx")
  build_partner_excel("fact", xlsx_tmp)
  cat("excel report written, size:", file.info(xlsx_tmp)$size, "bytes\n")

  pdf_tmp <- tempfile(fileext = ".pdf")
  build_partner_pdf("fact", pdf_tmp)
  cat("pdf report written, size:", file.info(pdf_tmp)$size, "bytes\n")
})

cat("\n=== mod_export_server ===\n")
testServer(mod_export_server, args = list(filtered_subs = reactive(submissions_raw), filtered_stratum = reactive(progress_by_stratum)), {
  session$flushReact()
  cat("preview rendered ok:", !is.null(output$preview), "\n")

  # Regression test (2026-08-16): respondent-identifying fields must never
  # reach the row-level export, even though filtered_subs() itself (fed
  # in above, unmodified) still carries them for other internal uses.
  # Exercises exportable_subs() directly — the actual reactive the
  # module's own CSV/Excel/preview outputs are built from — not a
  # standalone reimplementation, so this catches a regression in the real
  # code path.
  exported <- exportable_subs()
  still_present <- intersect(ROW_LEVEL_PII_COLUMNS, names(exported))
  cat("PII columns remaining in export:", if (length(still_present) == 0) "none" else paste(still_present, collapse = ", "), "\n")
  stopifnot(length(still_present) == 0)
  stopifnot(nrow(exported) == nrow(submissions_raw))

  csv_tmp <- tempfile(fileext = ".csv")
  write_csv(exported, csv_tmp)
  cat("subs csv written, size:", file.info(csv_tmp)$size, "bytes\n")

  xlsx_tmp <- tempfile(fileext = ".xlsx")
  writeData_wrapper(progress_by_stratum, xlsx_tmp, "LGA progress")
  cat("stratum xlsx written, size:", file.info(xlsx_tmp)$size, "bytes\n")
})
cat("Row-level PII exclusion regression test passed — export/preview never carry respondent-identifying fields.\n")

cat("\n=== mod_enumerator_server ===\n")
testServer(mod_enumerator_server, args = list(filtered_subs = reactive(submissions_raw)), {
  session$flushReact()
  cat("kpi_n_enum:", output$kpi_n_enum, "\n")
  cat("kpi_avg_subs:", output$kpi_avg_subs, "\n")
  cat("kpi_max_day:", output$kpi_max_day, "\n")
  cat("kpi_median_flag:", output$kpi_median_flag, "\n")
  cat("scatter rendered ok:", !is.null(output$scatter), "\n")
  cat("top_bar rendered ok:", !is.null(output$top_bar), "\n")
  cat("table rendered ok:", !is.null(output$table), "\n")
  # the module's own observe() populates drill_enum's choices via
  # updateSelectInput once stats() resolves; set it explicitly here too
  # since testServer doesn't always reflect that round-trip immediately
  session$setInputs(drill_enum = compute_enumerator_stats(submissions_raw)$enum_id[1])
  session$flushReact()
  cat("drill_trend rendered ok:", !is.null(output$drill_trend), "\n")
})

cat("\n=== mod_integrity_server ===\n")
testServer(mod_integrity_server, args = list(filtered_subs = reactive(submissions_raw)), {
  session$flushReact()
  cat("kpi_gps_dup:", output$kpi_gps_dup, "\n")
  cat("kpi_off_hours:", output$kpi_off_hours, "\n")
  cat("kpi_whipple:", output$kpi_whipple, "\n")
  cat("kpi_overmax:", output$kpi_overmax, "\n")
  cat("hour_hist rendered ok:", !is.null(output$hour_hist), "\n")
  cat("duration_hist rendered ok:", !is.null(output$duration_hist), "\n")
  cat("age_hist rendered ok:", !is.null(output$age_hist), "\n")
  cat("whipple_by_enum rendered ok:", !is.null(output$whipple_by_enum), "\n")
  cat("gps_dup_table rendered ok:", !is.null(output$gps_dup_table), "\n")
  cat("overmax_table rendered ok:", !is.null(output$overmax_table), "\n")
})
# Tests find_gps_duplicate_groups() itself against a small SYNTHETIC
# fixture with a deliberate GPS-reuse pattern, not whatever submissions_raw
# happens to be — real data has no guaranteed duplicate GPS coincidence,
# so asserting a nonzero count against whichever source is active would
# make this test flaky the moment real data's recovered-GPS subset happens
# to have zero exact coincidences, which isn't a bug. Used to read this
# off mock_submissions.csv (which deliberately injected such a pattern
# across its ~900 rows) — replaced 2026-08-21 when mock data was retired
# (real data has been the only source in practice for weeks; global.R now
# requires real_submissions.csv outright) with the minimal fixture
# actually needed:
# two completed submissions sharing one lat/lon, one that doesn't.
gps_dup_fixture <- tibble(
  interview_outcome = c("completed", "completed", "completed"),
  latitude_submitted = c(11.5, 11.5, 12.1),
  longitude_submitted = c(7.5, 7.5, 8.2),
  enum_id = c("test_enum_001", "test_enum_002", "test_enum_003"),
  admin1 = "Test State", admin2_submitted = "Test LGA",
  submission_date = as.Date("2026-08-01")
)
stopifnot(nrow(find_gps_duplicate_groups(gps_dup_fixture)) == 1) # exactly the 2 matching rows form one group
cat("GPS-duplicate detection confirmed against synthetic fixture.\n")
cat("(find_gps_duplicate_groups() against the currently-loaded data:", nrow(find_gps_duplicate_groups(submissions_raw)), "group(s) — informational, not asserted.)\n")

cat("\n=== mod_representativeness_server ===\n")
testServer(mod_representativeness_server, args = list(filtered_subs = reactive(submissions_raw), filtered_stratum = reactive(progress_by_stratum)), {
  session$flushReact()
  cat("kpi_design_hh:", output$kpi_design_hh, "\n")
  cat("kpi_achieved_hh:", output$kpi_achieved_hh, "\n")
  cat("kpi_resp_female:", output$kpi_resp_female, "\n")
  cat("kpi_hoh_male:", output$kpi_hoh_male, "\n")
  cat("hh_size_hist rendered ok:", !is.null(output$hh_size_hist), "\n")
  cat("setting_bar rendered ok:", !is.null(output$setting_bar), "\n")
  cat("pyramid rendered ok:", !is.null(output$pyramid), "\n")
  cat("hh_size_table rendered ok:", !is.null(output$hh_size_table), "\n")
})

cat("\n=== mutual cross-filter choice functions (direct, no Shiny) ===\n")
# Exercises the same functions app.R's mutual-filter observers call — direct
# calls avoid leaflet-in-testServer flakiness unrelated to the filter logic
# itself; the real Shiny wiring is covered by the live app boot test.
ne_states <- compute_filter_choices("state", list(region = "NE"))
cat("NE states:", paste(ne_states, collapse = ", "), "\n")
stopifnot(length(ne_states) > 0)

ne_lgas <- compute_filter_choices("lga", list(state = ne_states[1]))
cat(ne_states[1], "has", length(ne_lgas), "LGAs\n")
stopifnot(length(ne_lgas) > 0)
stopifnot(all(ne_lgas %in% (strata_frame %>% filter(adm1_name == ne_states[1]) %>% pull(adm2_name))))

ne_wards <- get_ward_choices(ne_lgas[1])
cat(ne_lgas[1], "has", length(ne_wards), "wards\n")

lgas_for_ward <- if (length(ne_wards) > 0) intersect(ne_lgas, ward_to_lga$adm2_name[ward_to_lga$adm3_name %in% ne_wards[1]]) else character(0)
cat("ward '", if (length(ne_wards) > 0) ne_wards[1] else NA, "' narrows to LGA(s): ", paste(lgas_for_ward, collapse = ", "), "\n", sep = "")
stopifnot(length(lgas_for_ward) >= 1)

# partner -> region/state (the explicit example from the request)
fact_states <- compute_filter_choices("state", list(partner = "fact"))
cat("FACT-covered states:", paste(fact_states, collapse = ", "), "\n")
stopifnot(length(fact_states) > 0, length(fact_states) < length(state_choices))
fact_regions <- compute_filter_choices("region", list(partner = "fact"))
stopifnot(length(fact_regions) > 0, length(fact_regions) < length(region_choices))

# poptype -> lga/partner (the "fully mutual" extension)
all_lgas <- compute_filter_choices("lga", list())
idp_lgas <- compute_filter_choices("lga", list(poptype = "idp"))
cat("LGAs with IDP presence:", length(idp_lgas), "of", length(all_lgas), "total\n")
stopifnot(length(idp_lgas) > 0, length(idp_lgas) < length(all_lgas))

# region -> partner (children narrowing a filter above them too, since the
# request was answered "fully mutual")
nc_partners <- compute_filter_choices("partner", list(region = "NC"))
all_partners <- compute_filter_choices("partner", list())
cat("Partners active in NC:", length(nc_partners), "of", length(all_partners), "total\n")
stopifnot(length(nc_partners) > 0, length(nc_partners) <= length(all_partners))

# smart_selection: preserves valid narrowing, falls back to "all" when the
# old selection no longer applies at all
stopifnot(setequal(smart_selection(c("Borno", "Yobe"), c("Borno", "Yobe", "Adamawa")), c("Borno", "Yobe")))
stopifnot(setequal(smart_selection(c("Kebbi"), c("Borno", "Yobe", "Adamawa")), c("Borno", "Yobe", "Adamawa")))

cat("Mutual cross-filter function test passed.\n")

cat("\n=== server-side histogram binning (bin_integer_counts/bin_continuous_counts) ===\n")
# Regression test for the 2026-08-17 "weak internet" performance fix:
# hour/duration/age/household-size histograms used to ship every raw row
# to the browser for plotly to bin client-side — fine at ~900 rows, a
# genuinely avoidable few-MB tax at the full ~31,500. These two helpers
# pre-bin server-side instead; verified here against a manual tally
# (exact bin-by-bin match, not just "didn't error") so a future change to
# either helper or to submissions_raw's shape can't silently drift from
# what a real histogram would have shown.
hours <- hour(submissions_raw$start_datetime)
hour_binned <- bin_integer_counts(hours, 0, 23)
hour_manual <- table(factor(hours, levels = 0:23))
stopifnot(all(hour_binned$n == as.integer(hour_manual)))
stopifnot(sum(hour_binned$n) == sum(!is.na(hours)))
cat("bin_integer_counts (hour): bin-by-bin match against manual tally, total", sum(hour_binned$n), "\n")

ages <- submissions_raw$resp_age
age_binned <- bin_integer_counts(ages, 18, 90)
age_manual <- table(factor(round(ages[!is.na(ages) & ages >= 18 & ages <= 90]), levels = 18:90))
stopifnot(all(age_binned$n == as.integer(age_manual)))
cat("bin_integer_counts (age, has NAs): bin-by-bin match, total", sum(age_binned$n), "of", sum(!is.na(ages)), "non-NA\n")

dur <- submissions_raw$duration_min
dur_binned <- bin_continuous_counts(dur, bins = 40)
stopifnot(sum(dur_binned$n) == sum(!is.na(dur)))
stopifnot(nrow(dur_binned) <= 40)
cat("bin_continuous_counts (duration): total", sum(dur_binned$n), "across", nrow(dur_binned), "bins, matches non-NA count\n")

stopifnot(nrow(bin_continuous_counts(numeric(0))) == 0)
single <- bin_continuous_counts(c(5, 5, 5, NA))
stopifnot(nrow(single) == 1, single$n == 3)
cat("Edge cases (empty input, all-identical input) handled without error.\n")
cat("Histogram binning regression test passed.\n")

cat("\n=== compute_progress_by_stratum is date-range aware ===\n")
full_progress <- compute_progress_by_stratum(submissions_raw)
half_date <- min(submissions_raw$submission_date, na.rm = TRUE) + as.numeric(diff(range(submissions_raw$submission_date, na.rm = TRUE))) %/% 2
early_subs <- submissions_raw %>% filter(submission_date <= half_date)
early_progress <- compute_progress_by_stratum(early_subs)
cat("Full-period total achieved:", sum(full_progress$achieved_n), "\n")
cat("First-half-period total achieved:", sum(early_progress$achieved_n), "\n")
stopifnot(sum(early_progress$achieved_n) < sum(full_progress$achieved_n))
stopifnot(sum(early_progress$achieved_n) > 0)
cat("Date-range awareness test passed.\n")

cat("\n=== filter feedback-loop regression test (app.R server) ===\n")
# Regression test for the "constant refreshing/jumping" bug: the mutual
# cross-filter observers used to call update*Input() unconditionally on
# every invalidation. testServer can't simulate the real client round-trip
# that actually triggered the runaway loop (pickerInput firing a change
# event even on a no-op update), but it CAN confirm the guard logic itself
# is doing its job: monkey-patch update*Input inside app.R's own
# environment (shadowing the shinyWidgets/shiny versions via lexical
# scoping) to count calls, then verify that re-flushing reactives with no
# actual input change produces zero further update calls — i.e. the
# system reaches a fixed point instead of continuing to fire.
app_env <- new.env()
source("app.R", local = app_env)
call_log <- new.env()
call_log$n <- 0
call_log$last_choices <- list()
call_log$last_selected <- list()
app_env$updatePickerInput <- function(session, inputId, choices = NULL, selected = NULL, ...) {
  call_log$n <- call_log$n + 1
  if (!is.null(choices)) call_log$last_choices[[inputId]] <- choices
  if (!is.null(selected)) call_log$last_selected[[inputId]] <- selected
}
app_env$updateCheckboxGroupInput <- function(...) call_log$n <- call_log$n + 1

testServer(app_env$server, {
  # dateRangeInput's UI-declared start/end don't always seem to reliably
  # populate input$f_daterange purely from the UI default inside a long
  # testServer session (unlike the pickerInput/checkboxGroupInput filters,
  # which do) — set it explicitly up front so every filtered_subs()/
  # filtered_stratum() read later in this block has a real 2-element
  # date range to work with, not an empty one.
  session$setInputs(f_daterange = c(FIELDING_START, max(submissions_raw$submission_date, na.rm = TRUE)))
  session$flushReact()
  n_after_init <- call_log$n
  cat("update calls after initial flush:", n_after_init, "\n")

  # flushing again with nothing changed must NOT trigger any more updates
  session$flushReact()
  session$flushReact()
  n_after_idle_flushes <- call_log$n
  cat("update calls after 2 more idle flushes:", n_after_idle_flushes, "\n")
  stopifnot(n_after_idle_flushes == n_after_init)

  # a real change (narrow the region) should trigger a bounded number of
  # updates that settle, not grow without bound on repeated flushing
  session$setInputs(f_region = "NE")
  session$flushReact()
  n_after_change <- call_log$n
  cat("update calls after narrowing region:", n_after_change, "\n")
  stopifnot(n_after_change > n_after_idle_flushes)

  session$flushReact()
  session$flushReact()
  session$flushReact()
  n_after_settle <- call_log$n
  cat("update calls after 3 more flushes (same input):", n_after_settle, "\n")
  stopifnot(n_after_settle == n_after_change)

  # Regression test for the "stuck after picking one Region" lock bug:
  # State must have narrowed to NE's states only (forward cascade still
  # works)...
  state_choices_now <- call_log$last_choices[["f_state"]]
  cat("State choices after narrowing Region to NE:", length(state_choices_now), "of", length(state_choices), "\n")
  stopifnot(length(state_choices_now) > 0, length(state_choices_now) < length(state_choices))

  # ...but Region's OWN choices must NOT have shrunk as a result (this is
  # exactly the lock: State feeding back to narrow Region permanently).
  # Region's choices depend only on poptype/partner now, neither of which
  # changed here, so update*Input("f_region", ...) is never called at all
  # — i.e. NULL below means "never touched, still the full initial set",
  # which is the correct (unlocked) outcome, not a gap in the test.
  region_choices_now <- call_log$last_choices[["f_region"]]
  if (is.null(region_choices_now)) {
    cat("Region's own choices were never re-sent (still the full initial set) — not locked.\n")
  } else {
    cat("Region's own choices after narrowing it to NE:", length(region_choices_now), "of", length(region_choices), "\n")
    stopifnot(length(region_choices_now) == length(region_choices))
  }

  # Regression test for the "doesn't auto-restore" bug: deselecting NW from
  # Region correctly narrows State, but until this fix, re-selecting NW
  # back into Region left State stuck at its narrowed set instead of
  # auto-expanding back to include NW's states again (since nothing had
  # ever directly asked it to). State was never manually touched by the
  # simulated user here — only Region changed — so it should count as
  # "untouched" and auto-follow back to the full set.
  session$setInputs(f_region = unname(region_choices))
  session$flushReact()
  state_choices_restored <- call_log$last_choices[["f_state"]]
  state_selected_restored <- call_log$last_selected[["f_state"]]
  cat("State choices after re-selecting full Region:", length(state_choices_restored), "of", length(state_choices), "\n")
  stopifnot(setequal(state_choices_restored, state_choices))
  stopifnot(setequal(state_selected_restored, state_choices))

  # Regression test for the exact bug reported 2026-08-16: deselecting NW
  # from Region (not narrowing to a single region — the user's own repro
  # removed just one of several) undercounted LGAs and planned target
  # samples on re-adding it back (156 of 156 LGAs / ~27k instead of the
  # full 176 LGAs / ~31.5k). Root cause was Pop.group and Partner being
  # mutually dependent on each other (a cycle, not a chain) rather than a
  # stale sibling read alone — no fixed linear registration order resolves
  # a cycle in one pass, so an iterative multi-round convergence was tried
  # and rejected (it converges to a self-consistent but WRONG fixed point
  # when two untouched, mutually-dependent dimensions keep constraining
  # each other with stale values). Fixed by having untouched dimensions
  # never act as constraints on siblings at all (only ever pass NULL),
  # since only touched dimensions are guaranteed fresh.
  full_lga_choices <- compute_filter_choices("lga", list())
  cat("Full LGA count / total planned interviews:", length(full_lga_choices), "/", comma(TOTAL_PLANNED_INTERVIEWS), "\n")
  # CAPTURED 2026-09-11: the actual pre-narrowing baseline from
  # filtered_stratum() itself, not TOTAL_PLANNED_INTERVIEWS - those are no
  # longer the same number now that Dropped strata exist (see below) and
  # equating them was masking a real, separate finding: the LGA/state
  # picker choice-lists only let a Dropped stratum through when it shares
  # an LGA with a still-covered one, so "select everything" doesn't
  # actually reach every Dropped stratum via the sidebar filters even
  # though compute_progress_by_stratum() itself returns all of them - a
  # real UI-wiring gap, flagged for a follow-up pass through the
  # choice-list-building code, not fixed here. This test's actual job is
  # narrower and still valid regardless: does resetting the region filter
  # restore exactly what you had before narrowing.
  target_full <- sum(filtered_stratum()$target_sample, na.rm = TRUE)
  session$setInputs(f_region = setdiff(unname(region_choices), "NW"))
  session$flushReact()
  lga_choices_no_nw <- call_log$last_choices[["f_lga"]]
  target_no_nw <- sum(filtered_stratum()$target_sample, na.rm = TRUE)
  cat("LGA choices / target with NW removed:", length(lga_choices_no_nw), "/", comma(target_no_nw), "\n")
  stopifnot(length(lga_choices_no_nw) < length(full_lga_choices))
  stopifnot(target_no_nw < TOTAL_PLANNED_INTERVIEWS)

  session$setInputs(f_region = unname(region_choices))
  session$flushReact()
  lga_choices_nw_restored <- call_log$last_choices[["f_lga"]]
  lga_selected_nw_restored <- call_log$last_selected[["f_lga"]]
  target_nw_restored <- sum(filtered_stratum()$target_sample, na.rm = TRUE)
  cat("LGA choices / target with NW re-added:", length(lga_choices_nw_restored), "/", comma(target_nw_restored), "\n")
  stopifnot(setequal(lga_choices_nw_restored, full_lga_choices))
  stopifnot(setequal(lga_selected_nw_restored, full_lga_choices))
  # FIXED 2026-09-11: was == TOTAL_PLANNED_INTERVIEWS - see target_full's
  # own note above for why that stopped being the right comparison.
  stopifnot(target_nw_restored == target_full)

  # Regression test for the "constant resetting" bug (2026-08-15): a direct
  # user click on a filter whose own observer never reads its own input
  # (true of all 5 — Region/State/LGA/Ward/Partner/Pop.group never include
  # their own filter in their dependency list, by design) left
  # filter_ui_state[[key]] stale relative to the live client value. The
  # very next time an unrelated sibling change caused that filter's
  # observer to recompute, sync_filter_input() compared its "should I
  # send" decision against that stale record rather than the live value —
  # so it kept re-sending a value that already matched what the client
  # had, and because update*Input() fires a change event on every call
  # regardless of whether the value changed, that redundant send
  # re-invalidated the whole cross-filter graph, over and over, with
  # nothing ever actually different driving it. Simulates exactly that
  # pattern: manually narrow Partner (a "leaf" the way Region/State/LGA
  # are), then fire several unrelated sibling changes (Pop. group
  # toggling) in a row — call count must stabilize, not keep climbing,
  # and Partner's manual narrowing must survive untouched throughout.
  #
  # last_selected[["f_partner"]] is reset here too, not just call_log$n: an
  # earlier block in this same session (region touched then restored, above)
  # legitimately pushed Partner's full choice set while Partner was still
  # untouched — that's correct behavior, but it leaves a stale prior entry
  # sitting in last_selected. Once Partner is manually narrowed below, this
  # fix's whole point is to NOT re-send it while nothing relevant changes —
  # so last_selected["f_partner"] would otherwise still show that older,
  # pre-touch send and produce a false failure. Clearing it scopes the check
  # to exactly what the test claims to verify: no wrong resend of Partner
  # *after* the touch.
  call_log$n <- 0
  call_log$last_selected[["f_partner"]] <- NULL
  session$setInputs(f_partner = org_id_choices[1:3])
  session$flushReact()
  n_after_partner_touch <- call_log$n
  for (i in 1:4) {
    session$setInputs(f_poptype = if (i %% 2 == 0) unname(pop_type_choices) else unname(pop_type_choices)[1])
    session$flushReact()
  }
  n_after_repeated_siblings <- call_log$n
  session$flushReact()
  session$flushReact()
  n_after_more_idle <- call_log$n
  cat("Calls after partner touch:", n_after_partner_touch, "| after 4 sibling toggles:", n_after_repeated_siblings, "| after 2 more idle flushes:", n_after_more_idle, "\n")
  stopifnot(n_after_more_idle == n_after_repeated_siblings)
  partner_selected_now <- call_log$last_selected[["f_partner"]]
  cat("Partner selection after sibling churn:", length(partner_selected_now), "of", length(org_id_choices[1:3]), "expected\n")
  stopifnot(is.null(partner_selected_now) || setequal(partner_selected_now, org_id_choices[1:3]))
})
cat("Filter feedback-loop regression test passed — converges, does not spin.\n")
cat("Region/State lock regression test passed — narrowing Region doesn't shrink its own choice list.\n")
cat("Filter auto-restore regression test passed — re-widening Region auto-restores State's full selection.\n")
cat("NW region remove/re-add regression test passed — LGA count and planned target samples fully restore (the 2026-08-16 user-reported bug).\n")
cat("Constant-resetting regression test passed — a manually-touched filter stays settled through unrelated sibling churn.\n")

cat("\n=== Coverage Map: real asymmetric-empty edge case (Zuru — non_idp-only target, zero real submissions) ===\n")
# Zuru is a real LGA with a non_idp target but NO idp stratum at all, and
# zero real submissions so far — an asymmetric edge case (one pop type has
# real geometry/target, the other has none whatsoever). Investigated
# 2026-08-15 after this scenario appeared to crash when narrowed to via the
# full multi-module app in one testServer session — traced conclusively to
# a testServer+leafletProxy harness artifact under heavy simultaneous
# multi-module reactive load (confirmed via: the exact data computations
# checked out with no NAs/malformed geometry; a raw leaflet()+addPolygons()
# call on that data succeeded; mod_map_server in ISOLATION with this exact
# real data succeeded fully, including switching to cluster view — only
# co-mounting all 10 modules together in one flush reproduced it). Live
# browser-boot checks against the full, larger unfiltered dataset never hit
# this. Kept as an isolated module-level test (the form that's actually
# reliable here) rather than a full-app one, so this specific data shape
# stays covered without the harness-only false alarm.
zuru_lgas <- "Zuru"
ward_choices_all <- get_ward_choices(compute_filter_choices("lga", list()))
zuru_effective_lgas <- intersect(zuru_lgas, ward_to_lga$adm2_name[ward_to_lga$adm3_name %in% ward_choices_all])
zuru_subs <- submissions_raw %>% filter(admin2_submitted %in% zuru_effective_lgas)
zuru_stratum <- compute_progress_by_stratum(zuru_subs) %>% filter(adm2_name %in% zuru_effective_lgas)
cat("Zuru filtered_stratum rows (expect 1, non_idp only):", nrow(zuru_stratum), "\n")
stopifnot(nrow(zuru_stratum) == 1, zuru_stratum$pop_type == "non_idp")
testServer(mod_map_server, args = list(
  filtered_stratum = reactive(zuru_stratum),
  filtered_subs = reactive(zuru_subs)
), {
  session$flushReact()
  cat("map rendered ok (Zuru, LGA view):", !is.null(output$map), "\n")
  session$setInputs(map_view = "cluster")
  session$flushReact()
  cat("map rendered ok (Zuru, cluster view — non-IDP hexagons present, IDP sites genuinely empty):", !is.null(output$map), "\n")
})
cat("Coverage Map asymmetric-empty-LGA regression test passed.\n")

cat("\n=== Coverage Map redraw is gated on tab visibility (2026-08-16 performance fix) ===\n")
# Regression test for the "filters cause big delays and lags" report:
# profiling found the Coverage Map's leafletProxy layer redraws (~2,500
# hexagons + ~800 sites + boundaries) firing on EVERY filter change
# regardless of which tab the user was actually looking at — a plain
# observe() has no suspendWhenHidden concept the way render*() outputs do,
# so these ran unconditionally. Measured at ~0.2s/layer server-side alone
# (before network transfer + the client's own Leaflet re-render are even
# counted) — a real, substantial, unnecessary cost on every filter click
# made from any OTHER tab. Fixed with map_tab_active (app.R passes
# identical(input$main_nav, "Coverage Map") into mod_map_server, gating
# all 7 filter-driven leafletProxy observers via req(map_tab_active())).
# Verifies both halves: zero leafletProxy calls while hidden, and exactly
# one full redraw the instant the tab becomes visible again.
map_env <- new.env()
source("app.R", local = map_env)
proxy_call_log <- new.env(); proxy_call_log$n <- 0
real_leafletProxy_fn <- leaflet::leafletProxy
# leafletProxy() is called from mod_map.R, which — like every R/*.R file —
# is sourced via global.R's source(f) with the default local = FALSE, so
# it always lands in .GlobalEnv regardless of which environment app.R
# itself was sourced into. Overriding map_env$leafletProxy (mirroring the
# update*Input pattern used elsewhere in this file) would silently miss
# every call mod_map.R makes — this must be a real top-level assignment.
leafletProxy <- function(mapId, ...) { proxy_call_log$n <- proxy_call_log$n + 1; real_leafletProxy_fn(mapId, ...) }
map_env$updatePickerInput <- function(session, inputId, choices = NULL, selected = NULL, ...) {
  shinyWidgets::updatePickerInput(session, inputId, choices = choices, selected = selected, ...)
}
map_env$updateCheckboxGroupInput <- function(session, inputId, choices = NULL, selected = NULL, ...) {
  shiny::updateCheckboxGroupInput(session, inputId, choices = choices, selected = selected, ...)
}
testServer(map_env$server, {
  session$setInputs(f_daterange = c(FIELDING_START, max(submissions_raw$submission_date, na.rm = TRUE)))
  session$setInputs(main_nav = "Home")
  session$flushReact()

  proxy_call_log$n <- 0
  session$setInputs(f_poptype = "non_idp")
  for (i in 1:5) session$flushReact()
  cat("leafletProxy() calls from a filter change while on Home tab (expect 0):", proxy_call_log$n, "\n")
  stopifnot(proxy_call_log$n == 0)

  proxy_call_log$n <- 0
  session$setInputs(main_nav = "Coverage Map")
  for (i in 1:5) session$flushReact()
  cat("leafletProxy() calls when switching TO Coverage Map (expect > 0, one full redraw):", proxy_call_log$n, "\n")
  stopifnot(proxy_call_log$n > 0)

  proxy_call_log$n <- 0
  session$setInputs(f_poptype = unname(pop_type_choices))
  for (i in 1:5) session$flushReact()
  cat("leafletProxy() calls from a filter change WHILE on Coverage Map (expect > 0, normal live update):", proxy_call_log$n, "\n")
  stopifnot(proxy_call_log$n > 0)

  # Regression test for the 2026-08-17 "weak internet" performance review:
  # Ward boundaries / PSU hexagons / PSU sites (all off by default) and
  # the inactive map_view's fill layer used to be computed and sent to
  # every Coverage Map visitor regardless of whether that layer/view was
  # ever actually selected. Both are now gated — reference layers behind
  # layer_shown (set via the layers control's 'overlayadd' JS listener
  # forwarding into input$layer_toggled, simulated here the same way a
  # real toggle would arrive since testServer can't run browser JS), and
  # the inactive view's fill behind input$map_view itself.
  #
  # This testServer call is on the top-level app server (map_env$server),
  # not mod_map_server directly, so the module's own input$layer_toggled
  # must be addressed by its fully-namespaced id ("map-layer_toggled",
  # matching mod_map_server("map", ...) below) — the same fully-qualified
  # name session$ns("layer_toggled") produces inside the module itself,
  # which is what the real browser-side JS actually sends.
  proxy_call_log$n <- 0
  session$flushReact()
  session$flushReact()
  cat("leafletProxy() calls from idle flushes on Coverage Map, no toggle (expect 0):", proxy_call_log$n, "\n")
  stopifnot(proxy_call_log$n == 0)

  session$setInputs(`map-layer_toggled` = "Ward boundaries")
  session$flushReact()
  cat("leafletProxy() calls the first time Ward boundaries is toggled on (expect > 0):", proxy_call_log$n, "\n")
  stopifnot(proxy_call_log$n > 0)

  proxy_call_log$n <- 0
  session$setInputs(`map-map_view` = "cluster")
  session$flushReact()
  cat("leafletProxy() calls the first time 'Coverage by cluster' is selected (expect > 0):", proxy_call_log$n, "\n")
  stopifnot(proxy_call_log$n > 0)
})
cat("Coverage Map visibility-gating regression test passed — zero redraw cost while hidden, normal updates while visible.\n")
cat("Coverage Map lazy-layer regression test passed — off-by-default reference layers and the inactive view are never computed until actually toggled on.\n")

cat("\nALL MODULE TESTS COMPLETED\n")
