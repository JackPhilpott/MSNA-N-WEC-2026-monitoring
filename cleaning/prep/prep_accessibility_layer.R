# One-time/rerunnable prep: copy the accessibility-status layer produced by
# 1_sampling/resampling/ into this project's own input_data/, per the
# static-copy convention in 1_sampling/CLAUDE.md ("treat this project's
# outputs as static input files to copy in, never read live from").
#
# Source (1_sampling/resampling/output/):
#   master_accessibility_status_ward_level.csv
#   master_accessibility_status_lga_level.csv
#   gis/accessible_area_lga_ward_portions.{shp,shx,dbf,prj}
#   NGA_MSNA_2026_accessibility_impact_workbook.xlsx ("Strata Level" sheet only)
#
# 2026-08-26: added the LGA-level CSV (ward-portion accessible/inaccessible
# counts per LGA, for the Coverage Map's LGA hover popup) and the impact
# workbook's "Strata Level" sheet (population-remaining-accessible, split by
# pop type — the only source file that actually has this split; the LGA-
# level CSV's own population columns turned out to be the unreduced full
# design population, verified directly against the sampling frame before
# reaching for the workbook instead). The workbook is NOT copied whole —
# only its "Strata Level" sheet is extracted into its own clean CSV
# (accessibility_strata_level.csv), same spirit as prep_real_submissions.R
# isolating the xlsx-quirks workaround below to prep time so global.R can
# stay a plain read_csv(). "Strata ID" in that sheet already matches this
# project's own strata_frame$strata_id format exactly (e.g.
# "non_idp_NG002001") — confirmed directly, no name-fuzzy-matching needed.
#
# Still deliberately NOT copied: the stage2 frame's accessible_status
# column — that's the separate, deliberate sampling-frame-integration
# follow-up (Jack: pending decisions there), out of scope for the Coverage
# Map / completeness-indicator work this file supports.
#
# Output: input_data/accessibility/{master_accessibility_status_ward_level.csv,
# master_accessibility_status_lga_level.csv, accessibility_strata_level.csv,
# accessible_area_lga_ward_portions.{shp,shx,dbf,prj}, _accessibility_version.txt}
#
# The version-stamp file mirrors 1_sampling's own _frame_version.txt
# mechanism (scripts/stamp_frame_version.R) rather than this project's more
# common *_meta.rds sidecar convention — deliberately, so it can be read by
# the same key:value parser (read_frame_version(), cleaning/real/
# sanity_checks.R) already used for the sampling frame's freshness check.
# check_accessibility_freshness() in that file compares the md5s recorded
# here against a fresh md5 of 1_sampling's current live files, so a stale
# copy is caught automatically as more partner reports land — this data is
# expected to be refreshed repeatedly over the course of the assessment,
# unlike most other static copies here.
#
# Rerun whenever 1_sampling/resampling/output/ produces a new accessibility
# extract (i.e. new partner reports have landed).
#
# Also regenerates accessible_area_lga_ward_portions_repaired.gpkg (2026-
# 09-02) — the geometry dashboard_app/global.R's accessibility_sf actually
# reads. Snapping the raw shapefile's ward-portion polygons to 4 decimal
# places (the precision reduction every OTHER boundary layer in the app
# uses safely) collapses nearby vertices in this specific layer and
# produces self-intersecting rings — 23% of rows came out invalid, 133 came
# out fully empty — which crashed the Leaflet widget on the live dashboard
# the moment a viewer toggled the Accessibility layer on. Repairing this
# once here (rather than on every app startup, which is what caused a
# separate shinyapps.io "startup took too long" failure the same day) means
# every rerun of THIS script — i.e. every accessibility refresh — keeps the
# dashboard's copy current automatically, with no separate manual
# precompute step to remember.

suppressPackageStartupMessages({
  library(tools)
  library(readxl)
  library(sf)
  library(dplyr)
})

SRC_DIR <- "../1_sampling/resampling/output"
DEST_DIR <- "input_data/accessibility"

if (!dir.exists(SRC_DIR)) {
  stop(
    "prep_accessibility_layer.R: ", SRC_DIR, " not found. Run this from the ",
    "2_monitoring project root with 1_sampling checked out as a sibling folder."
  )
}

dir.create(DEST_DIR, showWarnings = FALSE, recursive = TRUE)

# ---- xlsx read workaround (same [trash]-zip-entry issue documented in
# cleaning/real/prep_real_submissions.R's read_excel_robust()) — isolated
# here at prep time so global.R never needs to know about it. -------------
read_excel_robust <- function(path, ...) {
  tryCatch(
    readxl::read_excel(path, ...),
    error = function(e) {
      if (!grepl("cannot be opened", conditionMessage(e))) stop(e)
      unzip_exe <- Sys.which("unzip")
      zip_exe <- Sys.which("zip")
      if (!nzchar(unzip_exe) || !nzchar(zip_exe)) {
        stop("prep_accessibility_layer.R: normal xlsx read failed and no external unzip/zip found on PATH. Original error: ", conditionMessage(e))
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

ward_csv_src <- file.path(SRC_DIR, "master_accessibility_status_ward_level.csv")
lga_csv_src <- file.path(SRC_DIR, "master_accessibility_status_lga_level.csv")
workbook_src <- file.path(SRC_DIR, "NGA_MSNA_2026_accessibility_impact_workbook.xlsx")
shp_files_src <- list.files(
  file.path(SRC_DIR, "gis"), pattern = "^accessible_area_lga_ward_portions\\.(shp|shx|dbf|prj|cpg)$",
  full.names = TRUE
)

if (!file.exists(ward_csv_src)) stop("prep_accessibility_layer.R: ", ward_csv_src, " not found.")
if (!file.exists(lga_csv_src)) stop("prep_accessibility_layer.R: ", lga_csv_src, " not found.")
if (!file.exists(workbook_src)) stop("prep_accessibility_layer.R: ", workbook_src, " not found.")
if (length(shp_files_src) == 0) stop("prep_accessibility_layer.R: no accessible_area_lga_ward_portions.* shapefile parts found in ", file.path(SRC_DIR, "gis"))

invisible(file.copy(ward_csv_src, file.path(DEST_DIR, basename(ward_csv_src)), overwrite = TRUE))
invisible(file.copy(lga_csv_src, file.path(DEST_DIR, basename(lga_csv_src)), overwrite = TRUE))
invisible(file.copy(shp_files_src, file.path(DEST_DIR, basename(shp_files_src)), overwrite = TRUE))

strata_level <- read_excel_robust(workbook_src, sheet = "Strata Level")
strata_csv_dest <- file.path(DEST_DIR, "accessibility_strata_level.csv")
write.csv(strata_level, strata_csv_dest, row.names = FALSE)

ward_csv_dest <- file.path(DEST_DIR, basename(ward_csv_src))
lga_csv_dest <- file.path(DEST_DIR, basename(lga_csv_src))
shp_src <- file.path(SRC_DIR, "gis", "accessible_area_lga_ward_portions.shp")

n_ward_rows <- length(readLines(ward_csv_dest)) - 1L
n_lga_rows <- length(readLines(lga_csv_dest)) - 1L

version_lines <- c(
  paste0("stamped_at: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  paste0("ward_csv_source: ", normalizePath(ward_csv_src)),
  paste0("ward_csv_mtime: ", format(file.info(ward_csv_src)$mtime, "%Y-%m-%d %H:%M:%S")),
  paste0("ward_csv_md5: ", unname(md5sum(ward_csv_src))),
  paste0("ward_csv_rows: ", n_ward_rows),
  paste0("lga_csv_source: ", normalizePath(lga_csv_src)),
  paste0("lga_csv_mtime: ", format(file.info(lga_csv_src)$mtime, "%Y-%m-%d %H:%M:%S")),
  paste0("lga_csv_md5: ", unname(md5sum(lga_csv_src))),
  paste0("lga_csv_rows: ", n_lga_rows),
  paste0("workbook_source: ", normalizePath(workbook_src)),
  # mtime, not md5, for the workbook specifically — found 2026-08-26 that a
  # human having the workbook open in Excel puts an exclusive lock on it
  # that blocks md5sum() (and even certutil -hashfile) entirely, while
  # file.info()'s metadata-only read is unaffected. Only read_excel_robust()
  # above (external unzip, not a direct file handle) can get the CONTENT
  # while it's open — not worth doing that a second time just to hash it.
  paste0("workbook_mtime: ", format(file.info(workbook_src)$mtime, "%Y-%m-%d %H:%M:%S")),
  paste0("strata_level_rows: ", nrow(strata_level)),
  paste0("shp_source: ", normalizePath(shp_src)),
  paste0("shp_mtime: ", format(file.info(shp_src)$mtime, "%Y-%m-%d %H:%M:%S")),
  paste0("shp_md5: ", unname(md5sum(shp_src)))
)
writeLines(version_lines, file.path(DEST_DIR, "_accessibility_version.txt"))

cat("Copied accessibility layer:\n")
cat(" -", basename(ward_csv_src), "(", n_ward_rows, "rows)\n")
cat(" -", basename(lga_csv_src), "(", n_lga_rows, "rows)\n")
cat(" -", basename(strata_csv_dest), "(", nrow(strata_level), "rows, extracted from the impact workbook's 'Strata Level' sheet)\n")
for (f in shp_files_src) cat(" -", basename(f), "\n")
cat("Wrote", file.path(DEST_DIR, "_accessibility_version.txt"), "\n")

# ---- repair + precompute the ward-portion geometry dashboard_app/global.R
# actually reads (see header comment above for why this step exists here) --

# Mirrors dashboard_app/global.R's own reduce_coord_precision() exactly
# (duplicated rather than shared, same spirit as read_excel_robust() above
# — prep scripts here run standalone, not sourced by the app).
reduce_coord_precision <- function(sf_obj, digits = 4) {
  tmp <- tempfile(fileext = ".geojson")
  on.exit(unlink(tmp))
  st_write(sf_obj, tmp, quiet = TRUE, layer_options = paste0("COORDINATE_PRECISION=", digits))
  st_read(tmp, quiet = TRUE)
}

# Repairs self-intersections/degenerate geometry that reduce_coord_precision()
# introduces specifically in this layer (see header comment). st_make_valid()
# alone isn't enough on badly-degenerate input — it can turn a row into a
# GEOMETRYCOLLECTION mixing polygon/line/point fragments, which Leaflet's
# addPolygons() can't consume at all — so only those GEOMETRYCOLLECTION rows
# get the extract-and-reunion treatment below; every clean POLYGON/
# MULTIPOLYGON row st_make_valid() already fixed on its own is left alone.
repair_accessibility_geometry <- function(sf_obj) {
  # s2 (sf's default spherical engine for lon/lat data) enforces strict
  # topology and throws "Edge X crosses edge Y" on this kind of
  # near-degenerate input rather than resolving it (found via "Garkida"
  # ward, Hawul LGA). GEOS (s2 off) is the older, more tolerant engine and
  # snap-fixes it instead — fine here since this only runs once, on
  # already-imprecise (rounded-to-4-decimals) polygons.
  s2_was_on <- sf_use_s2()
  sf_use_s2(FALSE)
  on.exit(sf_use_s2(s2_was_on), add = TRUE)

  fixed <- st_make_valid(sf_obj)
  is_gc <- st_geometry_type(fixed) == "GEOMETRYCOLLECTION"
  geoms <- st_geometry(fixed)
  for (i in which(is_gc)) {
    extracted <- suppressWarnings(st_collection_extract(geoms[i], "POLYGON"))
    if (length(extracted) > 0 && !all(st_is_empty(extracted))) {
      # st_union() (not st_combine()): extracted fragments from the same
      # GEOMETRYCOLLECTION can overlap each other once pulled out on their
      # own — st_combine() just concatenates without resolving that,
      # st_union() dissolves the overlap into one clean polygon.
      geoms[i] <- st_make_valid(st_union(extracted))
    } else {
      geoms[i] <- st_polygon()
    }
  }
  st_geometry(fixed) <- geoms
  fixed[!st_is_empty(fixed) & st_is_valid(fixed), ]
}

repaired_sf <- st_read(shp_dest <- file.path(DEST_DIR, basename(shp_src)), quiet = TRUE) %>%
  st_transform(4326) %>%
  reduce_coord_precision() %>%
  repair_accessibility_geometry()

repaired_dest <- file.path(DEST_DIR, "accessible_area_lga_ward_portions_repaired.gpkg")
st_write(repaired_sf, repaired_dest, delete_dsn = TRUE, quiet = TRUE)
cat(
  "Wrote", repaired_dest, "(", nrow(repaired_sf), "valid rows,",
  sum(!st_is_valid(repaired_sf)), "invalid,", sum(st_is_empty(repaired_sf)), "empty )\n"
)
