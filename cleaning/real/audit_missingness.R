################################################################################
# audit_missingness.R - percentage_missing computed independently, 2026-09-11
################################################################################
# Reuses the SAME cleaningtools functions the DO's own deletion_log.R uses
# (add_percentage_missing() + check_percentage_missing(), strongness_factor=8
# - a statistical-outlier flag, NOT a literal >80% cutoff, confirmed by
# reading deletion_log.R's own comment at that call site) - run against our
# own read of the raw anonymised export and the DO's kobo tool XLSForm
# (read-only - both already read elsewhere in this repo: prep_real_
# submissions.R reads the same anonymised export; other scripts in reports/
# partner_data_recovery/ already read other files inside cleaning/MSNA_Data_
# Cleaning/ read-only, same house rule - never modify the DO's own pipeline,
# only read its outputs/resources).
#
# Needs the FULL dataset as a stable statistical baseline every run - the
# whole point of a strongness_factor outlier flag is "unusual relative to the
# rest of the sample," which can't be computed from one row in isolation, so
# unlike duration there's no per-row cache to build here.
#
# Usage: Rscript cleaning/real/audit_missingness.R
#    or: source("cleaning/real/audit_missingness.R"); compute_our_missingness()
################################################################################
suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(stringr); library(cleaningtools)
})

MSNA_ANON_DIR   <- "cleaning/MSNA_Data_Cleaning/output/anonymised_data"
KOBO_TOOL_PATH  <- "cleaning/MSNA_Data_Cleaning/kobo_tool/NGA2605_MSNA_Kobo_10082026.xlsx"
MISSINGNESS_STRONGNESS_FACTOR <- 8 # matches deletion_log.R's own value exactly

# Same latest-file-by-mtime resolution as prep_real_submissions.R's own
# anon_files block (kept separate rather than sourcing that script just for
# this helper - it's 6 lines and this stays a standalone-runnable script).
latest_anon_file <- function(dir = MSNA_ANON_DIR) {
  anon_files <- list.files(dir, pattern = "\\.xlsx$", full.names = TRUE)
  stopifnot(length(anon_files) > 0)
  anon_dates <- as.Date(str_extract(basename(anon_files), "\\d{4}-\\d{2}-\\d{2}"))
  same_day <- anon_files[anon_dates == max(anon_dates)]
  same_day[which.max(file.info(same_day)$mtime)]
}

# Returns one row per uuid with our own independently-computed
# percentage_missing AND whether check_percentage_missing() (strongness_factor
# 8, same as the DO's) flags it as a statistical outlier - callers filter on
# is_outlier themselves rather than this file owning the deletion-reason
# registration (matches independent_deletion_checks.R's own separation of
# "compute" from "register" used for duration).
compute_our_missingness <- function(verbose = TRUE) {
  latest_file <- latest_anon_file()
  if (verbose) cat("compute_our_missingness(): using anonymised export", basename(latest_file), "\n")

  main <- read_excel(latest_file, sheet = "main", guess_max = 5000)
  kobo_survey <- read_excel(KOBO_TOOL_PATH, sheet = "survey")

  with_pct <- main %>%
    cleaningtools::add_percentage_missing(
      kobo_survey = kobo_survey,
      type_to_include = c("integer", "select_one", "select_multiple")
    )
  stopifnot("percentage_missing" %in% colnames(with_pct))

  pct_log <- (list(checked_dataset = with_pct) %>%
    cleaningtools::check_percentage_missing(
      uuid_column = "uuid", column_to_check = "percentage_missing",
      strongness_factor = MISSINGNESS_STRONGNESS_FACTOR, log_name = "percentage_missing_log"
    ))$percentage_missing_log

  flagged_uuids <- if (!is.null(pct_log) && nrow(pct_log) > 0) as.character(pct_log$uuid) else character(0)

  out <- with_pct %>%
    transmute(
      uuid = as.character(uuid),
      percentage_missing = as.numeric(percentage_missing),
      is_outlier = uuid %in% flagged_uuids
    )
  if (verbose) {
    cat(sprintf("compute_our_missingness(): %d row(s) scored, %d flagged as a statistical outlier (strongness_factor=%d).\n",
                nrow(out), sum(out$is_outlier), MISSINGNESS_STRONGNESS_FACTOR))
  }
  out
}

if (sys.nframe() == 0) {
  compute_our_missingness()
}
