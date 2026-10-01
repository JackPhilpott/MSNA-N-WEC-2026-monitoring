suppressPackageStartupMessages({library(dplyr); library(readr)})
setwd("c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring")
source("reports/partner_data_recovery/scripts/issue_tracker.R")
source("reports/partner_data_recovery/scripts/fallback_resolvers.R")

TRACKER_PATH <- normalizePath("_working_files/scratch_fallback_test/scratch_tracker.csv")
apply_fallback_sweep(confirm = TRUE, log_dir = "_working_files/scratch_fallback_test/_log")

out <- build_do_deletion_log(out_path = "_working_files/scratch_fallback_test/deletion_log_TEST.csv")

cat("\n--- resolution_path totals ---\n")
print(as.data.frame(out %>% count(resolution_path, sort = TRUE)), row.names = FALSE)

cat("\n--- one example row of each resolution_path ---\n")
for (rp in unique(out$resolution_path)) {
  ex <- out[out$resolution_path == rp, ][1, c("issue_id","issue_type","deletion_reason","status","resolution_path","fallback_resolution")]
  print(as.data.frame(ex), row.names = FALSE)
}

# identity check: every open row should be accounted for exactly once, no drops
tracker <- read_tracker()
stopifnot(nrow(out) == nrow(tracker))
cat("\nOK: row count matches tracker exactly (", nrow(out), " rows), no drops.\n")
