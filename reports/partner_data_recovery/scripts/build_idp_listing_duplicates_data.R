# ==============================================================================
# Corrected data-prep for the "IDP Listing Duplicates" sheet used in partner
# data recovery workbooks (2_monitoring/reports/partner_data_recovery/outputs/).
# Written 2026-09-03 believing the original 2026-08-30 workbook-builder
# script no longer existed on disk (only its .xlsx output did) - rebuilt
# from first principles against the actual raw KoBo export, per the same
# logic prep_real_submissions.R already uses for dup_key/matched_cluster_id,
# rather than reverse-engineered purely from the old output file. The
# original WAS since found and rescued into ../scripts/full_batch_
# pipeline.R + build_workbook_fn.R (it had only been sitting in an
# untracked Claude scratchpad, not actually gone) - confirmed its ceiling
# logic is exactly the bug described below
# (`setdiff(seq_len(target_hh), claimed)`, build_workbook_fn.R line ~132),
# so this rebuild's understanding of the bug is verified correct against
# the real original, not just plausible. Kept as the standalone, CURRENT,
# runnable fix regardless - full_batch_pipeline.R itself is a frozen
# snapshot (see its own header), not something to run again as-is.
#
# TWO BUGS FIXED HERE, found 2026-09-03 by Jack inspecting the ZOA copy:
#
# 1. "Total Numbers Available in Cluster" (and the CONFIRMED Listing Number
#    dropdown built from it) was capped at target_households. Confirmed
#    directly: idp_NG034022_1's sheet showed total_available=16 with
#    target_households=48 and every "unclaimed" value <= 47 - i.e. the pool
#    really was {1..48} minus already-claimed, not the real household
#    listing size. This is wrong per the recovery workbook's own README
#    ("a dropdown limited to the households/listing numbers still available
#    in that same cluster") and per the actual field methodology - Tier 1
#    enumerators list EVERY household the site's head of area recognises as
#    belonging there, a number with no defined relationship to
#    target_households (a downstream SAMPLE size, not a population count).
#    The true field-submitted listing size (`hh_listed_count`, captured by
#    the separate NGA_MSNA_2026_HH_Listing_RandomSelect.xlsx KoBo tool -
#    see ../../../../4_kobotool/) is NOT available anywhere in this
#    project's pipeline - that tool's submissions have never been pulled
#    into 2_monitoring. In its absence, this script uses the best available
#    real evidence instead:
#       ceiling = max(households_in_cluster [DTM population estimate, from
#                     the sampling frame],
#                     target_households [guaranteed floor - the KoBo
#                     listing tool's own constraint requires
#                     hh_listed_count >= target_households],
#                     max(idp_hh_number_from_listing) actually observed in
#                     the raw KoBo export for that cluster - concrete proof
#                     the real listing was at least this large)
#    Checked directly against real data: for idp_NG034022_1, even
#    households_in_cluster (61) would have been too low - the real max
#    observed listing number is 74. Only the 3-way max catches this.
#
# 2. "Nearest Unclaimed Numbers" (a numeric-proximity suggestion column,
#    e.g. offering "6,8,10" as alternatives to a disputed "9") is dropped
#    entirely per Jack: picking the NEAREST number to what was originally
#    (possibly wrongly) recorded isn't a correction, it re-introduces a
#    non-random selection right where the design specifically relies on
#    the KoBo tool's own RNG. The CONFIRMED Listing Number column/dropdown
#    itself stays - only this suggestion column is removed.
#
# THIRD RULE ADDED 2026-09-03 (Jack): a cluster whose household listing is
# itself missing entirely has no real list for households_in_cluster/
# max_observed_listing to meaningfully reflect - so for those clusters
# specifically, drop straight to target_households alone rather than the
# 3-way max above. See missing_listing_clusters below for the (currently
# non-live, 2026-08-30-snapshot) signal this uses.
#
# BUG FOUND AND FIXED 2026-09-03 (later same day, while assessing IMC's
# returned workbook): the `claimed[[1]] %||% integer(0)` call below was
# wrong - inside rowwise(), a list-column referenced by name is ALREADY
# the unwrapped per-row vector, so `claimed[[1]]` was taking only the
# FIRST already-claimed number in the cluster, not the whole claimed set.
# Confirmed via an isolated dplyr test (rowwise() + list-column really
# does auto-unwrap - `claimed[[1]]` after that re-indexes into the
# unwrapped vector) and against a real saved file: IMC's rebuilt workbook
# showed idp_NG008007_4 as having 95 numbers available when the correct
# figure (all 41 nationally-claimed numbers excluded, not just one) is
# 55. This silently inflated "Total Numbers Available"/the CONFIRMED
# dropdown for every multi-claim cluster in every workbook rebuilt today
# via rebuild_idp_listing_sheets.R (which has the identical line) - up to
# and including ZOA and DRC, both already sent to partners before this
# was caught. Fixed by using the already-unwrapped `claimed` directly.
#
# Usage:
#   Rscript build_idp_listing_duplicates_data.R <ORG_ID> <OUT_CSV> [--full]
#     ORG_ID   - raw org_id code as it appears in the KoBo export (lowercase,
#                e.g. "zoa", "fact") - see distinct(main$org_id).
#     OUT_CSV  - where to write the row-level data for the xlsx builder.
#     --full   - include EVERY IDP-listing row for this partner's clusters,
#                with an added Is Duplicate (Yes/No) column, instead of only
#                rows that collide with another row on (cluster, listing
#                number) - see header note on why ZOA gets this mode and
#                nobody else does yet.
#
# Source data / joins mirror prep_real_submissions.R exactly (NG037 repair,
# dup_key construction, admin lookups) - see that script's own header for
# the full provenance/caveats of each piece reused here.
# ==============================================================================
suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(readr); library(stringr)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("Usage: Rscript build_idp_listing_duplicates_data.R <ORG_ID> <OUT_CSV> [--full]")
ORG_ID <- tolower(args[1])
OUT_CSV <- args[2]
FULL_MODE <- "--full" %in% args

MONITORING_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring"
setwd(MONITORING_DIR)
CLEANING_OUTPUT_DIR <- "cleaning/MSNA_Data_Cleaning/output"

# ---- 1. locate + read the most recent anonymised export (same tie-break as prep_real_submissions.R) ----
anon_files <- list.files(file.path(CLEANING_OUTPUT_DIR, "anonymised_data"), pattern = "\\.xlsx$", full.names = TRUE)
stopifnot(length(anon_files) > 0)
anon_dates <- as.Date(str_extract(basename(anon_files), "\\d{4}-\\d{2}-\\d{2}"))
same_day_candidates <- anon_files[anon_dates == max(anon_dates)]
latest_file <- same_day_candidates[which.max(file.info(same_day_candidates)$mtime)]
cat("Using anonymised export:", basename(latest_file), "\n")
main <- read_excel(latest_file, sheet = "main", guess_max = 5000)

# ---- 2. NG037 tool-bug repair (unchanged from prep_real_submissions.R) ----
ni_cols <- grep("^sample_point_NG\\d+_non_idp$", names(main), value = TRUE)
idp_cols <- grep("^idp_cluster_NG\\d+$", names(main), value = TRUE)
first_non_na <- function(df) apply(df, 1, function(r) { r <- r[!is.na(r)]; if (length(r)) r[1] else NA_character_ })
main <- main %>%
  mutate(
    rebuilt_idp = first_non_na(across(all_of(idp_cols))),
    idp_cluster_id_repaired = coalesce(as.character(idp_cluster_id), rebuilt_idp)
  )

# ---- 3. dup_key / dup_n, IDP listing-number rows only (Tier 1) ----
# Computed nationally (not partner-scoped) before filtering, since a dup
# group is defined by (cluster, listing number) and clusters aren't
# partner-exclusive in principle - matches prep_real_submissions.R's own
# ordering (dup detection runs before any partner-specific narrowing).
main <- main %>%
  mutate(dup_key = if_else(
    sample_pop_type_filter == "idp" & !is.na(idp_hh_number_from_listing),
    paste0(idp_cluster_id_repaired, "|listing_", idp_hh_number_from_listing),
    NA_character_
  )) %>%
  group_by(dup_key) %>%
  mutate(dup_n = if_else(is.na(dup_key), 1L, dplyr::n())) %>%
  ungroup()

# ---- 4. admin lookups (same source files as prep_real_submissions.R) ----
# FULL, not WORKING (fixed 2026-09-03 - the read below was still pointed at
# WORKING despite this exact comment already explaining why it shouldn't
# be: a partner's cluster/LGA can be fully achieved or accessibility-
# excluded and drop out of WORKING entirely while still having real
# submissions that need reconciling here - confirmed harmless for ZOA's own
# 3 clusters this run purely by luck (all 3 still had at least one row in
# WORKING), but would silently go NA -> pmax(..., na.rm=TRUE) quietly
# dropping the target_households/households_in_cluster floor entirely -
# for the next partner whose cluster doesn't survive in WORKING. Same class
# of bug as dashboard_app/global.R's household_frame, fixed there 2026-09-02
# for the identical reason.
household_frame <- read_csv(
  "input_data/sampling_frame/NGA_MSNA_2026_stage2_sampling_frame_v5_FULL.csv",
  show_col_types = FALSE, col_types = cols(.default = "c")
)
adm1_lookup <- household_frame %>% distinct(adm1_pcode, adm1_name)
adm2_lookup <- household_frame %>% distinct(adm2_pcode, adm2_name)
admin3_lookup <- read_csv("input_data/MSNA_2026_admin3.csv", show_col_types = FALSE) %>% distinct(name, .keep_all = TRUE)

# Cluster-level target, straight from the frame (FULL, not WORKING - see
# household_frame's own note above) - used only as the fallback ceiling
# below for a cluster with no real listing submission at all.
frame_full <- read_csv(
  "input_data/sampling_frame/NGA_MSNA_2026_stage2_sampling_frame_v5_FULL.csv",
  show_col_types = FALSE, col_types = cols(.default = "c")
) %>%
  distinct(cluster_id, .keep_all = TRUE) %>%
  transmute(cluster_id, target_households = as.integer(target_households))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# Real per-cluster listing pool, from the actual HH Listing RandomSelect
# tool's export (2026-09-03, per Jack - see real_hh_listing.R's own header
# for the full methodology: most-recent-submission-per-cluster,
# primary+reserve union, why that sidesteps the raw hh_listed_count field's
# own data-quality issues). Replaces the earlier max(households_in_cluster,
# target_households, max_observed_listing) proxy entirely - this is real
# data, not a substitute for it. Path is relative to MONITORING_DIR (see
# setwd() above), same directory this script itself lives in.
source("reports/partner_data_recovery/scripts/real_hh_listing.R")
avail_pools <- compute_real_avail_pools()

# "Claimed" = every listing number any IDP interview nationally has already
# recorded for that cluster (dup or not - a disputed number stays off the
# table, the point is finding a DIFFERENT one) - unchanged in spirit from
# the original claimed_by_cluster_all logic.
claimed_by_cluster <- main %>%
  filter(!is.na(idp_hh_number_from_listing)) %>%
  group_by(idp_cluster_id_repaired) %>%
  summarise(claimed = list(unique(idp_hh_number_from_listing)), .groups = "drop")

ceilings <- frame_full %>%
  left_join(claimed_by_cluster, by = c("cluster_id" = "idp_cluster_id_repaired")) %>%
  rowwise() %>%
  mutate(
    avail_list = list(resolve_avail_list(cluster_id, target_households, claimed %||% integer(0), avail_pools)),
    total_available = length(avail_list)
  ) %>%
  ungroup()

# ---- 5. this partner's IDP listing rows ----
partner_rows <- main %>%
  filter(tolower(org_id) == ORG_ID, sample_pop_type_filter == "idp", !is.na(idp_hh_number_from_listing))

if (!FULL_MODE) {
  partner_rows <- partner_rows %>% filter(dup_n > 1)
}

if (nrow(partner_rows) == 0) {
  cat("No qualifying rows for org_id =", ORG_ID, "(full_mode =", FULL_MODE, "). Nothing written.\n")
  quit(save = "no", status = 0)
}

out <- partner_rows %>%
  left_join(adm1_lookup, by = c("admin1" = "adm1_pcode")) %>%
  left_join(adm2_lookup, by = c("admin2" = "adm2_pcode")) %>%
  left_join(admin3_lookup %>% select(name, ward_label = label), by = c("admin3" = "name")) %>%
  left_join(ceilings, by = c("idp_cluster_id_repaired" = "cluster_id")) %>%
  transmute(
    `Interview ID` = uuid,
    `Enumerator ID` = enum_id,
    State = adm1_name,
    LGA = adm2_name,
    Ward = ward_label,
    `Date of Submission` = as.character(as.Date(start)),
    `Cluster/Site ID` = idp_cluster_id_repaired,
    `Listing Number Recorded` = idp_hh_number_from_listing,
    `Total Numbers Available in Cluster` = total_available,
    # Space-separated, the real available numbers themselves (sorted) - not
    # just a count. build_zoa_idp_listing_supplement.py (and any future
    # workbook-builder) should use THIS for the dropdown values, not
    # regenerate a synthetic 1..ceiling range from the count above.
    `Available Numbers` = vapply(avail_list, function(x) paste(x, collapse = " "), character(1)),
    `Is Duplicate (Yes/No)` = if (FULL_MODE) if_else(dup_n > 1, "Yes", "No") else NA_character_,
    `CONFIRMED Listing Number` = NA_integer_,
    `Notes / Explanation` = NA_character_
  ) %>%
  arrange(`Cluster/Site ID`, `Listing Number Recorded`, `Date of Submission`)

if (!FULL_MODE) out <- out %>% select(-`Is Duplicate (Yes/No)`)

write_csv(out, OUT_CSV)
cat(sprintf("Wrote %d row(s) across %d cluster(s) to %s (full_mode=%s)\n",
            nrow(out), n_distinct(out$`Cluster/Site ID`), OUT_CSV, FULL_MODE))
print(as.data.frame(ceilings %>% filter(cluster_id %in% unique(out$`Cluster/Site ID`)) %>%
  mutate(has_real_listing = cluster_id %in% avail_pools$cluster_id) %>%
  select(cluster_id, target_households, has_real_listing, total_available)))
