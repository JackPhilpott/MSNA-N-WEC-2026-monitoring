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
# including every `_archive_*` snapshot folder - a 618MB bundle shinyapps.io's
# worker couldn't start under. Archive folders at any depth are still skipped.
#
# 2026-10-02 (Jack, "agreed on the allowlist file"): copies ONLY the files the
# app reads, listed in scripts/shared/dashboard_bundle_allowlist.txt - no longer
# everything in data/ and input_data/. Bundle 12636193 shipped a raw
# household-GPS extract that happened to sit in data/; with an allowlist a new
# file only ships once it is deliberately added there. Also fixed: the old copy
# never overwrote (file.copy's default) and its unlink() could leave files
# behind (an undeletable empty _archive_2026-08-31 folder blocks removing
# dashboard_app/data itself), so a stale file could in principle survive into
# a bundle. Now every file is deleted individually, every copy overwrites, and
# check_dashboard_bundle() then proves the result: everything rsconnect would
# upload is allowlisted, and every bundled data file is byte-identical to its
# source. deploy_dashboard.R runs that check again right before deployApp().
# ==============================================================================
DASHBOARD_BUNDLE_ALLOWLIST <- "scripts/shared/dashboard_bundle_allowlist.txt"
.ARCHIVE_PATH <- "(^|/)_archive[^/]*(/|$)"

read_bundle_allowlist <- function(path = DASHBOARD_BUNDLE_ALLOWLIST) {
  x <- trimws(readLines(path, warn = FALSE))
  x[nzchar(x) & !startsWith(x, "#")]
}

bundle_path_allowed <- function(paths, allow = read_bundle_allowlist()) {
  vapply(paths, function(p) any(vapply(allow, function(re) grepl(re, p), logical(1))), logical(1), USE.NAMES = FALSE)
}

# Keep only the highest frame version of each family (e.g. ..._stage2_sampling_frame_v14_FULL.csv) - the app reads
# the latest one only (latest_frame_file()), so older versions would just be dead weight in the bundle.
.latest_frame_versions_only <- function(paths) {
  m <- regmatches(paths, regexec("^(.*_sampling_frame_v)([0-9]+)(_[A-Z]+\\.csv)$", paths))
  is_frame <- lengths(m) == 4
  if (!any(is_frame)) return(paths)
  fam <- vapply(m[is_frame], function(x) paste0(x[2], "#", x[4]), character(1))
  ver <- vapply(m[is_frame], function(x) as.integer(x[3]), integer(1))
  keep_frame <- ver == ave(ver, fam, FUN = max)
  c(paths[!is_frame], paths[is_frame][keep_frame])
}

bundle_dashboard_mirrors <- function(project_dir = ".") {
  old_wd <- getwd()
  setwd(project_dir)
  on.exit(setwd(old_wd))
  allow <- read_bundle_allowlist()

  for (d in c("dashboard_app/data", "dashboard_app/input_data")) {
    if (dir.exists(d)) {
      unlink(list.files(d, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE), force = TRUE)
      unlink(d, recursive = TRUE, force = TRUE)
    }
    dir.create(d, showWarnings = FALSE, recursive = TRUE)
  }

  src <- c(file.path("data", list.files("data", recursive = TRUE)),
           file.path("input_data", list.files("input_data", recursive = TRUE)))
  src <- src[!grepl(.ARCHIVE_PATH, src)]
  keep <- .latest_frame_versions_only(src[bundle_path_allowed(src, allow)])
  for (f in keep) {
    dest <- file.path("dashboard_app", f)
    dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(f, dest, overwrite = TRUE)) stop("bundle_dashboard_mirrors(): could not copy ", f)
  }
  skipped <- setdiff(src, keep)

  check_dashboard_bundle(".", allow = allow)
  mb <- sum(file.info(file.path("dashboard_app", keep))$size, na.rm = TRUE) %/% 1e6
  cat(sprintf("bundle_dashboard_mirrors(): %d allowlisted data file(s) bundled into dashboard_app/ (%d MB); %d file(s) in data/ and input_data/ not on the allowlist, left out.\n",
              length(keep), mb, length(skipped)))
  invisible(list(bundled = keep, skipped = skipped))
}

# The pre-deploy check: everything rsconnect would upload from dashboard_app/ must be on the allowlist, and every
# bundled data file must be byte-identical to its source in data/ or input_data/. Stops on any failure.
check_dashboard_bundle <- function(project_dir = ".", allow = NULL) {
  old_wd <- getwd()
  setwd(project_dir)
  on.exit(setwd(old_wd))
  if (is.null(allow)) allow <- read_bundle_allowlist()
  upload <- rsconnect::listDeploymentFiles("dashboard_app")
  unexpected <- upload[!bundle_path_allowed(upload, allow)]
  if (length(unexpected) > 0) {
    stop("check_dashboard_bundle(): ", length(unexpected), " file(s) in dashboard_app/ are not on the allowlist (",
         DASHBOARD_BUNDLE_ALLOWLIST, ") - NOT deploying: ", paste(head(unexpected, 20), collapse = ", "))
  }
  data_files <- upload[grepl("^(data|input_data)/", upload)]
  differs <- data_files[unname(tools::md5sum(file.path("dashboard_app", data_files))) != unname(tools::md5sum(data_files))]
  if (length(differs) > 0) {
    stop("check_dashboard_bundle(): ", length(differs), " bundled file(s) differ from their source - re-run ",
         "bundle_dashboard_mirrors(): ", paste(head(differs, 20), collapse = ", "))
  }
  cat(sprintf("check_dashboard_bundle(): OK - all %d file(s) rsconnect would upload are allowlisted; %d bundled data file(s) match their source.\n",
              length(upload), length(data_files)))
  invisible(upload)
}

if (sys.nframe() == 0) {
  bundle_dashboard_mirrors(project_dir = if (basename(getwd()) == "shared") "../.." else ".")
}
