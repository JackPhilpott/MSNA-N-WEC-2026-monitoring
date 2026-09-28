# Adapts the data officer's daily outputs into the dashboard's submission
# contract (data/real_submissions.csv, data/real_meta.rds — same columns
# as cleaning/mock/README.md's contract, so no dashboard_app/ code needs
# to change). Run from the 2_monitoring/ project root:
#
#   source("cleaning/real/prep_real_submissions.R")
#
# ---- Sources (read-only, never modified) -----------------------------------
# - cleaning/MSNA_Data_Cleaning/output/anonymised_data/*.xlsx — cumulative
#   daily KoBo export (main + roster sheets used here). Most recent file
#   by date-in-filename is used (it's a full re-export each day, not a
#   delta) — see that folder's own dated files for the history.
# - cleaning/MSNA_Data_Cleaning/output/checking/internal_audit/
#   spatial_duplicate_audit_*.xlsx — optional GPS enrichment (raw lat/lon
#   is NOT in the anonymised export itself, almost certainly stripped
#   deliberately for privacy before anonymisation; this audit file
#   incidentally carries coordinates for whatever it flags as spatially
#   proximate).
# - input_data/sampling_frame/ — our own copy of the WORKING frame, used
#   for pcode -> name translation (the real data uses pcodes throughout;
#   every dashboard_app/R/*.R module expects names, matching the mock
#   data's convention, so translating here means zero changes needed
#   downstream) and for idp_population_category (a frame attribute, not
#   something the enumerator answers).
# - input_data/MSNA_2026_admin3.csv — the KoBo form's admin3 ward list
#   (a `select_one_from_file` media attachment, not part of the XLSForm
#   workbook itself — pulled from the KoBo project's Media Files by hand,
#   2026-08-15). Confirmed 100% code coverage against the real export's
#   `admin3` values, and the ward *names* it carries match our own
#   GRID3-based `adm3_name` 1:1 (55/55 checked) even though the two use
#   different pcode schemes — so translating through this file's `label`
#   column is safe to feed straight into the existing ward scaffolding
#   (`get_ward_choices()`/`ward_to_lga` in global.R) with no changes
#   needed there.
#
# ---- What's NOT carried over from the mock data, and why -------------------
# - refugee_hh / "ineligible_refugee" outcome: refugee households aren't
#   being screened for in this round of data collection at all (confirmed
#   2026-08-14) — there's a column in the tool but it's never populated.
#   interview_outcome for real data only ever takes "completed" or
#   "consent_refused".
# - flag_lga_mismatch: the real tool's admin2 selection is what scopes the
#   cascading sample-point choice in the first place, so a submission
#   can't end up matched against a *different* LGA's point the way the
#   mock simulates — always FALSE here, kept only so the column exists
#   dashboard-wide.
# - flag_age_rounder_enum: was a deliberately-injected mock-only pattern
#   to demo the age-heaping check; always FALSE for real data (the
#   Whipple's Index check itself is computed live from resp_age in
#   mod_integrity.R regardless, so this doesn't lose any real detection).
# - latitude_submitted/longitude_submitted: only populated for the subset
#   of submissions present in spatial_duplicate_audit (raw GPS isn't in
#   the anonymised export for everyone) — NA elsewhere. The Coverage
#   Map's cluster markers use the sampling frame's own coordinates, not
#   submitted GPS, so this doesn't affect the map either way.
#
# ---- Known real-data issues this script works around ------------------------
# - **NG037 (Zamfara) tool bug**: a missing ${...} wrapper in the KoBo
#   tool's coalesce() for non_idp_point_id/idp_cluster_id means every
#   Zamfara submission exports with those fields blank. Repaired here the
#   same way the data officer's own progress script does — reconstructed
#   from the per-state sample_point_NG037_non_idp / idp_cluster_NG037
#   columns. Evidence + exact fix location for the tool team: see
#   NG037_tool_bug_evidence.md in this folder.
# - **Duplicate detection**: mirrors the same real, methodology-aware
#   logic (not a generic distance-based guess): non-IDP duplicates share
#   a `non_idp_point_id`; IDP duplicates share `idp_hh_number_from_listing`
#   (Tier 1) or `idp_walk_position` (Tier 2) within the same
#   `idp_cluster_id`. First submission by `_submission_time` is kept.

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(lubridate)
  library(stringr)
  library(uuid)
})

source("cleaning/real/sanity_checks.R")
print_sanity_banner_if_present() # resurface any prior unacknowledged warning right away

CLEANING_OUTPUT_DIR <- "cleaning/MSNA_Data_Cleaning/output"
GPS_OUTLIER_THRESHOLD_M <- 500
DURATION_OUTLIER_MIN <- 20 # flagged, NOT excluded from achieved counts — see
                            # header note; confirmed 2026-08-15, keep as flag-only
# MOVED HERE 2026-09-11 (was inline at the old drop-the-row step below) - now
# needs to be computed early enough to feed flag_date_outlier in the main
# mutate() block, since date_outlier rows no longer get dropped outright -
# see that step's own note for the full reasoning.
DATE_OUTLIER_MIN <- as.Date("2026-08-01") # generous buffer before the 12 Aug fielding start

# previous run's row count, for the row-count sanity check below — read
# BEFORE anything gets overwritten; NULL on a first-ever run.
prev_meta <- if (file.exists("data/real_meta.rds")) readRDS("data/real_meta.rds") else NULL

# Some daily anonymised exports have contained a stray zip entry R's own
# internal unzip (used by both readxl and openxlsx) can't open — confirmed
# 2026-08-25: a literal "[trash]/..." folder, almost certainly an Excel
# autosave/crash-recovery artifact from whatever produced that day's
# export, not real corruption (the external unzip.exe -t on the SAME file
# passes with zero errors — R's internal zip reader is the thing that's
# limited here, not the file). Falls back to re-packaging via Rtools'
# external unzip/zip (stripping whatever entry broke it) only when the
# normal read fails, so this costs nothing on a normal day.
read_excel_robust <- function(path, ...) {
  tryCatch(
    readxl::read_excel(path, ...),
    error = function(e) {
      if (!grepl("cannot be opened", conditionMessage(e))) stop(e)
      cat("NOTE: readxl couldn't open", basename(path), "directly (R's internal zip reader issue, not file corruption) — repackaging via external unzip/zip and retrying.\n")
      unzip_exe <- Sys.which("unzip")
      zip_exe <- Sys.which("zip")
      if (!nzchar(unzip_exe) || !nzchar(zip_exe)) {
        stop("read_excel_robust: normal read failed and no external unzip/zip found on PATH to fall back to. Original error: ", conditionMessage(e))
      }
      extract_dir <- file.path(tempdir(), paste0("xlsx_fix_", as.integer(Sys.time())))
      dir.create(extract_dir)
      system2(unzip_exe, c("-q", shQuote(path), "-d", shQuote(extract_dir)))
      trash_dir <- file.path(extract_dir, "[trash]")
      if (dir.exists(trash_dir)) unlink(trash_dir, recursive = TRUE)
      clean_path <- file.path(tempdir(), paste0("clean_", basename(path)))
      if (file.exists(clean_path)) file.remove(clean_path)
      old_wd <- getwd()
      on.exit(setwd(old_wd), add = TRUE)
      setwd(extract_dir)
      system2(zip_exe, c("-q", "-r", "-X", shQuote(clean_path), "."))
      setwd(old_wd)
      unlink(extract_dir, recursive = TRUE)
      readxl::read_excel(clean_path, ...)
    }
  )
}

# ---- 1. locate + read the most recent anonymised export --------------------
# Tie-break by mtime, not just filename date (2026-09-02): found two
# 2026-09-01-dated files sitting side by side with different naming
# conventions (NGA2605_MSNA_anonymised_2026-09-01.xlsx vs
# anon_2026-09-01.xlsx) — which.max() on the date alone breaks same-date
# ties by first occurrence in list.files()'s (incidental, not guaranteed)
# ordering, so it only picked the right (newer, larger) one by luck that
# time. Ordering by mtime within the max date removes that luck dependency
# regardless of naming convention.
anon_files <- list.files(file.path(CLEANING_OUTPUT_DIR, "anonymised_data"), pattern = "\\.xlsx$", full.names = TRUE)
stopifnot(length(anon_files) > 0)
anon_dates <- as.Date(str_extract(basename(anon_files), "\\d{4}-\\d{2}-\\d{2}"))

# GUARD ADDED 2026-09-25 (Jack: "yes, add the guard"). The data officer's
# 2026-09-24 export was overwritten at 22:24 on 09-23/24 with start, end,
# today AND _submission_time completely BLANK for all 26,222 rows (every
# other column intact - checked column by column against the previous
# day's file). Nothing errored: this script wrote real_submissions.csv with
# submission_date/start_datetime/end_datetime/uploaded_at all NA, which
# would have shipped a dashboard where every partner reads "Not started" and
# no pace/trend/date figure works. A refresh must never accept an export
# like that over good data. Candidates are tried newest-first (same date/
# mtime ordering as before); the first whose start/end/today columns are
# actually populated wins, and a skipped export is announced loudly here AND
# in the sanity-warnings banner further down (bad_export_notice). If NO
# export passes, this stops rather than writing undated data. Only the first
# three columns are read for the probe (start, end, today are columns 1-3 of
# the export); if that layout ever changes the probe steps aside with a
# warning instead of blocking a refresh.
EXPORT_MIN_DATE_SHARE <- 0.5
# ADDED 2026-09-25 (Coordinator/Jack): scripts/shared/date_reconstruction.R can
# fill blank dates from the previous build + the KoBo audit logs instead of
# falling back to an older, staler export. ALLOW_DATE_RECONSTRUCTION switches
# that capability on (it is a no-op on a valid export). What a wholly-blank
# NEWEST export triggers is a POLICY choice that is Jack's to make:
# "fallback"    = skip it and use the newest valid export (exact, but staler);
# "reconstruct" = use the newest export and reconstruct its dates (fresher, part
#                 approximate, loudly flagged on every run).
# DECIDED 2026-09-25 (Jack, decision I, "option 2", relayed verbatim by
# Coordinator): the standing rule is "reconstruct". "fallback" stays as the LAST
# RESORT only: the reconstruct branch below needs the KoBo audit logs
# (DATE_RECON_AUDIT_ZIP), and with none present a blank newest export is still
# skipped in favour of the newest valid one, exactly as before. Nothing changes on
# a valid export. A run that reconstructs says so loudly (console, sanity-warnings
# banner, real_meta$dates, dates_source in real_submissions.csv). Code default only:
# this was set, not run, and the 25 Sep export it was written after was valid.
ALLOW_DATE_RECONSTRUCTION <- TRUE
BLANK_DATE_EXPORT_POLICY <- "reconstruct" # "fallback" | "reconstruct"
source("scripts/shared/date_reconstruction.R")
export_date_share <- function(path) {
  probe <- tryCatch(
    read_excel_robust(path, sheet = "main", range = readxl::cell_cols(1:3), col_types = "text"),
    error = function(e) NULL
  )
  if (is.null(probe) || !all(c("start", "end", "today") %in% names(probe))) return(NA_real_)
  # readxl drops trailing all-blank rows, so a file whose start/end/today are
  # blank in EVERY row (the actual 2026-09-24 failure) reads as 0 rows here -
  # that is share 0, not "couldn't probe".
  if (nrow(probe) == 0) return(0)
  mean(!is.na(probe$start) & nzchar(probe$start) & !is.na(probe$end) & nzchar(probe$end) & !is.na(probe$today) & nzchar(probe$today))
}
candidate_order <- order(anon_dates, file.info(anon_files)$mtime, decreasing = TRUE)
latest_file <- NULL
skipped_exports <- character(0)
for (cand in anon_files[candidate_order]) {
  share <- export_date_share(cand)
  if (is.na(share)) {
    cat("WARNING: couldn't probe the date columns of", basename(cand), "- accepting it unchecked.\n")
    latest_file <- cand
    break
  }
  if (share >= EXPORT_MIN_DATE_SHARE) {
    latest_file <- cand
    break
  }
  if (BLANK_DATE_EXPORT_POLICY == "reconstruct" && ALLOW_DATE_RECONSTRUCTION && file.exists(DATE_RECON_AUDIT_ZIP)) {
    cat("!!! ACCEPTING EXPORT with blank date columns (BLANK_DATE_EXPORT_POLICY = 'reconstruct'):", basename(cand),
        "- dates will be carried forward / reconstructed from the audit logs and flagged.\n")
    latest_file <- cand
    break
  }
  msg <- paste0(basename(cand), " (start/end/today populated in only ", round(100 * share), "% of rows)")
  cat("!!! SKIPPING EXPORT with blank date columns:", msg, "\n")
  skipped_exports <- c(skipped_exports, msg)
}
if (is.null(latest_file)) stop("prep_real_submissions.R: every anonymised export has blank start/end/today columns - refusing to write undated data. Ask the data officer for a corrected export.")
bad_export_notice <- if (length(skipped_exports) > 0) {
  paste0("DATA OFFICER EXPORT SKIPPED (blank start/end/today columns, so no submission dates): ", paste(skipped_exports, collapse = "; "),
         " - this run used the older ", basename(latest_file), " instead, so figures are STALER than the newest export. Ask the data officer to reissue.")
} else NULL
cat("Using anonymised export:", basename(latest_file), "\n")

# FIX 2026-09-25 (Coordinator-approved, "Finding A"): readxl types each column from its first
# `guess_max` rows. A column with NO value in the first 5,000 rows is typed LOGICAL, and every
# value that arrives later is silently dropped (one "Expecting logical" warning per cell, 22,635 of
# them on the 09-25 export, seven columns: sample_point_NG026_non_idp, idp_cluster_NG026,
# admin3_true, special_zone, gps_hard_limit_base, gps_relaxation_used,
# other_wash_soap_observed_type). The first two are this script's per-state ID-repair columns
# (see ni_cols/idp_cols below) - harmless today because the combined id was populated on every
# one of those rows, but a late-starting state whose combined id ever came through blank would
# have lost its repair with no trace.
# read_sheet_guarded() keeps the SAME first read (guess_max = 5000, so every column that was
# typed before is typed exactly as before) and captures readxl's coercion warnings instead of
# printing 22k console lines. It then finds the trap by CONTENT, not by warnings (readxl converts
# a numeric cell in a logical-typed column to TRUE with NO warning, so a warning-only guard would
# miss a late-starting numeric column): every column typed logical is re-read as text in ONE extra
# pass that skips all other columns (~20 s; measured 2026-09-25), and any of them holding a
# non-boolean value is replaced by its text version. On the 09-25 export the only columns whose
# content or type change are the seven above. Coercions of any OTHER kind (a numeric/date column
# meeting stray text) are NOT auto-healed - forcing such a column to text would change a typed
# column downstream code relies on - they raise a sanity warning instead. Result carries attr
# "readxl_guard" (columns re-read as text, values recovered, anything unhealed).
read_sheet_guarded <- function(path, sheet, guess_max = 5000) {
  idx <- integer(0); cls <- character(0)
  df <- withCallingHandlers(
    read_excel_robust(path, sheet = sheet, guess_max = guess_max),
    warning = function(w) {
      m <- conditionMessage(w)
      if (grepl("^Expecting [a-z]+ in ", m) && grepl("R[0-9]+C[0-9]+", m)) {
        idx <<- c(idx, as.integer(sub(".*R[0-9]+C([0-9]+).*", "\\1", m)))
        cls <<- c(cls, sub("^Expecting ([a-z]+) in .*", "\\1", m))
        invokeRestart("muffleWarning")
      }
    }
  )
  is_pop <- function(x) !is.na(x) & nzchar(trimws(x))
  forced <- character(0); n_recovered <- 0L
  lg <- which(vapply(df, is.logical, logical(1)))
  if (length(lg) > 0) {
    ct <- rep("skip", ncol(df)); ct[lg] <- "text"
    txt <- read_excel_robust(path, sheet = sheet, col_types = ct)
    names(txt) <- names(df)[lg]
    for (k in seq_along(lg)) {
      v <- as.character(txt[[k]]); length(v) <- nrow(df) # readxl trims trailing blank rows; those cells are blank
      real <- is_pop(v) & !(toupper(v) %in% c("TRUE", "FALSE"))
      if (any(real)) { df[[lg[k]]] <- v; forced <- c(forced, names(df)[lg[k]]); n_recovered <- n_recovered + sum(is_pop(v)) }
    }
    if (length(forced) > 0) {
      cat(sprintf("NOTE: '%s' sheet - %d column(s) blank in the first %d rows (typed logical by readxl, which drops or mangles every later value) re-read as text, recovering %d value(s): %s\n",
                  sheet, length(forced), guess_max, n_recovered, paste(forced, collapse = ", ")))
    }
  }
  # coercions readxl reported that are NOT in a healed column (i.e. a typed numeric/date column that
  # met a value of another type): these values are gone, so they are reported, not healed
  left <- data.frame(idx = idx, cls = cls, stringsAsFactors = FALSE)
  left <- left[!(names(df)[left$idx] %in% forced), , drop = FALSE]
  unhealed <- if (nrow(left) > 0) {
    agg <- aggregate(list(n = rep(1L, nrow(left))), list(idx = left$idx, cls = left$cls), sum)
    paste0(names(df)[agg$idx], " (", agg$n, " ", agg$cls, ")")
  } else character(0)
  attr(df, "readxl_guard") <- list(sheet = sheet, forced_text = forced, n_values_recovered = n_recovered, unhealed = unhealed)
  df
}
main <- read_sheet_guarded(latest_file, "main")
roster <- read_sheet_guarded(latest_file, "roster")
readxl_guard <- list(main = attr(main, "readxl_guard"), roster = attr(roster, "readxl_guard"))
# only what could NOT be healed is a warning; a healed column loses nothing and would only add a
# persistent banner line on every run (the same seven columns turn up every day)
readxl_guard_notice <- {
  bad <- unlist(lapply(readxl_guard, function(g) if (length(g$unhealed) > 0) paste0("'", g$sheet, "' sheet: ", paste(g$unhealed, collapse = ", "))))
  if (length(bad) > 0) paste0("READXL COERCION: values were dropped by readxl's column-type guess and NOT auto-healed (a typed numeric/date column met a value of another type) - ", paste(bad, collapse = "; "),
                              ". Check the export for those columns; only columns blank in the first 5,000 rows are healed automatically.") else NULL
}

# Fill any blank start/end/today/_submission_time (none in a valid export -> no-op,
# values untouched) from the PREVIOUS build (read here, before it is overwritten
# at the end of this script) and the KoBo audit logs. Each row's dates_source
# says which; a row carried forward keeps its original source, so a
# reconstructed row can never turn into an "exact" one. See date_reconstruction.R.
prev_real <- if (file.exists("data/real_submissions.csv")) {
  suppressWarnings(read_csv("data/real_submissions.csv", show_col_types = FALSE, col_types = cols(.default = col_character()), na = character()))
} else NULL
date_recon <- reconstruct_missing_dates(main, prev_real, allow = ALLOW_DATE_RECONSTRUCTION)
main <- date_recon$main
rm(prev_real)
date_recon_notice <- if (date_recon$summary$n_blank_rows > 0) {
  s <- date_recon$summary
  msg <- paste0(
    "DATES RECONSTRUCTED: ", s$n_blank_rows, " of ", s$n_rows, " rows had blank start/end/today/_submission_time in ", basename(latest_file),
    " - ", s$n_carried_forward, " carried forward exact from the previous build, ", s$n_audit_reconstructed,
    " derived from the KoBo audit logs (start ~1s and date exact, end approximate; uploaded_at/sync lag unavailable; ", s$n_kept_reconstructed,
    " of them already reconstructed in an earlier run and kept marked as such), ", s$n_missing, " still without dates. See dates_source in real_submissions.csv."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  msg
} else NULL

# 2026-09-09: version-agnostic frame lookup, same fix/reasoning as global.R's
# latest_frame_file() (2026-09-08 rebuild) - this script had the identical
# hardcoded "_v5_" pattern that fix was supposed to close everywhere, just
# never updated here too. Found live: 1_sampling's sync scripts archived the
# old v5 files out of input_data/sampling_frame/ once the frame reached v7,
# and this script's hardcoded read broke deploy_dashboard.R's very first
# step as a result - blocking every redeploy, not just serving stale data.
# 2026-09-14: consolidated into scripts/shared/latest_frame_file.R (this
# script's own copy was byte-identical) - the original "runs standalone,
# before dashboard_app/ is ever sourced" reasoning for keeping a separate
# copy no longer applies now that the shared version lives outside
# dashboard_app/ specifically so standalone scripts can use it too.
source("scripts/shared/latest_frame_file.R")

# ---- 2. household-frame lookups (pcode -> name, idp_population_category) ---
household_frame <- read_csv(
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"),
  show_col_types = FALSE, col_types = cols(.default = "c")
)

# FULL's id columns only - for run_sanity_checks()' three FRAME DRIFT
# existence checks, which must ask "does this id point at anything real"
# against the full roster, not against WORKING's shrinking candidate pool
# (added 2026-09-23; see those checks' own note). Three columns of a large
# file, so col_select keeps this cheap.
frame_full_ids <- read_csv(
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"),
  show_col_types = FALSE, col_types = cols(.default = "c"),
  col_select = c(survey_id, cluster_id, strata_id)
)
# 2026-09-27: the state / LGA names and idp_population_category are looked up in FULL, not WORKING.
# WORKING is the SHRINKING candidate pool - an LGA or cluster leaves it once fully achieved
# or when its area goes inaccessible - so translating an interview that is ALREADY collected
# through it blanked that interview's LGA name / IDP category the moment its area left
# WORKING (27 Sep: 31 CRS Shagari rows and 62 FACT IDP rows after an accessibility change;
# ~1,090 older IDP rows and Gubio's 31 rows were already blank the same way). FULL never
# drops a row, and pcode -> name / cluster -> category are one-to-one in it (checked), so the
# joins below cannot multiply rows. Same reasoning as point_coords further down. adm1 moved
# too although nothing is blank yet (14 states in FULL, 11 in WORKING): the same defect, waiting.
frame_full_labels <- read_csv(
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"),
  show_col_types = FALSE, col_types = cols(.default = "c"),
  col_select = c(adm1_pcode, adm1_name, adm2_pcode, adm2_name, pop_type, cluster_id, idp_population_category)
)
adm1_lookup <- frame_full_labels %>% distinct(adm1_pcode, adm1_name)
adm2_lookup <- frame_full_labels %>% distinct(adm2_pcode, adm2_name)
idp_cat_lookup <- frame_full_labels %>%
  filter(pop_type == "idp") %>%
  distinct(cluster_id, idp_population_category)

# admin3 (ward) code -> name, from the KoBo form's own media-file choice
# list — see header note on why this is safe to feed into the existing
# GRID3-based ward scaffolding despite using a different pcode scheme.
admin3_lookup <- read_csv("input_data/MSNA_2026_admin3.csv", show_col_types = FALSE) %>%
  distinct(name, .keep_all = TRUE)

# Point-level coordinates (survey_id -> lat/lon), for dist_to_claimed_device_m
# below (added 2026-09-06, for the partner-recovery workbook's GPS Duplicates
# sheet). FULL not WORKING (same reasoning as household_frame above): a
# non_idp_point_id an enumerator claims could be a point WORKING has since
# dropped (fully achieved / excluded / resampled away) - this lookup only
# needs "does this point exist and where", never "is it still open", so FULL
# is the correct frame to check existence against.
point_coords <- read_csv(
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"),
  show_col_types = FALSE, col_types = cols_only(survey_id = "c", latitude = "d", longitude = "d")
) %>% distinct(survey_id, .keep_all = TRUE)

haversine_m <- function(lat1, lon1, lat2, lon2) {
  R <- 6371000; to_rad <- pi / 180
  dlat <- (lat2 - lat1) * to_rad; dlon <- (lon2 - lon1) * to_rad
  a <- sin(dlat / 2)^2 + cos(lat1 * to_rad) * cos(lat2 * to_rad) * sin(dlon / 2)^2
  2 * R * asin(pmin(1, sqrt(a)))
}

# Confirmed-quality exclusions (uuid -> reason), e.g. duration_under_20,
# fcs_zero. Decoupled from this daily refresh on purpose: the tracker this
# reads from is populated by reports/partner_data_recovery/scripts/
# register_deletion_log_issues.R (deletion_log.R's daily output) and by the
# recovery-workbook verification pipeline (partner contest resolutions),
# both run separately from this script. Affects Achieved only (is_achieved()
# in dashboard_app/global.R); Collected is untouched.
#
# Replaced 2026-09-06 (was a static, manually-built data/CONFIRMED_QUALITY_
# EXCLUSIONS.csv, agreed 2026-08-30 as a provisional process pending a more
# integrated computation path - this is that integration). Now reads the
# version-stamped overlay built by cleaning/real/build_confirmed_deletions_
# overlay.R from the live recovery_issue_tracker.csv - run that script
# first if this file looks stale (check data/CONFIRMED_DELETIONS_OVERLAY_
# version.txt's stamped_at). The old static file is left in place
# (harmless, nothing else reads it) rather than deleted.
quality_exclusions <- if (file.exists("data/CONFIRMED_DELETIONS_OVERLAY.csv")) {
  read_csv("data/CONFIRMED_DELETIONS_OVERLAY.csv", show_col_types = FALSE) %>%
    distinct(uuid, .keep_all = TRUE) %>%
    select(uuid, quality_exclusion_reason = reason)
} else {
  tibble(uuid = character(), quality_exclusion_reason = character())
}

# flagged_deletion_reason (added 2026-09-06, alongside quality_exclusion_
# reason above): a WIDER net - every confirmed_deletion tracker issue
# regardless of status (pending/sent/rejected, not just settled confirmed/
# contested). is_achieved() (dashboard_app/global.R) checks this one, not
# quality_exclusion_reason, so a flagged-but-not-yet-confirmed record shows
# as provisionally not achieved on the dashboard (the intended incentive)
# while still counting as achieved for quality_exclusion_reason's own
# purpose - the resampling-facing basis, which only excludes a SETTLED
# deletion. See cleaning/real/build_confirmed_deletions_overlay.R's header
# for why two separate overlays exist.
#
# deletion_status (added 2026-09-09, alongside flagged_deletion_reason):
# the tracker's own status for that same flagged row (pending/sent/rejected/
# confirmed/contested) - carried through so downstream code can tell a
# SETTLED deletion (confirmed/contested - feeds resampling too, via
# CONFIRMED_DELETIONS_OVERLAY.csv) apart from a merely PENDING one, without
# re-deriving that distinction from two separately-read overlays every time
# it's needed (dashboard_app/global.R's Confirmed/Pending Deletion columns,
# 2026-09-09). A row with recovery_type set is never in this overlay at all
# (build_confirmed_deletions_overlay.R excludes it from both overlays), so
# deletion_status/flagged_deletion_reason being NA already means "achieved,
# not flagged, or recovered" - no separate recovery_type column needed here.
flagged_deletions <- if (file.exists("data/FLAGGED_DELETIONS_OVERLAY.csv")) {
  read_csv("data/FLAGGED_DELETIONS_OVERLAY.csv", show_col_types = FALSE) %>%
    distinct(uuid, .keep_all = TRUE) %>%
    select(uuid, flagged_deletion_reason = reason, deletion_status = status)
} else {
  tibble(uuid = character(), flagged_deletion_reason = character(), deletion_status = character())
}

# ---- 2b. our own independent audit-trail-based duration (added 2026-09-10)
# duration_min below USED TO be a naive end-minus-start field diff. Found
# 2026-09-10 while cross-checking the data officer's duration_under_20
# output (a NO-APPEAL auto-delete rule) against it: that naive figure goes
# NEGATIVE for a real chunk of submissions (one as far as -160 minutes —
# `end` sitting before `start` in the raw export), which is why it was
# wildly over-flagging (342 vs the data officer's 80). Verified the data
# officer's own audit-trail-based figure IS trustworthy where it fires (67/67
# confirmed correct on the disputed set, zero false positives) — their real
# problem is coverage. UPDATE 2026-09-10 (later same night, full-dataset
# run, not just the disputed subset): the true completed-only total is 862,
# not the 235 first estimated from the disputed set alone — the disputed set
# only checked the 406 rows where our naive figure and the DO's own output
# already disagreed; a further ~600 genuinely-short interviews turned up in
# the much larger bucket where naive and the DO had already (wrongly)
# agreed "not short" together. Same missing-pipeline-run pattern as
# duplicate_point, just a bigger share of the dataset than the first,
# partial check suggested.
# Jack, 2026-09-10: stop using the naive figure anywhere, replace duration_min
# itself with the real audit-based number, computed independently rather than
# trusting the data officer's own (possibly-stale) cache — see
# cleaning/real/audit_duration.R's header for the full reasoning. This feeds
# EVERY downstream use of duration_min unchanged (avg/median duration KPIs,
# mod_integrity.R's histogram, the partner digest and mod_quality.R's
# Duration/Duration outlier columns) — all of those were showing the same
# broken negative-duration figures before this fix, not just the deletion
# decision, so no separate parallel column is kept for them.
# NA where a submission has no parseable audit.csv (should be rare — 401/401
# resolved in the disputed-set check) — left NA rather than falling back to
# the naive figure, so a missing audit trail is never silently treated as
# "not short" using a value already shown to be unreliable; flag_duration_
# outlier below is FALSE (not flagged) for an NA duration, consistent with
# this workspace's "never drop legitimate data" default when evidence is
# incomplete.
source("cleaning/real/audit_duration.R")
our_audit_durations <- compute_our_audit_durations()

# ---- 3. NG037 tool-bug repair (same approach as the data officer's own
# progress script — reconstruct from the per-state coalesce() columns) ------
ni_cols <- grep("^sample_point_NG\\d+_non_idp$", names(main), value = TRUE)
idp_cols <- grep("^idp_cluster_NG\\d+$", names(main), value = TRUE)
first_non_na <- function(df) apply(df, 1, function(r) { r <- r[!is.na(r)]; if (length(r)) r[1] else NA_character_ })

main <- main %>%
  mutate(
    rebuilt_ni = first_non_na(across(all_of(ni_cols))),
    rebuilt_idp = first_non_na(across(all_of(idp_cols))),
    non_idp_point_id_repaired = coalesce(as.character(non_idp_point_id), rebuilt_ni),
    idp_cluster_id_repaired = coalesce(as.character(idp_cluster_id), rebuilt_idp),
    was_id_repaired = (is.na(non_idp_point_id) & !is.na(rebuilt_ni)) | (is.na(idp_cluster_id) & !is.na(rebuilt_idp))
  )

cat("NG037 tool-bug repairs applied:", sum(main$was_id_repaired), "of", nrow(main), "rows\n")

# resolved sample_point_id / cluster_id / strata_id. IDP has no PRE-ASSIGNED
# per-household point the way non-IDP does (selection happens live in the
# field, not from a pre-assigned list — see the sampling methodology notes
# in ../../1_sampling/CLAUDE.md), but it does carry real per-household
# identifying info collected on-site: idp_hh_number_from_listing (Tier 1 —
# position in the household listing entered into KoBo for RNG selection)
# or idp_walk_position (Tier 2 fallback). matched_survey_id for IDP is built
# from these instead of just reusing the cluster id (which is all it held
# before 2026-08-22) — confirmed with Jack: the field-listing number is
# meant to be a persistent, never-reused identity within a cluster across
# the whole field period (not re-listed fresh per visit), so cluster +
# listing/walk position is a real per-household key, not just a per-visit
# one. The ~1.5% of IDP rows with neither Tier 1 nor Tier 2 info fall back
# to the cluster id alone, same as every IDP row did before this change —
# so is_achieved() (global.R), which only checks matched_survey_id for
# non-NA-ness, counts exactly the same rows as achieved as before; only the
# ID's VALUE is more specific now, not which rows have one. Any row where
# this key collides with another (same cluster + same listing/walk
# position) is, per Jack, always a field-team error, never a legitimate
# re-listing — already handled by the existing dup_key logic below,
# unchanged by this.
main <- main %>%
  mutate(
    idp_household_suffix = case_when(
      !is.na(idp_hh_number_from_listing) ~ paste0("L", idp_hh_number_from_listing),
      !is.na(idp_walk_position) ~ paste0("W", idp_walk_position),
      TRUE ~ NA_character_
    ),
    matched_survey_id = case_when(
      sample_pop_type_filter == "idp" & !is.na(idp_household_suffix) ~ paste0(idp_cluster_id_repaired, "_", idp_household_suffix),
      sample_pop_type_filter == "idp" ~ idp_cluster_id_repaired,
      TRUE ~ non_idp_point_id_repaired
    ),
    matched_cluster_id = if_else(sample_pop_type_filter == "idp", idp_cluster_id_repaired, str_remove(non_idp_point_id_repaired, "_(HH|R)\\d+$")),
    matched_strata_id = paste0(sample_pop_type_filter, "_", admin2),
    matched_status = if_else(sample_pop_type_filter == "idp", "primary", sample_status_filter)
  )

# ---- 4. real duplicate detection (methodology-aware, not distance-based) ---
# Claimant order = exact upload time, as it always was. ADDED 2026-09-25: a row
# with NO upload time (dates reconstructed from audit logs - see
# date_reconstruction.R) sorts AFTER every exact one - it is newer than the last
# good build by construction - and among such rows by start. On a valid export
# every row has an upload time, so the first key is constant, the third is all
# NA and this is exactly the previous arrange(`_submission_time`) (arrange is
# stable). Same key as scripts/shared/live_claims.R. Do NOT order by the audit
# form-start for rows that HAVE an upload time: that would change the canonical
# claimant in ~16% of existing claim groups.
main <- main %>%
  mutate(.up_missing = is.na(`_submission_time`) | as.character(`_submission_time`) %in% c("", "NA")) %>%
  arrange(.up_missing,
          if_else(.up_missing, NA_character_, as.character(`_submission_time`)),
          if_else(.up_missing, as.character(start), NA_character_)) %>%
  select(-.up_missing) %>%
  mutate(
    dup_key = case_when(
      sample_pop_type_filter == "idp" & !is.na(idp_hh_number_from_listing) ~
        paste0(idp_cluster_id_repaired, "|listing_", idp_hh_number_from_listing),
      sample_pop_type_filter == "idp" & !is.na(idp_walk_position) ~
        paste0(idp_cluster_id_repaired, "|walk_", idp_walk_position),
      sample_pop_type_filter == "idp" ~ NA_character_,
      TRUE ~ non_idp_point_id_repaired
    )
  ) %>%
  group_by(dup_key) %>%
  mutate(dup_n = if_else(is.na(dup_key), 1L, n()), dup_rank = row_number()) %>%
  ungroup() %>%
  mutate(is_duplicate = !is.na(dup_key) & dup_n > 1 & dup_rank > 1)

# ---- 5. roster_count (real hh_size-vs-roster check) -------------------------
roster_counts <- roster %>%
  count(parent_instance_name, name = "roster_count")

main <- main %>% left_join(roster_counts, by = c("instance_name" = "parent_instance_name"))

# ---- 6. optional GPS enrichment from the spatial-duplicate audit -----------
# 2026-09-27 (Jack, "GPS duplicate submissions" KPI fix, option 1): each row now carries ONLY its
# own submitted coordinate - the coordinate recorded on the audit row where THIS uuid is the
# `uuid` column (the flagged submission itself), never copied from the `matched_uuid` column's
# counterpart. Before this, both members of a flagged pair were assigned the SAME single lat/lon
# (whichever the audit row carried, which is the `uuid` member's own reading - verified 2026-09-27,
# see _working_files/gps_audit_pair_assignment_2026-09-27.md), which meant the dashboard's exact-
# GPS-reuse KPI (find_gps_duplicate_groups(), global.R) was counting audit PAIRS by construction:
# 100% of its groups (60/60 on the 27 Sep data) came from this assignment, not genuine reuse. The
# `matched_uuid` half of the old bind_rows() is simply dropped; dist_to_claimed_device_m (6b below)
# already only ever used whatever lat/lon landed here, so restricting the source is the whole fix.
# A same-day update to just these 3 columns without a full prep re-run: cleaning/real/refresh_gps_
# columns.R (built the same night - see its own header for why a bare prep re-run isn't safe on
# data that already has confirmed deletions, and this file's own section 4 is unaffected either way).
spatial_audit_files <- list.files(
  file.path(CLEANING_OUTPUT_DIR, "checking/internal_audit"),
  pattern = "^spatial_duplicate_audit_\\d{4}-\\d{2}-\\d{2}\\.xlsx$", full.names = TRUE
)
gps_lookup <- tibble(uuid = character(), lat = double(), lon = double())
if (length(spatial_audit_files) > 0) {
  audit_dates <- as.Date(str_extract(basename(spatial_audit_files), "\\d{4}-\\d{2}-\\d{2}"))
  latest_audit <- spatial_audit_files[which.max(audit_dates)]
  audit <- read_excel(latest_audit, guess_max = 2000)
  gps_lookup <- audit %>% transmute(uuid, lat, lon) %>% distinct(uuid, .keep_all = TRUE)
  cat("GPS coordinates recovered for", nrow(gps_lookup), "submissions via spatial-duplicate audit (", basename(latest_audit), ") - own coordinate only, no longer borrowed from a flagged pair's counterpart\n")
}
main <- main %>% left_join(gps_lookup, by = "uuid")

# ---- 6b. distance from submitted GPS to the CLAIMED point's own frame
# coordinates (added 2026-09-06, for the recovery workbook's GPS Duplicates
# sheet) - a DIFFERENT signal from dist_to_matched_point_m/match_quality
# below, which compare against whatever point the post-hoc GPS matching
# assigned. This compares against whatever point the ENUMERATOR claimed
# (non_idp_point_id) regardless of match outcome - the two can legitimately
# differ (a claim can be wrong even when post-hoc matching still finds SOME
# nearby point). Non-IDP only (IDP has no pre-assigned per-household point to
# claim against) - NA wherever submitted GPS wasn't recovered via the
# spatial-duplicate audit above (most rows) or the claimed point_id doesn't
# exist in the frame.
main <- main %>%
  left_join(
    point_coords %>% rename(claimed_lat = latitude, claimed_lon = longitude),
    by = c("non_idp_point_id_repaired" = "survey_id")
  ) %>%
  mutate(
    dist_to_claimed_device_m = if_else(
      sample_pop_type_filter == "idp" | is.na(lat) | is.na(claimed_lat) | is.na(claimed_lon),
      NA_real_,
      round(haversine_m(lat, lon, claimed_lat, claimed_lon), 0)
    )
  )

# ---- 7. assemble the dashboard's submission contract ------------------------
out <- main %>%
  left_join(adm1_lookup, by = c("admin1" = "adm1_pcode")) %>%
  left_join(adm2_lookup, by = c("admin2" = "adm2_pcode")) %>%
  left_join(idp_cat_lookup, by = c("matched_cluster_id" = "cluster_id")) %>%
  left_join(admin3_lookup %>% select(name, ward_label = label), by = c("admin3" = "name")) %>%
  left_join(quality_exclusions, by = "uuid") %>%
  left_join(flagged_deletions, by = "uuid") %>%
  left_join(our_audit_durations %>% select(uuid, duration_audit_sum_all_minutes), by = "uuid") %>%
  mutate(
    duration_min = duration_audit_sum_all_minutes, # was as.numeric(difftime(end, start, units = "mins")) — see 2b above
    sync_lag_min = as.numeric(difftime(`_submission_time`, end, units = "mins")),
    interview_outcome = if_else(tolower(as.character(consent)) == "yes", "completed", "consent_refused"),
    match_quality = case_when(
      is.na(matched_survey_id) ~ "unmatched_no_point_id",
      !is.na(dist_btn_sample_collected) & dist_btn_sample_collected > GPS_OUTLIER_THRESHOLD_M ~ "matched_gps_outlier",
      TRUE ~ "matched"
    ),
    flag_gps_outlier = match_quality == "matched_gps_outlier",
    flag_duration_outlier = !is.na(duration_min) & duration_min < DURATION_OUTLIER_MIN,
    flag_hh_size_mismatch = !is.na(hh_size) & !is.na(roster_count) & as.numeric(hh_size) != roster_count,
    flag_lga_mismatch = FALSE, # see header note — not reachable with this tool's cascading select
    flag_off_hours = !is.na(start) & !(hour(start) %in% 6:19),
    flag_age_rounder_enum = FALSE, # mock-only concept, see header note
    # ADDED 2026-09-11 - see the old "7b. exclude date-outlier submissions"
    # step below (now repurposed to null, not drop) for the full reasoning.
    flag_date_outlier = !is.na(start) & (as.Date(start) < DATE_OUTLIER_MIN | as.Date(start) > Sys.Date()),
    tier2_fallback_used = if_else(sample_pop_type_filter == "idp", !is.na(idp_walk_position), NA)
  ) %>%
  transmute(
    submission_uuid = coalesce(uuid, `meta.rootUuid`, replicate(n(), UUIDgenerate())),
    submission_date = as.Date(start),
    start_datetime = start,
    end_datetime = end,
    uploaded_at = `_submission_time`,
    sync_lag_min,
    duration_min,
    interview_outcome,
    org_id,
    enum_id,
    enum_gender,
    enum_age = suppressWarnings(as.numeric(enum_age)),
    admin1 = adm1_name,
    admin2_submitted = adm2_name,
    admin3_submitted = ward_label,
    latitude_submitted = lat,
    longitude_submitted = lon,
    setting,
    resp_gender,
    resp_age = suppressWarnings(as.numeric(resp_age)),
    resp_hoh_yn,
    hoh_gender,
    hoh_age = suppressWarnings(as.numeric(hoh_age)),
    hh_size = suppressWarnings(as.numeric(hh_size)),
    roster_count,
    matched_survey_id,
    matched_cluster_id,
    matched_strata_id,
    matched_status,
    pop_type = sample_pop_type_filter,
    idp_population_category,
    tier2_fallback_used,
    dist_to_matched_point_m = dist_btn_sample_collected,
    match_quality,
    is_duplicate,
    quality_exclusion_reason,
    flagged_deletion_reason,
    deletion_status,
    flag_gps_outlier,
    flag_duration_outlier,
    flag_hh_size_mismatch,
    flag_lga_mismatch,
    flag_off_hours,
    flag_age_rounder_enum,
    flag_date_outlier,
    # ---- raw claim fields (added 2026-09-06, for the partner recovery
    # workbook's GPS Duplicates / IDP Listing Duplicates sheets) — the
    # enumerator's OWN claimed point/listing identity, already NG037-repaired
    # above, as distinct from matched_survey_id/matched_cluster_id (the
    # post-hoc GPS match, which can legitimately disagree with the claim).
    # Not previously exposed here since dashboard_app/ never needed them —
    # only the recovery-workbook pipeline does.
    non_idp_point_id = non_idp_point_id_repaired,
    idp_hh_number_from_listing,
    idp_walk_position,
    claim_group_size = dup_n, # how many submissions share this exact claimed identity (point, or IDP listing/walk position) — dup_n from the duplicate-detection step above, reused rather than recomputed
    dist_to_claimed_device_m,
    # ADDED 2026-09-25: where this row's dates came from - "export" (always,
    # on a valid export), "carried_forward" (exact, from the previous build),
    # "audit_reconstructed" (approximate: start ~1s, end ~90% within 60s, no
    # uploaded_at), or "missing". See scripts/shared/date_reconstruction.R.
    dates_source,
    dates_reconstructed = dates_source == "audit_reconstructed"
  ) %>%
  mutate(
    any_quality_flag = flag_gps_outlier | flag_duration_outlier | flag_hh_size_mismatch | flag_lga_mismatch | is_duplicate
  ) %>%
  arrange(start_datetime)

# ADDED 2026-09-25 (Coordinator/Jack, 4a): the first LIVE claimant of a point/
# listing slot is not a duplicate even when an earlier submission (since
# confirmed-deleted, or never a completed interview) came before it - see
# scripts/shared/live_claims.R for the rule, the ordering key and why it must
# not switch to the audit form-start. Uses the deletion status joined above
# (the overlays as of the previous run); refresh_deletion_columns.R re-applies
# it with this run's freshly rebuilt overlays. Adds n_live_claims.
source("scripts/shared/live_claims.R")
out <- apply_live_claim_rule(out, settled_uuid = out$submission_uuid[out$deletion_status %in% c("confirmed", "contested")])

# ---- 7b. date-outlier submissions (2026-08-27, REPURPOSED 2026-09-11) — a
# device's clock can be wrong at the START of an interview even when
# everything else about the submission is real and valid: found via one NRC
# submission with start_datetime of 2022-09-12 while end_datetime was
# correctly today (a ~4-year gap, giving a nonsensical multi-million-minute
# duration_min that flag_duration_outlier's own threshold doesn't catch,
# since it's a huge POSITIVE value, not the negative-duration case that
# check looks for). submission_date is derived from start_datetime (see the
# mutate() above), so a bad device clock at start corrupts FIELDING_START
# (global.R: min(submission_date)) and every days-elapsed/pace/ETA
# calculation downstream of it.
#
# 2026-08-27 (Jack): excluded these rows entirely, rather than repair/guess
# a corrected date. REPURPOSED 2026-09-11 (Jack): this was worse than a
# no-appeal deletion - no tracker row, no appeal path, the interview just
# vanished with no trace. Now these rows flow through into real_submissions.
# csv (so they count as Collected and get a real independent check +
# recovery-workbook appeal path, same as every other reason - see
# independent_deletion_checks.R's run_independent_date_outlier_check()) -
# but submission_date/start_datetime/duration_min are still nulled for
# exactly these rows specifically, preserving the ORIGINAL protective intent
# (a corrupted clock must never corrupt FIELDING_START/pace/ETA) without
# silently dropping the row itself. flag_date_outlier (set earlier, in the
# main mutate() block) is what independent_deletion_checks.R actually keys
# off - computed from the ORIGINAL start value, before it gets nulled here.
# duration_min deliberately NOT nulled: it's sourced from the audit log's
# active-editing-time SUM (duration_audit_sum_all_minutes, see the 2b note
# above), a relative measure between audit events on the device's own
# clock - a bad ABSOLUTE clock reading doesn't corrupt a delta between two
# readings on that same (if wrong) clock, so this figure stays reliable
# even when start's absolute timestamp isn't. Confirmed this reasoning
# rather than assumed it - nulling it would have destroyed real, valid
# signal for no reason.
if (any(out$flag_date_outlier)) {
  msg <- paste0(
    sum(out$flag_date_outlier), " submission(s) have an implausible submission_date ",
    "(before ", format(DATE_OUTLIER_MIN, "%d %b %Y"), " or after today — almost always a device ",
    "clock wrong at the start of the interview, not a real fielding date): ",
    paste(out$submission_uuid[out$flag_date_outlier], collapse = ", "),
    " - kept as real rows (Collected), submission_date/start_datetime nulled, independently flagged for the recovery workbook."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  write_sanity_warnings(msg, source_label = "prep_real_submissions.R")
  out$submission_date[out$flag_date_outlier] <- as.Date(NA)
  out$start_datetime[out$flag_date_outlier] <- as.POSIXct(NA)
}

cat("Ward names translated:", sum(!is.na(out$admin3_submitted)), "of", nrow(out), "rows\n")

# ---- 8. sanity checks — see cleaning/real/sanity_checks.R for the full
# rationale (added 2026-08-21). Runs before the write below so a check
# could in principle inspect the file about to be replaced; doesn't block
# the write either way — warn-and-continue, confirmed with Jack.
# 2026-09-25: the partner REGISTRY (assignment orgs + config/partner_registry.csv), not the
# assignment alone - a partner whose LGAs were all reallocated (ACF -> ZOA) holds no assignment
# row but is still a valid collector; deriving this from the assignment made every one of its
# interviews an "UNKNOWN ORG_ID". See scripts/shared/partner_registry.R.
source("scripts/shared/partner_registry.R")
known_org_ids <- read_partner_registry()$org_id
sanity_issues <- c(
  if (!is.null(bad_export_notice)) bad_export_notice, # see the export-selection guard near the top of this file
  if (!is.null(date_recon_notice)) date_recon_notice, # every run that reconstructs any dates says so, here and in real_meta$dates
  if (!is.null(readxl_guard_notice)) readxl_guard_notice, # values readxl dropped that read_sheet_guarded() could not heal (normally none)
  run_sanity_checks(out, main, roster, prev_meta, known_org_ids, household_frame, frame_full = frame_full_ids),
  check_frame_freshness(),
  check_accessibility_freshness(),
  check_target_revision()
)
write_sanity_warnings(sanity_issues)
if (length(sanity_issues) > 0) {
  cat("\n"); print_sanity_banner_if_present()
} else {
  cat("Sanity checks: no issues found.\n")
}

# retry_file_write() (OneDrive-lock-tolerant staging write) was defined
# inline here until 2026-09-22; it now lives in scripts/shared/ because
# cleaning/real/refresh_deletion_columns.R needs the identical guarantee
# for this same file, and a second hand-maintained copy of a retry/rename
# routine is exactly the duplicated-logic-drifts pattern this project
# keeps re-finding. Same path convention as latest_frame_file.R above.
source("scripts/shared/retry_file_write.R")

dir.create("data", showWarnings = FALSE)
retry_file_write(function(p) write_csv(out, p), "data/real_submissions.csv")

meta <- list(
  generated_at = Sys.time(),
  source_file = basename(latest_file),
  skipped_exports = skipped_exports, # newer exports the date guard rejected this run (character(0) normally)
  dates = date_recon$summary,        # rows with blank export dates and how each was filled (all zero on a valid export)
  readxl_forced_text = readxl_guard, # per sheet: columns re-read as text so no late value is dropped, values recovered, anything unhealed
  n_rows = nrow(out),
  n_completed = sum(out$interview_outcome == "completed"),
  n_unmatched = sum(out$match_quality == "unmatched_no_point_id"),
  is_mock_data = FALSE
)
retry_file_write(function(p) saveRDS(meta, p), "data/real_meta.rds")

cat("\nWrote data/real_submissions.csv:", nrow(out), "rows\n")
cat("Interview outcomes:\n"); print(table(out$interview_outcome))
cat("Match quality:\n"); print(table(out$match_quality))
cat("Duplicates:", sum(out$is_duplicate), "\n")
cat("Any quality flag:", sum(out$any_quality_flag), "/", nrow(out), "\n")
