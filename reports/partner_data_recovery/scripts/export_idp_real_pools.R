# ==============================================================================
# Exports real_hh_listing.R's compute_real_avail_pools() to a CSV so the
# Python side (verify_data_recovery_response.py) can validate a partner's
# CONFIRMED Listing Number against the REAL drawn household pool (primary +
# reserve list from the actual HH Listing RandomSelect KoBo tool), not
# against "Total Numbers Available in Cluster" (a COUNT of remaining open
# slots, never a valid upper bound to compare a real listing number
# against - see verify_data_recovery_response.py's header for the bug this
# replaces, found 2026-09-06 reviewing DRC/ACF/FACT's returned workbooks:
# every one of DRC's confirmed numbers turned out to be a genuine real
# match despite "exceeding" the count-based check).
#
# One row per (cluster_id, real drawn-pool number) - not one row per
# cluster with a packed list - so the Python side can do a plain row
# lookup instead of parsing a delimited sub-field.
#
# Usage: Rscript reports/partner_data_recovery/scripts/export_idp_real_pools.R
# Re-run whenever cleaning/MSNA_Data_Cleaning/Kobo Downloads/hh_listing_tool/
# hh_listing.xlsx is refreshed - this file is a snapshot, not auto-synced.
# ==============================================================================
suppressPackageStartupMessages({library(readr); library(dplyr); library(tidyr)})

SCRIPTS_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring/reports/partner_data_recovery/scripts"
source(file.path(SCRIPTS_DIR, "real_hh_listing.R"))

pools <- compute_real_avail_pools()

out <- pools %>%
  select(cluster_id, drawn_pool) %>%
  unnest(drawn_pool) %>%
  rename(listing_number = drawn_pool) %>%
  arrange(cluster_id, listing_number)

out_path <- file.path(SCRIPTS_DIR, "idp_real_listing_pools.csv")
write_csv(out, out_path)
cat(sprintf("export_idp_real_pools(): wrote %d row(s) (%d clusters) to %s\n",
            nrow(out), n_distinct(out$cluster_id), out_path))
