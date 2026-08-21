# Acknowledges and clears data/SANITY_WARNINGS.txt (see
# cleaning/real/sanity_checks.R for what writes it and why). Run this only
# once you've actually reviewed the warning(s) and decided they're either
# fixed, or not a real problem — prep_real_submissions.R, generate_fact_
# digest.R, and deploy_dashboard.R will keep re-printing them every single
# run until this file is gone, deliberately, so nothing gets missed.
#
# Run from this file's location (2_monitoring/ project root):
#   source("clear_sanity_warnings.R")

f <- "data/SANITY_WARNINGS.txt"
if (file.exists(f)) {
  cat("Clearing", f, "— contents were:\n\n")
  cat(readLines(f), sep = "\n")
  file.remove(f)
  cat("\n\nCleared. Acknowledged as of", format(Sys.time(), "%d %b %Y %H:%M"), "\n")
} else {
  cat("No active sanity warnings to clear.\n")
}
