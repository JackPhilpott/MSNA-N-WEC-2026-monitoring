# run_round1_reprep_and_checks.R - 2026-10-01, Round 1 recovery closeout.
#
# ONE-OFF, KEPT FOR THE RECORD - never part of a routine run. 2026-10-04 (Jack: "show all data collected, the
# concept of Round 1 is very much an internal mechanism"): routine refreshes ingest every new export through
# run_refresh_and_deploy.R / deploy_dashboard.R, which have no Round 1 pin. Guard A below now fails by design (a
# later export exists, and the 1 Oct file was re-saved 4 bytes smaller on 3 Oct). Guard B's invariant - no Round 1
# submission ever disappears - lives on in validity_checks/modules/three_way_reconciliation.R.
#
# Re-runs prep_real_submissions.R against the RESTORED v14 frame mirror (a
# OneDrive sync conflict had silently reverted the live frame to its 30 Sep
# 01:38 version, missing 2,412 rows of 30 Sep top-ups; Coordinator restored
# it 1 Oct 23:37 and both mirrors were re-synced and md5-verified), then the
# data side of deploy_dashboard.R: snapshot -> prep -> the 7 independent
# checks in priority order -> overlays -> refresh_deletion_columns ->
# restore_duplicate_history. No report, bundle or deploy step.
#
# Two guards keep this strictly Round 1:
#   A. before prep: the newest anonymised export on disk must still be the
#      Round 1 file (prep always reads the newest one).
#   B. after prep: data/real_submissions.csv must contain EXACTLY the uuid set
#      in data/ROUND1_MEMBERSHIP.csv. The file md5 is NOT the invariant -
#      deletion-status columns legitimately change every run - the uuid set is.
# If B fails, stop: restore data/ from data/_archive/<date>_pre_round1_reprep_
# restored_frame/ before doing anything else.
#
# Run from the 2_monitoring repo root:
#   Rscript _working_files/scripts/run_round1_reprep_and_checks.R
suppressPackageStartupMessages({ library(dplyr); library(readr); library(stringr) })

ROUND1_EXPORT <- "NGA2605_MSNA_anonymised_2026-10-01.xlsx"
ROUND1_EXPORT_SIZE <- 169961268

# ---- guard A ----------------------------------------------------------------
exports <- list.files("cleaning/MSNA_Data_Cleaning/output/anonymised_data", pattern = "^NGA2605_MSNA_anonymised_\\d{4}-\\d{2}-\\d{2}\\.xlsx$")
newest <- exports[which.max(as.Date(str_extract(exports, "\\d{4}-\\d{2}-\\d{2}")))]
newest_size <- file.size(file.path("cleaning/MSNA_Data_Cleaning/output/anonymised_data", newest))
if (newest != ROUND1_EXPORT || newest_size != ROUND1_EXPORT_SIZE) {
  stop("Guard A failed: newest export is ", newest, " (", newest_size, " bytes), not the Round 1 export ",
       ROUND1_EXPORT, " (", ROUND1_EXPORT_SIZE, " bytes). A Round 2 export may have landed - not re-prepping.")
}
cat("Guard A OK: newest export is still the Round 1 file.\n\n")

source("reports/partner_data_recovery/scripts/issue_tracker.R")
cat(sprintf("Tracker before: %d rows, %d open.\n\n", nrow(read_tracker()),
            sum(!read_tracker()$status %in% TERMINAL_STATUSES)))

source("cleaning/real/preserve_duplicate_history.R")
snapshot_duplicate_history()

source("cleaning/real/prep_real_submissions.R")

# ---- guard B ----------------------------------------------------------------
members <- read_csv("data/ROUND1_MEMBERSHIP.csv", show_col_types = FALSE, col_types = cols(.default = "c"))$submission_uuid
now_uuids <- read_csv("data/real_submissions.csv", show_col_types = FALSE, col_select = "submission_uuid",
                      col_types = cols(.default = "c"))$submission_uuid
extra <- setdiff(now_uuids, members); missing <- setdiff(members, now_uuids)
if (length(extra) > 0 || length(missing) > 0 || length(now_uuids) != length(members)) {
  stop("Guard B failed: real_submissions.csv is no longer exactly Round 1 - ", length(extra), " extra uuid(s), ",
       length(missing), " missing, ", length(now_uuids), " rows vs ", length(members),
       ". STOP and restore data/ from the pre-reprep archive before anything else.")
}
cat(sprintf("\nGuard B OK: real_submissions.csv is exactly the %d Round 1 uuids.\n\n", length(members)))

source("cleaning/real/independent_deletion_checks.R")
cat("\n--- no_consent ---\n");          run_independent_no_consent_check()
cat("\n--- duration_under_20 ---\n");   run_independent_duration_check()
cat("\n--- duplicate_point ---\n");     run_independent_duplicate_check()
cat("\n--- missing_hh_listing ---\n");  run_independent_listing_missing_check()
cat("\n--- pct_missing_flagged ---\n"); run_independent_percentage_missing_check()
cat("\n--- date_outlier ---\n");        run_independent_date_outlier_check()
cat("\n--- crs_unmatched ---\n");       run_independent_unmatched_check()

cat("\n")
source("cleaning/real/build_confirmed_deletions_overlay.R")
source("cleaning/real/refresh_deletion_columns.R")
refresh_deletion_columns()
restore_duplicate_history()

tr <- read_tracker()
open_after <- tr %>% filter(!status %in% TERMINAL_STATUSES)
cat(sprintf("\nTracker after: %d rows, %d open.\n", nrow(tr), nrow(open_after)))
cat("\nOpen items by issue_type / deletion_reason:\n")
print(as.data.frame(open_after %>% count(issue_type, deletion_reason, sort = TRUE)), row.names = FALSE)
cat("\nreprep + checks DONE\n")
