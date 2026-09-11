# One-time prep: filter the GRID3 ward boundary layer down to our 11
# fielding states, for use as a reference boundary layer on the Coverage
# Map (outline only, no data join — same role as the admin1 state outline
# layer already on the map).
#
# GRID3 (not the COD admin3 dataset also in 1_sampling/input_data) is used
# deliberately: it's the same ward source the sampling frame itself uses
# for `adm3_name`/`adm3_pcode` (`admin3_source == "GRID3"` for every row —
# see NGA_MSNA_2026_stage2_sampling_frame_v5_WORKING.csv) — the COD admin3
# dataset uses a different delineation/pcode scheme entirely and would not
# match the frame's own ward attribution. State/LGA names match exactly
# (verified directly, zero mismatches), so no reconciliation needed here.
#
# Output: input_data/boundaries/nga_wards_grid3.gpkg

suppressPackageStartupMessages({
  library(sf)
  library(readr)
  library(dplyr)
})

# FIX 2026-09-11: was hardcoded to "_v5_", which no longer exists (current:
# v7) - would have failed outright the next time this one-time prep script
# was rerun. See scripts/shared/latest_frame_file.R for why this is now
# resolved dynamically instead of just bumping the number again.
source("scripts/shared/latest_frame_file.R")
strata_frame <- read_csv(
  latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "WORKING"),
  show_col_types = FALSE
)
our_states <- unique(strata_frame$adm1_name)

wards <- st_read(
  "../1_sampling/input_data/boundaries/GRID3_NGA_Ward_Boundaries_v1/grid3_nga_boundary_vaccwards.shp",
  quiet = TRUE
) %>%
  filter(statename %in% our_states) %>%
  select(wardname, wardcode, lganame, lgacode, statename, statecode)

cat("Filtered to", nrow(wards), "wards across", length(our_states), "states.\n")

st_write(wards, "input_data/boundaries/nga_wards_grid3.gpkg", delete_dsn = TRUE, quiet = TRUE)
cat("Done.\n")
