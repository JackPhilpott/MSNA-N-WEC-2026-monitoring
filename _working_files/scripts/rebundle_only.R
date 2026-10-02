# Re-run only the data/ + input_data/ -> dashboard_app/ mirror copy (2026-10-02): used after moving the raw GPS
# extract out of data/, so the redeploy bundle no longer carries it. No prep, no checks.
#   Rscript _working_files/scripts/rebundle_only.R
source("scripts/shared/bundle_dashboard_mirrors.R")
bundle_dashboard_mirrors(".")
left <- list.files("dashboard_app", pattern = "raw_gps", recursive = TRUE)
if (length(left)) stop("raw GPS file(s) still in dashboard_app/: ", paste(left, collapse = ", "))
cat("no raw GPS file in dashboard_app/ | real_submissions md5:", unname(tools::md5sum("dashboard_app/data/real_submissions.csv")), "\n")
