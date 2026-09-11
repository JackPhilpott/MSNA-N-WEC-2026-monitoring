# ==============================================================================
# bundle_dashboard_mirrors() - copies data/ and input_data/ INTO
# dashboard_app/data/ and dashboard_app/input_data/ (shinyapps.io only
# bundles the app directory itself, so the app's DATA_DIR/INPUT_DIR fallback
# reads from these bundled copies once actually deployed).
#
# Extracted 2026-09-08 from deploy_dashboard.R, where this was previously
# only ever a side effect of a FULL deploy (refresh + sanity checks + digest
# + actual shinyapps.io push). Found live during this rebuild: the
# sampling_frame mirror was 3 versions stale (dashboard_app/input_data/ still
# had only v5 files while the canonical copies had moved to v6) because
# nothing had triggered a full deploy since - exactly 2-monitoring-ba's own
# suggestion from the incident review (make this mirror refresh independent
# of a full deploy, since more than one thing depends on it being fresh).
#
# This function is ONLY the safe, deterministic file-copy part - it does NOT
# refresh submissions, run sanity checks, regenerate the digest, or push
# anything to shinyapps.io. Safe to call automatically (assert_fresh mode=
# "auto") for local testing/verification. deploy_dashboard.R still calls
# this as one step in its full sequence for a real deploy - refactored to
# call it, not duplicated.
#
# 2026-09-09 (Jack, live crash): this used to copy input_data/ wholesale,
# including every `_archive_*` snapshot folder that the various sync
# scripts leave behind under input_data/sampling_frame/ and
# input_data/accessibility/ (their own "archive stale mirror before
# overwrite" convention, correct for the source repo, but never meant to
# be shipped). global.R's loaders are non-recursive/specific-pattern and
# never read these - they're pure audit trail. Nothing excluded them from
# the deploy bundle, which grew to 618MB (mostly archives, ~525MB) after
# the 2026-09-08 v7 propagation added its own 135MB archive on top -
# shinyapps.io's worker failed to start under that bundle weight, 503 for
# everyone. Fixed once to skip top-level "_archive*" entries only - wrong,
# the archive folders actually live one level down (input_data/sampling_frame/
# _archive_.../, input_data/accessibility/_archive_.../), so that first fix
# still shipped 646MB on the very next deploy. Now walks and copies files
# individually, skipping any path component starting with "_archive" at any
# depth.
# ==============================================================================
bundle_dashboard_mirrors <- function(project_dir = ".") {
  old_wd <- getwd()
  setwd(project_dir)
  on.exit(setwd(old_wd))

  for (d in c("dashboard_app/data", "dashboard_app/input_data")) {
    if (dir.exists(d)) unlink(d, recursive = TRUE)
  }
  dir.create("dashboard_app/data")
  dir.create("dashboard_app/input_data")

  copy_excluding_archives <- function(src_dir, dest_dir) {
    all_files <- list.files(src_dir, recursive = TRUE, full.names = FALSE)
    keep <- all_files[!grepl("(^|/)_archive[^/]*(/|$)", all_files)]
    for (f in keep) {
      dest_file <- file.path(dest_dir, f)
      dir.create(dirname(dest_file), recursive = TRUE, showWarnings = FALSE)
      file.copy(file.path(src_dir, f), dest_file)
    }
  }
  copy_excluding_archives("data", "dashboard_app/data")
  copy_excluding_archives("input_data", "dashboard_app/input_data")

  data_mb <- sum(file.info(list.files("dashboard_app/data", recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE) %/% 1e6
  input_mb <- sum(file.info(list.files("dashboard_app/input_data", recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE) %/% 1e6
  cat("bundle_dashboard_mirrors(): bundled data/ (", data_mb, "MB) and input_data/ (", input_mb, "MB) into dashboard_app/\n", sep = "")
  invisible(TRUE)
}

if (sys.nframe() == 0) {
  bundle_dashboard_mirrors(project_dir = if (basename(getwd()) == "shared") "../.." else ".")
}
