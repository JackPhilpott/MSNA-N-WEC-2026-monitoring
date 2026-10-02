# run_round1_checks_only.R - 2026-10-01, Round 1 recovery closeout, step 1.
#
# The data side of deploy_dashboard.R (snapshot -> the 7 independent checks in
# priority order -> overlays -> refresh_deletion_columns -> restore) WITHOUT
# re-running prep_real_submissions.R and WITHOUT any report/bundle/deploy step.
#
# Why no prep: data/real_submissions.csv is already exactly the frozen Round 1
# set (28,046 rows, data/ROUND1_MEMBERSHIP.csv). Re-running prep would re-read
# whatever export is newest on disk - fine today, but if a Round 2 export
# landed mid-closeout it would silently pull Round 2 rows into the Round 1
# checks. The guard below refuses to run unless real_submissions.csv still
# matches the frozen Round 1 md5.
#
# Needed because the 1 Oct deploy ran the checks against 27,957 rows; the
# extra 89 rows Jack has since confirmed as Round 1 have never been checked.
#
# Run from the 2_monitoring repo root:
#   Rscript _working_files/scripts/run_round1_checks_only.R
suppressPackageStartupMessages({ library(dplyr); library(readr) })

ROUND1_MD5 <- "2cf1c9594a71670ada54b8a772432005"
actual <- unname(tools::md5sum("data/real_submissions.csv"))
if (!identical(actual, ROUND1_MD5)) {
  stop("real_submissions.csv md5 is ", actual, ", not the frozen Round 1 md5 ", ROUND1_MD5,
       " - refusing to run the Round 1 checks against a different dataset.")
}
cat("Guard OK: real_submissions.csv matches the frozen Round 1 md5.\n\n")

source("reports/partner_data_recovery/scripts/issue_tracker.R")
open_before <- read_tracker() %>% filter(!status %in% TERMINAL_STATUSES)
cat(sprintf("Tracker before: %d rows, %d open.\n\n", nrow(read_tracker()), nrow(open_before)))

source("cleaning/real/preserve_duplicate_history.R")
snapshot_duplicate_history()

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
cat(sprintf("\nTracker after: %d rows, %d open (was %d).\n", nrow(tr), nrow(open_after), nrow(open_before)))
cat("\nOpen items by issue_type / deletion_reason:\n")
print(as.data.frame(open_after %>% count(issue_type, deletion_reason, sort = TRUE)), row.names = FALSE)
cat("\nchecks-only run DONE\n")
