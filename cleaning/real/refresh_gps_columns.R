# ==============================================================================
# refresh_gps_columns.R - re-derives real_submissions.csv's THREE GPS columns
# (latitude_submitted, longitude_submitted, dist_to_claimed_device_m) from the
# CURRENT spatial-duplicate audit + frame, without re-running prep_real_
# submissions.R end to end.
#
# WHY THIS EXISTS AS ITS OWN SCRIPT, NOT "just re-run prep" (found 2026-09-27,
# while applying the GPS-duplicate-KPI fix below): prep_real_submissions.R's
# own is_duplicate (section 4) is computed FRESH from raw dup_key/upload-time
# ordering every run, with NO memory of past runs - it does NOT know a
# submission has since been confirmed-deleted. Correctness for a SETTLED
# claimant's is_duplicate value instead depends on real_submissions.csv's OWN
# history: scripts/shared/live_claims.R's apply_live_claim_rule() (called by
# refresh_deletion_columns()) promotes the CURRENT first-LIVE claimant of a
# key each time it runs, but for a claimant that is itself already settled it
# deliberately "keeps exactly the flag it had" - i.e. trusts whatever value
# was ALREADY in the file, rather than recomputing it. A bare prep re-run
# overwrites that accumulated history with the naive value (first-by-raw-time
# = FALSE, everyone else = TRUE, regardless of settled status) BEFORE
# refresh_deletion_columns() ever runs - and once overwritten, a settled
# claimant's true historical FALSE can never be recovered by refresh alone,
# since refresh only touches the CURRENT first-live position, never anyone
# already excluded from "live" by settled status. Verified empirically
# 2026-09-27: a bare prep re-run (with or without this file's own GPS fix -
# tested both, byte-identical result) flips 20 already-settled rows' is_
# duplicate FALSE->TRUE this way. Zero Achieved/credited impact either way
# (is_achieved() never reads is_duplicate - see live_claims.R's own header),
# but it is real, cosmetic drift with no path back short of restoring from a
# pre-re-run backup. This script sidesteps the whole problem: it never
# touches is_duplicate (or any other column) at all, so it carries zero risk
# of that regression - the only way to change these 3 GPS columns without a
# full prep re-run's side effects.
#
# Reuses prep_real_submissions.R's own section 6/6b logic byte-for-byte
# (same gps_lookup construction, same haversine, same non-IDP-only /
# NA-guarded dist_to_claimed_device_m rule) against real_submissions.csv's
# OWN already-repaired non_idp_point_id/pop_type columns - no need to re-read
# the raw anonymised export or repair the NG037 tool bug again, since
# real_submissions.csv already carries the repaired value (non_idp_point_id
# = non_idp_point_id_repaired, prep_real_submissions.R:705).
#
# Scope: ONLY these 3 columns. Row count, row order, every other column
# (including is_duplicate/deletion_status/any_quality_flag) untouched -
# verified by the caller's own before/after diff, same discipline as
# refresh_deletion_columns.R's own scope note.
#
# Usage: source("cleaning/real/refresh_gps_columns.R"); refresh_gps_columns()
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(readxl); library(stringr)})
source("scripts/shared/retry_file_write.R")
if (!exists("latest_frame_file", mode = "function")) source("scripts/shared/latest_frame_file.R")

haversine_m <- function(lat1, lon1, lat2, lon2) {
  R <- 6371000; to_rad <- pi / 180
  dlat <- (lat2 - lat1) * to_rad; dlon <- (lon2 - lon1) * to_rad
  a <- sin(dlat / 2)^2 + cos(lat1 * to_rad) * cos(lat2 * to_rad) * sin(dlon / 2)^2
  2 * R * asin(pmin(1, sqrt(a)))
}

refresh_gps_columns <- function(csv_path = "data/real_submissions.csv",
                                 audit_dir = "cleaning/MSNA_Data_Cleaning/output/checking/internal_audit") {
  if (!file.exists(csv_path)) {
    cat("refresh_gps_columns():", csv_path, "not found - nothing to refresh.\n")
    return(invisible(NULL))
  }
  subs <- read_csv(csv_path, show_col_types = FALSE, na = character(),
                    col_types = cols(.default = col_character()))
  needed <- c("submission_uuid", "pop_type", "non_idp_point_id", "latitude_submitted",
              "longitude_submitted", "dist_to_claimed_device_m")
  missing <- setdiff(needed, names(subs))
  if (length(missing) > 0) {
    stop("refresh_gps_columns(): ", csv_path, " is missing column(s): ", paste(missing, collapse = ", "),
         " - prep_real_submissions.R's output shape has changed, so this refresh needs revisiting rather than guessing.")
  }

  # ---- own-coordinate-only GPS lookup (same logic as prep_real_submissions.R
  # section 6, post the 2026-09-27 fix - see that file's own header) ---------
  spatial_audit_files <- list.files(audit_dir, pattern = "^spatial_duplicate_audit_\\d{4}-\\d{2}-\\d{2}\\.xlsx$", full.names = TRUE)
  gps_lookup <- tibble(uuid = character(), lat = double(), lon = double())
  latest_audit <- NA_character_
  if (length(spatial_audit_files) > 0) {
    audit_dates <- as.Date(str_extract(basename(spatial_audit_files), "\\d{4}-\\d{2}-\\d{2}"))
    latest_audit <- spatial_audit_files[which.max(audit_dates)]
    audit <- read_excel(latest_audit, guess_max = 2000)
    gps_lookup <- audit %>% transmute(uuid, lat, lon) %>% distinct(uuid, .keep_all = TRUE)
  }
  new_lat <- gps_lookup$lat[match(subs$submission_uuid, gps_lookup$uuid)]
  new_lon <- gps_lookup$lon[match(subs$submission_uuid, gps_lookup$uuid)]

  # ---- distance to the claimed point's own frame coordinates (section 6b) -
  point_coords <- read_csv(
    latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"),
    show_col_types = FALSE, col_types = cols_only(survey_id = "c", latitude = "d", longitude = "d")
  ) %>% distinct(survey_id, .keep_all = TRUE)
  claimed <- point_coords[match(subs$non_idp_point_id, point_coords$survey_id), ]
  new_dist <- if_else(
    subs$pop_type == "idp" | is.na(new_lat) | is.na(claimed$latitude) | is.na(claimed$longitude),
    NA_real_,
    round(haversine_m(new_lat, new_lon, claimed$latitude, claimed$longitude), 0)
  )

  # "NA" (the literal string) matches prep's own convention for these columns.
  chr <- function(x) ifelse(is.na(x), "NA", as.character(x))
  new_lat_c <- chr(new_lat); new_lon_c <- chr(new_lon); new_dist_c <- chr(new_dist)

  changed <- subs$latitude_submitted != new_lat_c | subs$longitude_submitted != new_lon_c |
    subs$dist_to_claimed_device_m != new_dist_c
  n_changed <- sum(changed)
  if (n_changed == 0) {
    cat("refresh_gps_columns(): already current with", if (is.na(latest_audit)) "(no audit files found)" else basename(latest_audit), "- no rewrite needed.\n")
    return(invisible(list(changed = 0L)))
  }

  subs$latitude_submitted <- new_lat_c
  subs$longitude_submitted <- new_lon_c
  subs$dist_to_claimed_device_m <- new_dist_c
  retry_file_write(function(p) write_csv(subs, p, na = "NA"), csv_path)

  n_gained <- sum(changed & subs$latitude_submitted != "NA" & new_lat_c != "NA")
  cat(sprintf(
    "refresh_gps_columns(): updated %d of %d row(s) from %s. %d submission(s) now carry their own recovered coordinate (own-uuid rows only; the counterpart-borrowing this fixed is gone). %d row(s) now have a claimed-point distance.\n",
    n_changed, nrow(subs), if (is.na(latest_audit)) "(no audit files found)" else basename(latest_audit),
    sum(new_lat_c != "NA"), sum(new_dist_c != "NA")
  ))
  invisible(list(changed = n_changed))
}

if (sys.nframe() == 0) refresh_gps_columns()
