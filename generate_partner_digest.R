# Generates the partner data quality digest — a standalone workbook for
# IMPACT's own internal review first (renamed from "...for_FACT"
# 2026-08-21d: what, if anything, gets shared onward with FACT — a close
# field partner, not the primary audience — or disseminated further is a
# decision made after reviewing this, not assumed by the report's name).
# NOT a dashboard feature.
#
# Integrated into deploy_dashboard.R 2026-08-21d, which now sources this
# file as its first step — the report and the dashboard are both
# downstream of the same daily data refresh and are meant to update
# together, not as two separate things to remember. This file still works
# perfectly well as its own standalone entry point too (e.g. to regenerate
# just the report, without redeploying):
#
#   source("generate_partner_digest.R")
#
# Same cadence as the dashboard's own data refresh either way: re-running
# cleaning/real/prep_real_submissions.R first (as usual) covers the
# dashboard-flag half of the digest; the cleaning-log half reads straight
# from cleaning/MSNA_Data_Cleaning/output/checking/ so it always reflects
# whatever cleaning logs exist on disk at run time — nothing extra to
# refresh for that either.
#
# Run from this file's location (2_monitoring/ project root).
#
# Writes to reports/ (gitignored, like data/ and input_data/ — this is a
# generated artifact you hand off directly, not something to track in git).

source("cleaning/real/sanity_checks.R")
print_sanity_banner_if_present() # re-announce any unacknowledged input-data warning — see that file's header

setwd("dashboard_app")
source("global.R")
setwd("..")
source("cleaning/real/summarise_cleaning_logs.R")

dir.create("reports", showWarnings = FALSE)
out_file <- file.path("reports", paste0("MSNA_2026_partner_digest_", Sys.Date(), ".xlsx"))
cleaning_log <- summarise_cleaning_logs()
build_partner_quality_digest_excel(out_file, cleaning_log)

cat("Written:", normalizePath(out_file), "\n")
cat("Built from:", submissions_meta$source_file, "(pulled", format(submissions_meta$generated_at, "%d %b %Y %H:%M"), ")\n")
cat("Cleaning logs covered:", format(min(cleaning_log$dates_covered), "%d %b"), "to", format(max(cleaning_log$dates_covered), "%d %b"), "\n")
