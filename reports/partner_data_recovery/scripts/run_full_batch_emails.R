# STAGE 2 of 2 (2026-09-06, per Jack): run this only after reviewing Stage
# 1's output (run_full_batch.R - the workbooks plus
# outputs/_batch_review_summary_<date>.csv) and deciding the batch is ready
# to go out. Drafts one email per partner from EXACTLY the package data
# Stage 1 computed and saved (outputs/_batch_state/batch_<date>.rds) - not a
# fresh rebuild - so the numbers in the email can never drift from what's
# actually in the reviewed workbook, even if the tracker or
# real_submissions.csv has changed since Stage 1 ran (e.g. a new deletion-log
# batch registered in between).
#
# batch_date defaults to the most recently written batch_<date>.rds file
# (ISO dates sort correctly as strings) - pass one explicitly as the first
# CLI arg (Rscript run_full_batch_emails.R 2026-09-06) to target an older
# batch instead.
#
# UPDATED 2026-09-23, per Jack: this is now the second email round (the
# first, and only prior, round was drafted 2026-08-30 - the workbook itself
# has been regenerated several times since via run_full_batch.R, but no
# corresponding email round went out until now). EMAIL_DEADLINE and
# SECOND_ROUND are passed explicitly into build_partner_email_html() below
# rather than left to that function's own defaults - the previous version
# of this script relied on the default deadline ("4 September 2026") and it
# silently went stale for every batch after the first, since nothing here
# ever passed a fresh one. Bump EMAIL_DEADLINE by hand for the next round.
EMAIL_DEADLINE <- "28 September 2026"
SECOND_ROUND <- TRUE
FIRST_EMAIL_DATE <- "30 August 2026"

SCRIPTS_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring/reports/partner_data_recovery/scripts"
source(file.path(SCRIPTS_DIR, "build_email_fn.R"))

out_root <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring/reports/partner_data_recovery/outputs"
state_dir <- file.path(out_root, "_batch_state")

args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1) {
  batch_date <- args[1]
  state_path <- file.path(state_dir, paste0("batch_", batch_date, ".rds"))
  if (!file.exists(state_path)) stop("run_full_batch_emails(): no saved batch state for ", batch_date, " at ", state_path)
} else {
  state_files <- list.files(state_dir, pattern = "^batch_\\d{4}-\\d{2}-\\d{2}\\.rds$", full.names = TRUE)
  if (length(state_files) == 0) stop("run_full_batch_emails(): no saved batch state found in ", state_dir, " - run run_full_batch.R (Stage 1) first.")
  state_path <- sort(state_files, decreasing = TRUE)[1]
}

state <- readRDS(state_path)
batch_date <- state$batch_date
cat("Drafting emails for batch", batch_date, "(", length(state$packages), "partner package(s) )\n\n")

for (org in names(state$packages)) {
  pkg <- state$packages[[org]]
  is_precautionary <- isTRUE(state$precautionary[[org]])

  folder <- file.path(out_root, toupper(org))
  dir.create(folder, showWarnings = FALSE, recursive = TRUE)
  email_path <- file.path(folder, paste0(toupper(org), "_email_draft_", batch_date, ".html"))
  old_txt_path <- file.path(folder, paste0(toupper(org), "_email_draft_", batch_date, ".txt"))
  if (file.exists(old_txt_path)) unlink(old_txt_path) # superseded by the .html draft (real bold headers)

  tryCatch({
    email_html <- build_partner_email_html(pkg, precautionary = is_precautionary, deadline = EMAIL_DEADLINE,
                                            second_round = SECOND_ROUND, first_email_date = FIRST_EMAIL_DATE)
    writeLines(email_html, email_path, useBytes = TRUE)
    cat("  OK:", org, "->", email_path, if (is_precautionary) "[PRECAUTIONARY]" else "", "\n")
  }, error = function(e) cat("  ERROR drafting email for", org, ":", conditionMessage(e), "\n"))
}

cat("\nSTAGE 2 DONE - email drafts written for batch", batch_date, "\n")
