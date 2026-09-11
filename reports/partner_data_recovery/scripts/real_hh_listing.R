# ==============================================================================
# Real per-cluster IDP household-listing pool, from the actual HH Listing
# RandomSelect KoBo tool's export (2026-09-03, per Jack: "here are the HH
# listing numbers downloaded from the tool - use this to fill and update
# all workbooks accordingly"). Replaces the earlier proxy ceiling in
# build_idp_listing_duplicates_data.R (max(households_in_cluster,
# target_households, max observed listing number in MSNA submissions)) -
# that was a stand-in for exactly this data, used only because this
# project had never had access to it before today.
#
# Source: cleaning/MSNA_Data_Cleaning/Kobo Downloads/hh_listing_tool/
# hh_listing.xlsx - one row per LISTING SUBMISSION (main sheet), one row
# per LISTED HOUSEHOLD (hd sheet, a repeat group, joined via
# hd$`_submission__uuid` == main$`_uuid` - confirmed 100% match, 0 orphans).
#
# Two real complications in the raw data, resolved per Jack's explicit
# calls (2026-09-03):
#
# 1. MANY clusters were listed more than once (up to 12 submissions for
#    one cluster) - checked the timing pattern directly: hh_listed_count
#    grows monotonically across re-submissions for the same cluster (e.g.
#    idp_NG002001_11: 24 -> 30 -> 30 -> 42 -> 42 across 5 submissions over
#    4 days), consistent with genuine progressive re-listing, not
#    conflicting parallel attempts. Rule: take the MOST RECENT submission
#    per cluster (by `_submission_time`), skipping any submission with a
#    blank primary_list (an incomplete attempt) in favour of an earlier
#    complete one if needed.
#
# 2. hh_listed_count itself isn't always trustworthy - two huge camps
#    (Abagena Camp, International Market, population estimates 1,236/2,663)
#    both show hh_listed_count exactly 1000, an obvious form cap, not a
#    real count. Sidestepped entirely by NOT using hh_listed_count or the
#    raw per-household `dn` values as the ceiling at all - instead using
#    primary_list + reserve_list (below), which are bounded by the design's
#    own n_total_to_draw parameter regardless of how large the underlying
#    population/listing is.
#
# What "available" actually means here (per Jack): the pool a partner could
# legitimately have meant when correcting a mis-recorded listing number is
# the set of households that were actually DRAWN into the sample - primary
# AND reserve together, not just the household that happened to fall in
# the primary draw, since a genuinely-collected interview could be from
# either. primary_list/reserve_list are space-separated integers on the
# main sheet, already the exact numbers a partner's own listing/draw
# produced - merged, de-duplicated, and sorted numerically.
#
# compute_real_avail_pools() returns a tibble: cluster_id (idp_NG... format,
# matches this project's own convention directly - confirmed cluster_select
# needs no name-mapping), drawn_pool (list-column of sorted integers, the
# primary+reserve union for that cluster's latest usable submission),
# has_real_listing (TRUE/FALSE - whether this cluster appears in the tool's
# export at all; FALSE is the live signal for "genuinely no listing exists
# yet", replacing the earlier proxy's stale 2026-08-30 deletion-log
# snapshot).
# ==============================================================================
suppressPackageStartupMessages({library(readxl); library(dplyr); library(stringr); library(purrr)})

HH_LISTING_PATH <- "cleaning/MSNA_Data_Cleaning/Kobo Downloads/hh_listing_tool/hh_listing.xlsx"

parse_number_list <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) return(integer(0))
  as.integer(str_split(trimws(x), "\\s+")[[1]])
}

compute_real_avail_pools <- function(path = HH_LISTING_PATH) {
  main <- read_excel(path, sheet = "NGA MSNA 2026 - HH Listing &...", guess_max = 2000)

  usable <- main %>%
    filter(!is.na(cluster_select), !is.na(primary_list)) %>%
    group_by(cluster_select) %>%
    slice_max(`_submission_time`, n = 1, with_ties = FALSE) %>%
    ungroup()

  pools <- usable %>%
    mutate(
      drawn_pool = map2(primary_list, reserve_list, function(p, r) {
        sort(unique(c(parse_number_list(p), parse_number_list(r))))
      })
    ) %>%
    transmute(cluster_id = cluster_select, drawn_pool, has_real_listing = TRUE)

  cat(sprintf(
    "compute_real_avail_pools(): %d clusters with a usable listing submission (of %d distinct clusters seen, %d total submissions in the file)\n",
    nrow(pools), n_distinct(main$cluster_select), nrow(main)
  ))
  pools
}

# Final per-cluster available numbers for the recovery-workbook dropdown:
# the real drawn pool (if this cluster has one) minus whatever's already
# claimed by an existing MSNA interview in that cluster - falls back to
# 1:target_households (Jack's explicit fallback rule, 2026-09-03) only
# when the cluster has no usable listing submission at all.
resolve_avail_list <- function(cluster_id, target_households, claimed, pools) {
  pool_row <- pools[pools$cluster_id == cluster_id, ]
  base_pool <- if (nrow(pool_row) == 1) pool_row$drawn_pool[[1]] else seq_len(target_households)
  setdiff(base_pool, claimed)
}
