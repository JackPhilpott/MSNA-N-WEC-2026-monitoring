# Round 1 closeout - after the tracker changes: rebuild both deletion overlays and re-sync real_submissions.csv's
# deletion columns from them (the same three steps deploy_dashboard.R runs after the independent checks), with the
# is_duplicate history snapshot/restore around it. No prep, no checks, no report, no deploy.
suppressPackageStartupMessages({ library(dplyr); library(readr) })
source("reports/partner_data_recovery/scripts/issue_tracker.R")
source("cleaning/real/preserve_duplicate_history.R")
snapshot_duplicate_history()
source("cleaning/real/build_confirmed_deletions_overlay.R")
source("cleaning/real/refresh_deletion_columns.R")
refresh_deletion_columns()
restore_duplicate_history()
cat("overlays rebuilt and deletion columns refreshed\n")
