# Rebuilt 2026-09-06 alongside full_batch_pipeline.R (see that file's header
# for what changed) - runnable again as of this date, against current data.
#
# STAGE 1 of 2 (2026-09-06 split, per Jack): this stage builds every
# partner's workbook plus a reviewable batch summary (console + CSV) and
# STOPS - it no longer generates email drafts in the same pass. Jack reviews
# the summary and the workbooks first; only once he's given the go-ahead does
# anyone run run_full_batch_emails.R (Stage 2), which drafts emails from
# EXACTLY the package data this stage computed (saved to the .rds below), not
# a fresh recomputation - so what gets emailed can never drift from what was
# actually reviewed, even if the tracker/real_submissions.csv changes in the
# meantime.
#
# CAUTION before running this for real: this writes a FRESH-FROM-SCRATCH
# workbook into every partner's outputs/<ORG>/ folder, using today's date in
# the filename. For a partner whose outputs/ folder already holds a
# carefully consolidated master (reviewer decisions merged in via
# apply_returned_response.R - IMC as of 2026-09-03, check others before
# running) this does NOT overwrite that file (different date in the
# filename) but DOES add a second, undecided workbook alongside it - confirm
# that's actually what's wanted for a given round before running the full
# batch, rather than assuming every partner is starting a from-scratch round.
SCRIPTS_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring/reports/partner_data_recovery/scripts"
source(file.path(SCRIPTS_DIR, "full_batch_pipeline.R"))
source(file.path(SCRIPTS_DIR, "build_workbook_fn.R"))

out_root <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring/reports/partner_data_recovery/outputs"
state_dir <- file.path(out_root, "_batch_state")
dir.create(state_dir, showWarnings = FALSE, recursive = TRUE)

all_partners <- setdiff(names(partner_adm2)[lengths(partner_adm2) > 0], c("other"))
precautionary_partners <- c("street_child", "care", "plan")
cat("Total partners:", length(all_partners), "\n")
cat("Precautionary:", paste(intersect(all_partners, precautionary_partners), collapse=", "), "\n\n")

batch_date <- format(Sys.Date(), "%Y-%m-%d")
summary_rows <- list()
packages <- list()
precautionary_flags <- list()
for (org in all_partners) {
  cat("=== ", org, " ===\n")
  pkg <- tryCatch(build_partner_package(org), error = function(e) { cat("  ERROR building package:", conditionMessage(e), "\n"); NULL })
  if (is.null(pkg)) next

  folder <- file.path(out_root, toupper(org))
  dir.create(folder, showWarnings = FALSE, recursive = TRUE)

  is_precautionary <- org %in% precautionary_partners
  wb_path <- file.path(folder, paste0(toupper(org), "_data_recovery_workbook_", batch_date, ".xlsx"))

  tryCatch({
    build_partner_workbook(pkg, wb_path)
    packages[[org]] <- pkg
    precautionary_flags[[org]] <- is_precautionary
    cat("  OK: collected=", pkg$n_collected_total, " achieved=", pkg$n_achieved_total, "/", pkg$target_sample,
        " gps=", nrow(pkg$gps_sheet), " idp=", nrow(pkg$idp_sheet), " listing=", nrow(pkg$listing_sheet),
        " del=", nrow(pkg$del_sheet), " flagged_enums=", pkg$n_flagged_enums, if(is_precautionary) " [PRECAUTIONARY]" else "", "\n")
    summary_rows[[org]] <- data.frame(org=org, collected=pkg$n_collected_total, achieved=pkg$n_achieved_total,
                                       target=pkg$target_sample, gps=nrow(pkg$gps_sheet), idp=nrow(pkg$idp_sheet),
                                       listing=nrow(pkg$listing_sheet), del=nrow(pkg$del_sheet),
                                       flagged_enums=pkg$n_flagged_enums, precautionary=is_precautionary)
  }, error = function(e) cat("  ERROR building outputs:", conditionMessage(e), "\n"))
}

summary_df <- do.call(rbind, summary_rows)
cat("\n\n=== BATCH SUMMARY ===\n")
print(summary_df, row.names=FALSE)

summary_csv_path <- file.path(out_root, paste0("_batch_review_summary_", batch_date, ".csv"))
write.csv(summary_df, summary_csv_path, row.names = FALSE)

state_path <- file.path(state_dir, paste0("batch_", batch_date, ".rds"))
saveRDS(list(batch_date = batch_date, packages = packages, precautionary = precautionary_flags), state_path)

cat("\nSTAGE 1 DONE - workbooks written, no emails drafted yet.\n")
cat("Review", summary_csv_path, "and each partner's workbook.\n")
cat("When ready to draft emails, run run_full_batch_emails.R (defaults to this batch:", batch_date, ").\n")
