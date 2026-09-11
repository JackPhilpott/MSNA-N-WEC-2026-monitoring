# ==============================================================================
# latest_frame_file() - finds the CURRENT sampling-frame version file
# dynamically instead of a hardcoded "_v5_"/"_v6_" filename. Same logic as
# dashboard_app/global.R's own copy of this function (not sourced from there
# directly - that file also sets up the whole dashboard's reactive/data
# environment, which a standalone one-off prep script has no business
# triggering just to reuse one helper).
#
# Extracted 2026-09-11 after cleaning/prep/prep_admin3_wards.R and
# prep_partner_lga_assignment.R were both found still hardcoding a path to
# the long-gone v5 frame (current version: v7) - the exact bug class
# global.R's own copy of this function was written to close during the
# 2026-09-08 rebuild, just never applied to these two one-off scripts.
# ==============================================================================
latest_frame_file <- function(prefix, suffix, dir = "input_data/sampling_frame") {
  pat <- paste0("^", prefix, "_v([0-9]+)_", suffix, "\\.csv$")
  candidates <- list.files(dir, pattern = pat)
  if (length(candidates) == 0) stop(sprintf("latest_frame_file(): no file matching %s_v<N>_%s.csv found in %s", prefix, suffix, dir))
  versions <- as.integer(sub(pat, "\\1", candidates))
  file.path(dir, candidates[which.max(versions)])
}
