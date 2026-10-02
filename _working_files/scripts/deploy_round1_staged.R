# deploy_round1_staged.R - 2026-10-02, the post-closeout Round 1 deploy, staged (Jack's overnight yes: "start the app
# locally first, deploy only if it starts cleanly").
#
# Runs deploy_dashboard.R end to end - mirror sync, PSU geometries, re-prep, checks, overlays, digest, bundle - with
# deployApp() stubbed, so everything is built and bundled but nothing goes live. The local start check and the real
# deployApp() call are separate steps after this. Two guards keep it strictly Round 1:
#   A. before: the newest anonymised export on disk must still be the Round 1 file (prep reads the newest one);
#   B. after: data/real_submissions.csv must hold exactly the uuid set in data/ROUND1_MEMBERSHIP.csv.
#
# Run from the 2_monitoring repo root:
#   Rscript _working_files/scripts/deploy_round1_staged.R
suppressPackageStartupMessages({ library(readr); library(stringr) })

ROUND1_EXPORT <- "NGA2605_MSNA_anonymised_2026-10-01.xlsx"
ROUND1_EXPORT_SIZE <- 169961268
exports <- list.files("cleaning/MSNA_Data_Cleaning/output/anonymised_data", pattern = "^NGA2605_MSNA_anonymised_\\d{4}-\\d{2}-\\d{2}\\.xlsx$")
newest <- exports[which.max(as.Date(str_extract(exports, "\\d{4}-\\d{2}-\\d{2}")))]
if (newest != ROUND1_EXPORT || file.size(file.path("cleaning/MSNA_Data_Cleaning/output/anonymised_data", newest)) != ROUND1_EXPORT_SIZE) {
  stop("Guard A failed: newest export is ", newest, ", not the Round 1 export - a Round 2 export may have landed. Not deploying.")
}
cat("Guard A OK: newest export is still the Round 1 file.\n\n")

deployApp <- function(...) cat("\n[staged] deployApp() skipped - bundle built, waiting for the local start check.\n")
source("deploy_dashboard.R")

members <- read_csv("data/ROUND1_MEMBERSHIP.csv", show_col_types = FALSE, col_types = cols(.default = "c"))$submission_uuid
now <- read_csv("data/real_submissions.csv", show_col_types = FALSE, col_select = "submission_uuid", col_types = cols(.default = "c"))$submission_uuid
if (!setequal(now, members) || length(now) != length(members)) {
  stop("Guard B failed: real_submissions.csv is not exactly the Round 1 uuid set (", length(now), " rows). Do NOT deploy.")
}
cat(sprintf("\nGuard B OK: real_submissions.csv is exactly the %d Round 1 uuids.\n", length(members)))
cat("real_submissions md5:", unname(tools::md5sum("data/real_submissions.csv")),
    "| bundled copy md5:", unname(tools::md5sum("dashboard_app/data/real_submissions.csv")), "\n")
cat("staged deploy DONE\n")
