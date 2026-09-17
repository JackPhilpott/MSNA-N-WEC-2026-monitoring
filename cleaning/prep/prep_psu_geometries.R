# One-time prep: build the hex/site geometries for every currently-covered
# PSU, reproject to WGS84, and split by geometry type: Non-IDP PSU =
# hexagon polygons, IDP PSU = DTM site points (IDP SSU is the site's own
# GPS point directly, no hexagon boundary).
#
# Output: input_data/boundaries/psu/psu_hexagons_non_idp.gpkg (polygons)
#         input_data/boundaries/psu/psu_sites_idp.gpkg (points)
#         input_data/boundaries/psu/psu_frame_meta.rds (generated-at stamp)
#
# 2026-08-21: hardened ahead of an expected resampling event that will
# replace the geometry source this reads from. The overlap-rate check
# below writes to data/SANITY_WARNINGS.txt (same file prep_real_
# submissions.R uses) if too few of the current covered cluster_ids are
# found in the combined geometry source, and psu_frame_meta.rds records
# when/from-what this was generated — there was previously no way to tell
# a frame swap had happened at all from the output files themselves.
#
# 2026-09-02: rebuilt per 1_sampling's own diagnosis of three compounding
# issues in how this script (and global.R's cluster_targets lookup)
# sourced clusters, after Jack raised incorrect achieved-vs-target totals
# across clusters/LGAs/partners:
#
#   ISSUE 1 (global.R, not this file): stage2_frame_v5_full there was
#   loaded with no coverage_status/exclusion_reason filter, mixing ~42k
#   never-covered and ~2.3k permanently-excluded rows in with the real
#   covered ones. Fixed separately in global.R alongside this file.
#
#   ISSUE 2 (the real gap, this script): geometry used to come ONLY from
#   a frozen 2026-08-06 archive that predates this week's entire
#   resampling round — the ~375 new/supplementary clusters from this
#   round's partner batches don't just have stale values there, their
#   rows are COMPLETELY ABSENT. Every cluster/LGA/partner total involving
#   one of them silently undercounted, because mod_map.R's cluster_
#   status() and everything downstream of psu_hexagons_sf/psu_sites_sf
#   only ever sees what's in these two files. Fixed by unioning the
#   Aug-6 archive with every partner batch's own new-cluster geometry
#   (resampling/output/resample_runs/*/*/new_clusters_{non_idp,idp}.gpkg)
#   before filtering to what's actually covered -- see
#   build_combined_geometry_source() below.
#
#   ISSUE 3 (this script, same root cause as Issue 1): the cluster_id
#   universe here used to come from WORKING (a deliberately SHRINKING
#   candidate pool that drops a cluster's rows once fully achieved or its
#   ward goes inaccessible — expected there, since WORKING means "still
#   needs sampling"). Using it here meant a fully-achieved or newly-
#   inaccessible cluster dropped out of the MAP GEOMETRY entirely, not
#   just its target/achieved figures. Fixed by sourcing the cluster
#   universe from FULL (which never drops a row) filtered to
#   coverage_status == "covered" & exclusion_reason == "none" instead —
#   the same WORKING-vs-FULL distinction 1_sampling's own accessibility
#   scripts were fixed for overnight, for the identical reason.
#
# target_households is deliberately NOT carried through the geometry
# union (the archive and new-cluster files each have their own copy, and
# keeping two copies in sync is exactly the kind of drift that caused
# Issue 1) — it's dropped from the geometry layer entirely and re-joined
# fresh from the FULL frame (post Issue-1's filter) at the end, so the
# household CSV is the single source of truth for target values and this
# geometry layer is shape-only.

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(readr)
})

source("cleaning/real/sanity_checks.R")

# 2026-09-09: was hardcoded to "_v5_" - same class of bug fixed elsewhere
# this week (global.R's latest_frame_file(), prep_real_submissions.R,
# sanity_checks.R's STRATA_FRAME_FOR_TARGET_CHECK) - just missed here. This
# one crashed outright (no defensive guard) the moment 1_sampling's sync
# archived the old v5 files away, blocking this script entirely - found
# while re-running it to refresh 8 strata's stale PSU geometry (Dandume,
# Faskari, Matazu, Musawa, Sabuwa - real, currently-covered clusters that
# were invisible to target_sample_current purely because this cache
# predated their reinstatement into the frame).
# 2026-09-14: consolidated into scripts/shared/latest_frame_file.R (this
# script's own copy was byte-identical) - one less place to miss next time
# the frame version bumps.
source("scripts/shared/latest_frame_file.R")

# ---- ISSUE 1 & 3: FULL frame, filtered to the same "genuinely in scope"
# definition (covered & not excluded), replaces WORKING as both the
# cluster_id universe and the target_households source. ----------------
household_frame <- read_csv(
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"),
  show_col_types = FALSE, col_types = cols(.default = "c")
) %>%
  filter(coverage_status == "covered", exclusion_reason == "none")
working_cluster_ids <- unique(household_frame$cluster_id)

cluster_target_lookup <- household_frame %>%
  distinct(cluster_id, .keep_all = TRUE) %>%
  mutate(target_households = as.numeric(target_households)) %>%
  select(cluster_id, target_households)

# modal (most common) ward per cluster — hexagons can span >1 ward in
# principle, but in practice almost always sit within one
modal_ward_by_cluster <- household_frame %>%
  filter(!is.na(adm3_name), adm3_name != "NA") %>%
  count(cluster_id, adm3_pcode, adm3_name, sort = TRUE) %>%
  distinct(cluster_id, .keep_all = TRUE) %>%
  select(cluster_id, adm3_pcode, adm3_name)

DESIGN_FRAME_PATH <- "../1_sampling/_archive/2026-08-06_design_frame_post_nw_targeted_resample/selected_clusters_final.rds"
if (!file.exists(DESIGN_FRAME_PATH)) {
  stop(
    "Design-frame archive not found at: ", DESIGN_FRAME_PATH, " — this path is a manually dated ",
    "snapshot (see header note). If 1_sampling has produced a new design frame, update DESIGN_FRAME_PATH ",
    "in this script to point at it."
  )
}
cat("Design frame source:", normalizePath(DESIGN_FRAME_PATH), "\n")
cat("Design frame file last modified:", format(file.info(DESIGN_FRAME_PATH)$mtime), "\n")

design_frame_raw <- readRDS(DESIGN_FRAME_PATH)

# ---- ISSUE 2: union archive + every partner batch's new-cluster geometry
GEOM_KEEP_COLS <- c(
  "cluster_id", "strata_id", "pop_type", "region",
  "adm1_name", "adm1_pcode", "adm2_name", "adm2_pcode",
  "selection_type", "iom_site_name", "iom_site_type", "idp_population_category"
)

# Normalises one geometry source to a common shape before combining:
# renames the "geom" column some new-cluster files use to "geometry"
# (the archive's own name), and keeps only the columns actually needed
# downstream — extra columns some sources carry (accessible_status,
# .source, .old_cluster_id, below_target_cluster, ...) are silently
# dropped rather than erroring, per 1_sampling's own note that they don't
# match 1:1 across sources. target_households is deliberately excluded
# here (see header note) even though every source has its own copy.
standardize_geom_source <- function(x) {
  if (!("geometry" %in% names(x)) && "geom" %in% names(x)) {
    x <- rename(x, geometry = geom)
    st_geometry(x) <- "geometry"
  }
  present <- intersect(GEOM_KEEP_COLS, names(x))
  x[, c(present, "geometry")]
}

archive_std <- standardize_geom_source(design_frame_raw)

# 2026-09-03: broadened from "new_clusters_*.gpkg" (requires an underscore
# suffix, e.g. new_clusters_non_idp.gpkg) - 1_sampling's Non-IDP
# supplementary-draw mechanism (draw_supplementary_clusters_batch.R and its
# per-partner variants) has written a plain, unsuffixed "new_clusters.gpkg"
# since at least 2026-09-02, which the old pattern silently never matched.
# Found while investigating why the Mobbar/FHI 360 batch's geometry was
# missing tonight - checked directly and this also silently dropped FACT's,
# INTERSOS's, and ZOA's own 2026-09-02 batches (each has both an unsuffixed
# new_clusters.gpkg for Non-IDP and a separate new_clusters_idp.gpkg) - a
# real, pre-existing gap affecting 4 partners, not just tonight's change.
# standardize_geom_source() below doesn't depend on the filename for pop_type
# (that comes from the geometry itself, polygon vs point), so broadening
# this is safe - it can only ever pick up MORE real cluster geometry, never
# misclassify anything.
NEW_CLUSTER_FILES <- Sys.glob("../1_sampling/resampling/output/resample_runs/*/*/new_clusters*.gpkg")
cat("New-cluster geometry files found:", length(NEW_CLUSTER_FILES), "\n")

new_cluster_parts <- lapply(NEW_CLUSTER_FILES, function(p) {
  x <- st_read(p, quiet = TRUE)
  if (nrow(x) == 0) {
    cat("  (skipping, 0 rows):", sub(".*resample_runs/", "", p), "\n")
    return(NULL)
  }
  # CRS: the new-cluster files' own CRS commonly prints as the unnamed
  # "Yoff / UTM zone 28N" while the archive prints as "EPSG:31028" — these
  # are the same projection (confirmed directly, both resolve to EPSG
  # 31028), just labeled differently by GDAL depending on how each file
  # was written. Reprojecting is only actually triggered if a future
  # batch's file genuinely differs.
  if (!is.na(st_crs(x)$epsg) && !is.na(st_crs(archive_std)$epsg) && st_crs(x)$epsg != st_crs(archive_std)$epsg) {
    cat("  Reprojecting (CRS differs from archive):", sub(".*resample_runs/", "", p), "\n")
    x <- st_transform(x, st_crs(archive_std))
  }
  standardize_geom_source(x)
})
n_new_files_with_rows <- sum(!sapply(new_cluster_parts, is.null))
new_cluster_parts <- new_cluster_parts[!sapply(new_cluster_parts, is.null)]
cat(
  "New-cluster files with at least 1 row:", n_new_files_with_rows, "of", length(NEW_CLUSTER_FILES),
  "—", sum(vapply(new_cluster_parts, nrow, integer(1))), "new-cluster rows total\n"
)

# 2026-09-04: per-batch completeness check, added after finding 29 covered
# FACT site-level IDP clusters with no geometry at all — the overlap-rate
# check below (design_overlap_rate < 0.98) is an aggregate signal and only
# fires once enough clusters are missing across the whole frame; it doesn't
# say WHICH batch is the culprit, and a smaller gap (as this one initially
# was, before more clusters accumulated in the same untouched batches) can
# sit under the threshold for a while. This check instead looks at each
# partner/date batch directory directly: if it has a new_clusters/new_
# households CSV (real evidence a draw happened) but no matching
# new_clusters*.gpkg, that's exactly the "CSV written, geometry never
# generated" failure mode from both the Mobbar and FACT sitelevel gaps —
# flag it explicitly, per-directory, rather than relying on the aggregate
# rate to eventually notice. Classifies each CSV/gpkg by whether "idp"
# appears in the filename (case-insensitive) rather than matching exact
# suffix conventions (new_clusters.csv/_non_idp.csv/_idp.csv/_idp_sitelevel.csv
# all coexist across existing batches) — this only needs to durably
# distinguish "an IDP draw's geometry" from "a Non-IDP draw's geometry",
# not reproduce every naming variant exactly.
# 2026-09-17: real false-positive found live (2 nights running) - a batch
# script upstream routinely writes BOTH a Non-IDP and an "*_idp*.csv" file
# per draw regardless of whether that pop_type was actually drawn, leaving
# a header-only, 0-row placeholder for the one that wasn't (confirmed
# directly: every one of 9 "(IDP)"-flagged batches that night - CARE/FACT/
# FHI 360/IMC/Malteser/NRC/Solidarités's 2026-09-14_comprehensive plus
# tonight's two _multi_partner_batches - had a 0-row new_clusters_idp_
# sitelevel.csv sitting next to real Non-IDP rows that already had matching
# geometry). Checking filename pattern alone treats that placeholder as "a
# draw happened", so this warning would false-positive on the same
# batches forever. csv_nonempty() gates on real data rows (cheap: reads at
# most 2 lines, no full parse) before a CSV counts as evidence anything
# needs geometry.
csv_nonempty <- function(path) length(readLines(path, n = 2, warn = FALSE)) > 1

BATCH_DIRS <- list.dirs("../1_sampling/resampling/output/resample_runs", recursive = FALSE) %>%
  lapply(function(d) list.dirs(d, recursive = FALSE)) %>%
  unlist()
incomplete_batches <- character(0)
for (d in BATCH_DIRS) {
  csvs_all <- list.files(d, pattern = "^new_(clusters|households).*\\.csv$", ignore.case = TRUE, full.names = FALSE)
  if (length(csvs_all) == 0) next
  csvs <- csvs_all[vapply(file.path(d, csvs_all), csv_nonempty, logical(1))]
  if (length(csvs) == 0) next
  gpkgs <- list.files(d, pattern = "^new_clusters.*\\.gpkg$", ignore.case = TRUE, full.names = FALSE)
  csv_has_idp <- any(grepl("idp", csvs, ignore.case = TRUE))
  csv_has_non_idp <- any(!grepl("idp", csvs, ignore.case = TRUE))
  gpkg_has_idp <- any(grepl("idp", gpkgs, ignore.case = TRUE))
  gpkg_has_non_idp <- any(!grepl("idp", gpkgs, ignore.case = TRUE))
  missing_kinds <- c(
    if (csv_has_idp && !gpkg_has_idp) "IDP",
    if (csv_has_non_idp && !gpkg_has_non_idp) "Non-IDP"
  )
  if (length(missing_kinds) > 0) {
    incomplete_batches <- c(incomplete_batches, paste0(sub(".*resample_runs/", "", d), " (", paste(missing_kinds, collapse = " + "), ")"))
  }
}
if (length(incomplete_batches) > 0) {
  msg <- paste0(
    "PSU GEOMETRY COMPLETENESS: ", length(incomplete_batches), " resample_runs batch director",
    if (length(incomplete_batches) == 1) "y has" else "ies have",
    " a new_clusters/new_households CSV but no matching new_clusters*.gpkg — this batch's clusters are ",
    "invisible on the Coverage Map (silently dropped by the geometry union below) even if covered. ",
    "Affected: ", paste(incomplete_batches, collapse = "; "), ". Backfill via a standalone geometry-only ",
    "rebuild from the batch's own CSV (no redraw needed) — see 1_sampling's write_mobbar_idp_geometry_gpkg_",
    "2026-09-03.R / backfill_fact_sitelevel_idp_geometry_2026-09-04.R for the pattern."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  write_sanity_warnings(msg, source_label = "prep_psu_geometries.R")
} else {
  cat("Per-batch geometry completeness check: all", length(BATCH_DIRS), "batch directories with a new-cluster CSV have a matching gpkg.\n")
}

# archive first: if a cluster_id genuinely appears in both (shouldn't
# happen — new-cluster files mint fresh ids, tracked via their own
# .old_cluster_id lineage column — but guarded regardless), the archive's
# row wins rather than erroring or silently duplicating the cluster.
combined_geometry_source <- bind_rows(archive_std, new_cluster_parts) %>%
  distinct(cluster_id, .keep_all = TRUE)
cat("Combined geometry source:", nrow(combined_geometry_source), "clusters (",
    nrow(archive_std), "from the Aug-6 archive +", sum(vapply(new_cluster_parts, nrow, integer(1))),
    "from new-cluster batches, before de-dup)\n")

design_overlap_n <- sum(working_cluster_ids %in% combined_geometry_source$cluster_id)
design_overlap_rate <- design_overlap_n / length(working_cluster_ids)
cat(
  "Covered cluster_ids found in the combined geometry source:", design_overlap_n, "of", length(working_cluster_ids),
  sprintf("(%.0f%%)\n", design_overlap_rate * 100)
)
# Threshold tightened 90% -> 98% (2026-09-02): the 91% overlap rate from
# the resampling batches missing here in practice never tripped the old
# 90% threshold despite being a real, material gap (334 clusters) — this
# check needs to be sensitive enough to actually catch that class of issue
# instead of requiring it to be found by hand.
if (design_overlap_rate < 0.98) {
  msg <- paste0(
    "PSU GEOMETRY OVERLAP: only ", sprintf("%.0f%%", design_overlap_rate * 100), " (", design_overlap_n, " of ",
    length(working_cluster_ids), ") of the current covered frame's cluster_ids were found in the combined ",
    "archive + new-cluster-batch geometry source — either a resampling event added clusters not yet reflected ",
    "in resample_runs/, or a new partner batch's file needs adding. Coverage Map geometry/targets for the ",
    "missing clusters will be silently absent."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  write_sanity_warnings(msg, source_label = "prep_psu_geometries.R")
}

sc <- combined_geometry_source %>%
  filter(cluster_id %in% working_cluster_ids) %>%
  st_transform(4326) %>%
  left_join(modal_ward_by_cluster, by = "cluster_id") %>%
  left_join(cluster_target_lookup, by = "cluster_id")

cat("Filtered to", nrow(sc), "clusters (of", length(working_cluster_ids), "covered).\n")
cat("Clusters with a resolved ward:", sum(!is.na(sc$adm3_name)), "\n")
cat("Clusters with a resolved target_households:", sum(!is.na(sc$target_households)), "\n")

geom_types <- st_geometry_type(sc)

hex_polygons <- sc[geom_types %in% c("POLYGON", "MULTIPOLYGON"), ] %>%
  select(cluster_id, strata_id, pop_type, region, adm1_name, adm1_pcode, adm2_name, adm2_pcode,
         adm3_name, adm3_pcode, target_households, selection_type)

site_points <- sc[geom_types == "POINT", ] %>%
  select(cluster_id, strata_id, pop_type, region, adm1_name, adm1_pcode, adm2_name, adm2_pcode,
         adm3_name, adm3_pcode, target_households, iom_site_name, iom_site_type, idp_population_category)

cat("Non-IDP hexagon polygons:", nrow(hex_polygons), "\n")
cat("IDP site points:", nrow(site_points), "\n")
cat("Dropped (no/other geometry):", nrow(sc) - nrow(hex_polygons) - nrow(site_points), "\n")

st_write(hex_polygons, "input_data/boundaries/psu/psu_hexagons_non_idp.gpkg", delete_dsn = TRUE, quiet = TRUE)
st_write(site_points, "input_data/boundaries/psu/psu_sites_idp.gpkg", delete_dsn = TRUE, quiet = TRUE)

# Mirrors real_meta.rds's shape/purpose — without this there was no way to
# tell, from the output files alone, when this was last regenerated or
# from what source, which matters once the design frame stops being static.
saveRDS(
  list(
    generated_at = Sys.time(),
    design_frame_path = normalizePath(DESIGN_FRAME_PATH),
    design_frame_modified = file.info(DESIGN_FRAME_PATH)$mtime,
    new_cluster_files_used = length(new_cluster_parts),
    n_working_cluster_ids = length(working_cluster_ids),
    n_matched_in_design_frame = design_overlap_n,
    n_hexagons = nrow(hex_polygons),
    n_sites = nrow(site_points)
  ),
  "input_data/boundaries/psu/psu_frame_meta.rds"
)

cat("Done.\n")
