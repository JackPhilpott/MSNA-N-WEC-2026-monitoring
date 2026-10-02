# Round 1 closeout - READ-ONLY fallback preview on the restored v14 frame and the post-step-2 tracker.
# Writes the per-issue preview to reports/partner_data_recovery/outputs/_round1_closeout/ for the Q3 review.
suppressPackageStartupMessages({ library(dplyr); library(readr) })
source("reports/partner_data_recovery/scripts/issue_tracker.R")
source("reports/partner_data_recovery/scripts/fallback_resolvers.R")
res <- preview_fallback_sweep()
dir.create("reports/partner_data_recovery/outputs/_round1_closeout", showWarnings = FALSE, recursive = TRUE)
write_csv(res, "reports/partner_data_recovery/outputs/_round1_closeout/round1_fallback_preview.csv", na = "")
cat("\nwrote reports/partner_data_recovery/outputs/_round1_closeout/round1_fallback_preview.csv\n")
