# Generates the partner data quality digest for FACT — a standalone
# workbook you send them directly (email/Teams), NOT a dashboard feature.
# Meant to be re-run daily, same cadence as the dashboard's own data
# refresh: the digest is built entirely from data/real_submissions.csv,
# so re-running cleaning/real/prep_real_submissions.R first (as usual)
# is the only "refresh" step — nothing extra to maintain here.
#
# Run from this file's location (2_monitoring/ project root):
#   source("generate_fact_digest.R")
#
# Writes to reports/ (gitignored, like data/ and input_data/ — this is a
# generated artifact you hand off directly, not something to track in git).

setwd("dashboard_app")
source("global.R")
setwd("..")

dir.create("reports", showWarnings = FALSE)
out_file <- file.path("reports", paste0("MSNA_2026_partner_digest_for_FACT_", Sys.Date(), ".xlsx"))
build_fact_quality_digest_excel(out_file)

cat("Written:", normalizePath(out_file), "\n")
cat("Built from:", mock_meta$source_file, "(pulled", format(mock_meta$generated_at, "%d %b %Y %H:%M"), ")\n")
if (IS_MOCK_DATA) cat("WARNING: this ran against MOCK data, not real submissions — check data/real_submissions.csv exists.\n")
