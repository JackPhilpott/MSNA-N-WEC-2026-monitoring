# Global setup: packages, data loading, shared constants/helpers.
# Sourced once per R process before ui/server run (standard Shiny behaviour
# for a global.R alongside app.R in the same directory).

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(lubridate)
  library(stringr)
  library(leaflet)
  library(sf)
  library(DT)
  library(plotly)
  library(scales)
  library(openxlsx)
  library(ggplot2)
  library(cowplot)
  library(shinyWidgets)
})

# ---- paths ---------------------------------------------------------------
# Locally, this app runs with working directory = dashboard_app/, reading
# its sibling data/ and input_data/ folders one level up. A shinyapps.io/
# Posit Connect deploy only bundles dashboard_app/ itself (not siblings),
# so deploy_dashboard.R (project root) copies both folders IN before
# deploying — this falls back to that bundled copy when the sibling
# folders aren't there (i.e. when actually running deployed, not just
# locally with a coincidentally-missing folder — if neither exists,
# read_csv() below fails with a clear "file not found", same as always).
DATA_DIR <- if (dir.exists("../data")) "../data" else "data"
INPUT_DIR <- if (dir.exists("../input_data")) "../input_data" else "input_data"

# 2026-09-08 rebuild: latest_frame_file() finds the CURRENT version number
# dynamically rather than hardcoding it. Found live during this rebuild: the
# strata/household frame reads below were hardcoded to "_v5_" while
# 1_sampling had already moved to v6 - meaning this app's dashboard_app/
# input_data/ mirror (what actually gets deployed) was still reading v5,
# three versions' worth of resampling batches behind, because nothing
# forces a hardcoded filename to get updated at each version bump. That's
# exactly the class of bug this whole rebuild exists to close - fixing it
# generically here, not just bumping the number to v6 and recreating the
# identical problem at the next bump.
latest_frame_file <- function(prefix, suffix, dir = file.path(INPUT_DIR, "sampling_frame")) {
  pat <- paste0("^", prefix, "_v([0-9]+)_", suffix, "\\.csv$")
  candidates <- list.files(dir, pattern = pat)
  if (length(candidates) == 0) stop(sprintf("latest_frame_file(): no file matching %s_v<N>_%s.csv found in %s", prefix, suffix, dir))
  versions <- as.integer(sub(pat, "\\1", candidates))
  file.path(dir, candidates[which.max(versions)])
}

# ---- feature flags -----------------------------------------------------------
# Analysis menu (Enumerator Performance / Data Integrity Checks / Sample
# Representativeness) hidden from the navbar for the 2026-08-15 go-live —
# there's a lot to review there and focus is on the core tabs first. Code/
# modules untouched, not deleted — flip back to TRUE to bring it back.
SHOW_ANALYSIS_TAB <- FALSE

# ---- fielding window --------------------------------------------------------
# FIELDING_PLANNED_END: confirmed 2026-08-15 as the realistic current
# end-of-collection estimate. FIELDING_START is computed below, once
# submissions_raw is loaded — the first date that actually appears in the
# data, so the date filter/home page can't disagree with what's really there.
FIELDING_PLANNED_END <- as.Date("2026-09-11")

# ---- load data -------------------------------------------------------------

# Real data only (cleaning/real/prep_real_submissions.R) — mock/simulated
# data (previously cleaning/mock/generate_mock_submissions.R, a pre-launch
# stand-in before real submissions existed) was retired 2026-08-21 once
# real data was reliably flowing every day; see README's 2026-08-21 entry.
# Fails loudly and clearly if this hasn't been run yet, rather than
# silently falling back to a mock file that no longer exists.
if (!file.exists(file.path(DATA_DIR, "real_submissions.csv"))) {
  stop(
    "data/real_submissions.csv not found. Run cleaning/real/prep_real_submissions.R ",
    "from the project root first — see that file's header for the daily workflow."
  )
}

# guess_max + explicit col_types for the two GPS columns (2026-08-21,
# found while verifying a deploy): latitude_submitted/longitude_submitted
# are NA for most rows (only populated where GPS was recovered via the
# spatial-duplicate audit — see prep_real_submissions.R's header) and, as
# the file has grown, the real values now first appear well past readr's
# default 1000-row guess sample. Left to guess, readr sees nothing but NA
# in that sample, infers `logical`, and silently turns every real
# coordinate past row ~4084 into NA — confirmed directly (100% NA where
# the source CSV plainly has real decimals). Not just cosmetic:
# find_gps_duplicate_groups() below depends on this column, so it was
# silently checking against zero real coordinates. guess_max scans the
# whole file (cheap at this size) as a general safeguard against the same
# class of mistake on any other sparse column; the explicit col_types
# guarantees these two specifically regardless of guess_max.
submissions_raw <- read_csv(
  file.path(DATA_DIR, "real_submissions.csv"), show_col_types = FALSE,
  guess_max = 100000, col_types = cols(latitude_submitted = col_double(), longitude_submitted = col_double())
) %>%
  mutate(
    submission_date = as.Date(submission_date),
    start_datetime = as_datetime(start_datetime),
    end_datetime = as_datetime(end_datetime)
  )

submissions_meta <- readRDS(file.path(DATA_DIR, "real_meta.rds"))

FIELDING_START <- min(submissions_raw$submission_date, na.rm = TRUE)


# CHANGED 2026-09-11 (Jack, explicit): the old filter(coverage_status ==
# "covered", exclusion_reason == "none") against WORKING was found to have
# a real, if dormant, bug - 1_sampling's strata-level WORKING file doesn't
# just FLAG an excluded stratum, it OMITS the row entirely (confirmed
# directly against the live v7 files: WORKING's 314 rows are the exact
# subset of FULL's 571 with coverage_status=="covered"). That means the
# moment a stratum's coverage_status flips to "excluded" (the
# accessibility_loss_below_population_threshold mechanism - the same one
# behind the whole Dandume/Faskari/Matazu/Musawa/Sabuwa saga on the
# 1_sampling side), every real submission already collected there becomes
# invisible to every stratum-level Collected/Achieved/Confirmed/Pending
# total for as long as it stays excluded - not miscounted, never summed at
# all. Cluster-level progress was already protected against this
# (cluster_targets below is FULL-sourced, fixed 2026-09-01) - stratum-level
# wasn't. Zero strata were excluded when checked (2026-09-11), so this
# wasn't producing a wrong number that day, but it's a live landmine given
# how often this mechanism has flipped on the 1_sampling side.
#
# Fix: read the strata-level FULL file (confirmed to exist,
# NGA_MSNA_2026_strata_level_sampling_frame_v7_FULL.csv, 571 rows) instead
# of WORKING, and include two categories: normally covered rows, PLUS rows
# currently excluded specifically for accessibility_loss_below_population_
# threshold (11 rows as of 2026-09-11) - Jack's explicit requirement: a
# stratum dropped for inaccessibility should stay visible in the
# progress-by-LGA table with its real target/collected/achieved figures,
# not disappear, with its own status shown as "Dropped" (see
# compute_progress_by_stratum()'s status case_when below). Deliberately
# NOT included: the 245 rows that were never covered at all
# (partner_coverage_declined / certainty_stratum_below_moe_threshold at
# not_covered) - those never had real data collected against them, so
# showing them as "Dropped" would be confusing clutter for something that
# was never live, not a data-visibility fix.
strata_frame <- read_csv(
  latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"),
  show_col_types = FALSE
) %>%
  filter(
    (coverage_status == "covered" & exclusion_reason == "none") |
      (coverage_status == "excluded" & exclusion_reason == "accessibility_loss_below_population_threshold")
  )

# Single source of truth for the two headline design numbers — every place
# that used to hardcode or separately recompute these (Home's intro
# paragraph, "At a glance", "Today's snapshot") reads from here instead, so
# they can't drift out of sync with each other or with the sampling frame
# again the way the intro's hardcoded "31,051"/old FIELDING dates did.
# Filtered to coverage_status=="covered" (2026-09-11): a Dropped stratum's
# original design target shouldn't inflate "what we're currently trying to
# achieve" - it stays visible in the per-stratum table (above) but drops
# out of this aggregate the same way it drops out of TOTAL_PLANNED_
# INTERVIEWS_CURRENT below.
TOTAL_PLANNED_INTERVIEWS <- sum(strata_frame$target_sample[strata_frame$coverage_status == "covered"], na.rm = TRUE)
TOTAL_COVERED_LGAS <- length(unique(strata_frame$adm2_pcode[strata_frame$coverage_status == "covered"]))

# Reads FULL (not WORKING), filtered to coverage_status=="covered" &
# exclusion_reason=="none" — same fix already applied to
# prep_psu_geometries.R's cluster universe (2026-09-01), same reason: this
# table is only ever used below for adm1/adm2/adm3 name+pcode lookups
# (get_ward_choices, ward_to_lga, KNOWN_*_NAMES, adm2_name_lookup) — "does
# this place exist", not "what's left to sample" — so it needs the frame
# that never drops a covered row, not the shrinking candidate pool. WORKING
# was confirmed to already be dropping fully-achieved strata's clusters
# entirely (1_sampling's build log: idp_NG021014), which would silently
# remove that stratum's wards from the ward filter and (if it were ever the
# LAST pop_type left in an LGA) that LGA's own name/pcode from
# adm2_name_lookup. col_select limited to just the columns actually used
# downstream — FULL is 2.4x WORKING's row count (109k vs 46.5k), so reading
# only ~40 char columns' worth less than the full one avoids re-adding the
# kind of startup-time cost the stage2_frame_v5_full fallback (removed
# above) caused when it read the whole 47MB file. latitude/longitude/
# target_households (previously converted to numeric here) were never
# actually read by anything downstream in dashboard_app/ itself — dropped
# along with the unused columns. cluster_id WAS still needed, just not by
# anything in dashboard_app/: cleaning/real/summarise_cleaning_logs.R's
# summarise_cleaning_logs() (called from generate_partner_digest.R, which
# explicitly sources this file first — see that function's own header)
# reads household_frame$cluster_id for its ward lookup. Missed 2026-09-03
# when this col_select was first added, since the check only looked at
# dashboard_app/'s own usage — caught the same day when a redeploy's
# digest-generation step failed with "column cluster_id is not found".
# Added back here rather than in summarise_cleaning_logs.R itself, since
# household_frame is the single shared object both places read from.
household_frame <- read_csv(
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"),
  show_col_types = FALSE,
  col_types = cols_only(
    cluster_id = "c", adm1_pcode = "c", adm1_name = "c", adm2_pcode = "c",
    adm2_name = "c", adm3_name = "c", coverage_status = "c", exclusion_reason = "c"
  )
) %>%
  filter(coverage_status == "covered", exclusion_reason == "none")

# Boundary/geometry layers are all read at full survey precision (~15
# significant digits — sub-millimeter) but only ever displayed on a
# country-level web map, so that precision is pure transmitted weight with
# zero visual benefit. Reducing to 4 decimal degrees (~11m) cuts every
# layer's GeoJSON weight roughly in half (measured 2026-08-17: 16.6MB ->
# 9.2MB combined across all six layers below) with NO visible difference —
# verified directly by overlaying full-precision vs reduced-precision
# outlines on the densest LGA's smallest ward (the single most
# precision-sensitive shape in the whole dataset, ~13 sq km) at a tight
# zoom: full vs ~11m was pixel-identical, full vs ~111m (one digit
# coarser) already showed a visible corner shift. 4 decimal places is
# therefore the deliberate floor, not an arbitrary round number — going
# further would start trading away real visual fidelity for comparatively
# little extra savings (precision reduction has diminishing returns per
# digit; going from 5->4 digits saved another 8%, but 4->3 is where
# artifacts start appearing).
#
# Deliberately precision-only, NOT geometry simplification (e.g.
# rmapshaper::ms_simplify()/sf::st_simplify()) — tested that too, and it
# added only marginal extra savings on top of precision reduction (since
# these boundaries aren't especially vertex-dense to begin with) while
# introducing real topology risk: st_simplify() on the PSU hexagon grid
# produced invalid geometry ("Loop 0 is not valid: Edge 2 is degenerate").
# Precision reduction alone carries none of that risk (it rounds
# coordinates, it never removes or moves a vertex relative to its
# neighbours), so it's the simpler, safer choice for the size of win
# available here.
reduce_coord_precision <- function(sf_obj, digits = 4) {
  tmp <- tempfile(fileext = ".geojson")
  on.exit(unlink(tmp))
  st_write(sf_obj, tmp, quiet = TRUE, layer_options = paste0("COORDINATE_PRECISION=", digits))
  st_read(tmp, quiet = TRUE)
}

# The geometry-repair step for accessible_area_lga_ward_portions.shp
# (needed because reduce_coord_precision() corrupts that layer specifically
# — see accessibility_sf below) now lives in cleaning/prep/
# prep_accessibility_layer.R, run at prep time rather than on every app
# startup. It used to be a repair_accessibility_geometry() function defined
# here and called live below; moved out 2026-09-02 (see accessibility_sf's
# own comment for why) — no longer anything to call at runtime, so removed
# from here rather than left as dead code.

# National (unfiltered) — the Coverage Map wants full-Nigeria context (all
# states, non-assessment ones shown greyed rather than just omitted).
admin0_sf <- st_read(file.path(INPUT_DIR, "boundaries/nga_admin0_em.shp"), quiet = TRUE) %>%
  reduce_coord_precision()
admin1_sf <- st_read(file.path(INPUT_DIR, "boundaries/nga_admin1_em.shp"), quiet = TRUE) %>%
  reduce_coord_precision() %>%
  mutate(in_assessment = adm1_pcode %in% unique(strata_frame$adm1_pcode))

admin2_sf <- st_read(file.path(INPUT_DIR, "boundaries/nga_admin2_em.shp"), quiet = TRUE) %>%
  reduce_coord_precision() %>%
  filter(adm2_pcode %in% unique(strata_frame$adm2_pcode))

# PSU geometries (cleaning/prep/prep_psu_geometries.R): Non-IDP PSU = hexagon
# polygons; IDP PSU = the DTM site's own GPS point (no hexagon boundary).
# Both carry a modal adm3_name/adm3_pcode per cluster, so the ward filter
# can scope the per-cluster map view too.
psu_hexagons_sf <- st_read(file.path(INPUT_DIR, "boundaries/psu/psu_hexagons_non_idp.gpkg"), quiet = TRUE) %>%
  reduce_coord_precision()
psu_sites_sf <- st_read(file.path(INPUT_DIR, "boundaries/psu/psu_sites_idp.gpkg"), quiet = TRUE) %>%
  reduce_coord_precision()

# Ward (admin3) reference boundaries — GRID3 source, matching the sampling
# frame's own adm3_name/adm3_pcode source (cleaning/prep/prep_admin3_wards.R).
# Outline-only reference layer, no data join (like the state boundary layer).
wards_sf <- st_read(file.path(INPUT_DIR, "boundaries/nga_wards_grid3.gpkg"), quiet = TRUE) %>%
  reduce_coord_precision()

# real per-LGA partner assignment (cleaning/prep/prep_partner_lga_assignment.R,
# from input_data/partner_coverage/Partnerscoverage.xlsx)
partner_lga_assignment <- read_csv(
  file.path(INPUT_DIR, "partner_coverage/partner_lga_assignment.csv"),
  show_col_types = FALSE
)

# ---- respondent privacy: fields never shown/exported at the individual-
# submission level ------------------------------------------------------------
# General rule (2026-08-16): nothing that could make a specific respondent
# or household more identifiable/vulnerable — on its own, or combined with
# the row's date/enumerator/admin2/admin3 — belongs in a ROW-LEVEL view or
# export, even though the same fields are completely fine to use in
# AGGREGATE form (a histogram, a group mean, a %) where no single row is
# recoverable from the output. Exact GPS is the most direct case (it
# pinpoints the household outright); age/gender/household-size/HoH-status
# combined with a known submission date and LGA/ward can narrow a small
# settlement's population down to very few candidates.
# `strip_row_level_pii()` is the single place this list is applied —
# extend ROW_LEVEL_PII_COLUMNS here (not ad hoc per module) if another
# similarly-identifying field needs the same treatment later.
# Aggregate-only, privacy-safe uses of these SAME fields (Sample
# Representativeness's histograms/pyramid/group means, Data Integrity's
# Whipple's Index) are unaffected — they never call this helper, since
# they never expose a single row's own combination of values.
ROW_LEVEL_PII_COLUMNS <- c(
  "resp_gender", "resp_age", "resp_hoh_yn", "hoh_gender", "hoh_age", "hh_size",
  "latitude_submitted", "longitude_submitted"
)

strip_row_level_pii <- function(df) {
  df %>% select(-any_of(ROW_LEVEL_PII_COLUMNS))
}

# ---- lookups ---------------------------------------------------------------

# NB on direction: shiny's selectInput/selectizeInput `choices` uses the
# vector's *names* as the displayed label and its *values* as what's
# actually stored in input$x — so every choices vector below is built as
# c(label = code), not c(code = label).
REGION_LABELS <- c(NE = "North-East (NE)", NW = "North-West (NW)", NC = "North-Central (NC)")

# ---- global colour theme ----------------------------------------------------
# Consistent throughout: population group has its own fixed colour pair,
# distinct from the (unrelated) traffic-light status colours below, so the
# two colour systems never get visually confused with each other.
POP_TYPE_COLORS <- c(non_idp = "#2E6F9E", idp = "#D9822B") # blue / orange — classic colourblind-safe pair
POP_TYPE_LABELS <- c(non_idp = "Non-IDP", idp = "IDP")
COMBINED_COLOR <- "#1B2A4A" # used when a 3rd "both groups combined" series is shown alongside the pair above
UNMATCHED_COLOR <- "#9AA3AF"

# 3-tier progress status, used everywhere a stratum/cluster's status is
# shown (Progress by LGA table, Partner Report, Home's priorities panel,
# Coverage Map's per-cluster traffic-light view) — one consistent
# vocabulary/colour set dashboard-wide instead of a different scheme per tab.
STATUS_COLORS <- c("Complete" = "#1E7B4D", "In progress" = "#D99A2B", "Not started" = "#C1443C")

# Coverage Map's per-cluster view: border colour for clusters that have
# received MORE completed interviews than target_households (see
# mod_map.R's cluster_status()/OVERSAMPLED_BORDER usage, and
# reports_partner_digest.R's compute_oversampled_clusters() for the same
# achieved > target definition applied dashboard-wide). Deliberately not a
# red — STATUS_COLORS["Not started"] already owns red in the same legend,
# and oversampled clusters are always "Complete" (green-filled), so a red
# border there would read as a clash with "Not started" rather than as its
# own thing, on top of red-vs-red being a bad pair for red-green
# colourblindness (see POP_TYPE_COLORS above for the same concern).
OVERSAMPLED_BORDER <- "#6C3483" # darkened 2026-08-24 (was #8E44AD) — Jack: outline wasn't clear enough

# Overall app "chrome" theme — first pass, expected to be revised. Navbar
# and sidebar (filter panel) get the dark blue/grey; the main body stays
# the Bootstrap default white/black (not overridden here) so cards, tables
# and value_box status colours all keep reading clearly against it.
THEME_NAVBAR_BG <- "#1B2A4A" # dark navy
THEME_SIDEBAR_BG <- "#3D4B5C" # blue-grey
THEME_SIDEBAR_FG <- "#F4F6F8" # near-white, for text/labels on the sidebar

# ward choices stay downstream-only (nothing narrows *because* of a ward
# pick, except which LGA(s) are effectively in view — see ward_to_lga
# below); every other sidebar filter — Region, State, LGA, Partner,
# Population group — mutually narrows every other one.
get_ward_choices <- function(lgas) {
  household_frame %>%
    filter(adm2_name %in% lgas, !is.na(adm3_name), adm3_name != "NA") %>%
    distinct(adm3_name) %>% arrange(adm3_name) %>% pull(adm3_name)
}

# ward -> LGA lookup, used so selecting a ward narrows the LGA-level
# progress view to LGAs containing that ward (targets aren't ward-level —
# the sampling frame's strata are LGA x pop_type — so a ward selection
# narrows *which* LGA(s) are shown rather than splitting their target).
ward_to_lga <- household_frame %>%
  filter(!is.na(adm3_name), adm3_name != "NA") %>%
  distinct(adm2_name, adm3_name)

# ---- known state/LGA/ward names, straight from the current frame -----------
# Root-caused 2026-09-01, per Jack (ZOA's Partner Report showed 152
# collected, but Progress Overview/Coverage Map showed 146 even with every
# filter reset): app.R's filtered_subs() excludes a row whenever its
# submitted admin1/admin2_submitted/admin3_submitted isn't in the CURRENT
# filter selection -- but "select all" only ever offers names the frame
# currently recognises. A submitted ward that used to be valid but was
# renamed/merged/dropped in a frame revision (exactly what just happened
# with the resampling batches, e.g. ZOA's "Lahodu" and "Hamma Ali
# Marabawa" — 5 + 1 = 6, precisely the gap) can never be "selected",
# because it was never offered as a choice — so it silently vanishes from
# every LGA-level view even though Partner Report (which doesn't route
# through the ward/LGA picker at all) still counts it correctly. These
# sets let filtered_subs() tell "genuinely no ward info" (NA — already
# handled) apart from "a real value the frame just doesn't recognise
# anymore" (should still count toward its LGA, just can't be individually
# ward-filtered) rather than treating both as excludable.
KNOWN_STATE_NAMES <- unique(household_frame$adm1_name)
KNOWN_LGA_NAMES <- unique(household_frame$adm2_name)
KNOWN_WARD_NAMES <- unique(ward_to_lga$adm3_name)

# canonical partner id -> display name. irc/lhi split from a single-select
# question (l_org_id) in the live tool (cleaning/MSNA_Data_Cleaning/kobo_tool/
# NGA2605_MSNA_Kobo_10082026.xlsx) — they're separate organisations with
# separate enumeration teams, jointly covering 4 LGAs by internal agreement
# (see cleaning/prep/prep_partner_lga_assignment.R header) but never
# submitting under a combined code.
ORG_LABELS <- c(
  acf = "Action Against Hunger (ACF)", care = "CARE", coopi = "COOPI",
  crs = "Catholic Relief Services", drc = "Danish Refugee Council",
  fact = "FACT Foundation", fhi360 = "FHI 360", imc = "International Medical Corps",
  intersos = "INTERSOS", irc = "International Rescue Committee",
  lhi = "Legacy Humanitarian Initiative (LHI)",
  jrs = "Jesuit Refugee Service", malteser = "Malteser International",
  mdm = "Médecins du Monde", nrc = "Norwegian Refugee Council",
  plan = "PLAN International", sci = "Save the Children",
  si = "Solidarités International", street_child = "Street Child of Nigeria",
  zoa = "ZOA", other = "Other / unassigned"
)

# LGAs jointly covered by more than one org (currently: Isa, Sabon Birni,
# Tangaza, Zuru — irc+lhi, Isa also drc), where neither org has claimed
# specific sample points ahead of time — used to show a "jointly covered"
# note on the Partner Report so achieved counts there (which include every
# covering org's submissions, not just the viewed org's own) aren't
# mistaken for that org's individual progress.
shared_coverage_adm2 <- partner_lga_assignment %>%
  count(adm2_pcode, name = "n_orgs") %>%
  filter(n_orgs > 1) %>%
  pull(adm2_pcode)

# adm2_pcode -> every org_id assigned there, for looking up "who else covers
# this LGA" from a given org's own report (excludes itself at the call site).
coverage_orgs_by_adm2 <- split(partner_lga_assignment$org_id, partner_lga_assignment$adm2_pcode)

# adm2_pcode -> "Partner A, Partner B" (or "Not partner-assigned") — used in
# Coverage Map popups (LGA polygons, cluster points/hexagons) so a viewer
# can see who's responsible without leaving the map. Vectorised (one call
# per row via sapply at the call site), not a per-row loop.
partner_coverage_label <- function(pc) {
  orgs <- coverage_orgs_by_adm2[[pc]]
  if (is.null(orgs)) "Not partner-assigned" else paste(unname(ORG_LABELS[orgs]), collapse = ", ")
}

# ---- accessibility layer (1_sampling/resampling/, copied in via cleaning/
# prep/prep_accessibility_layer.R) — partners report which of their own
# LGA-scoped ward portions are currently inaccessible (insecurity, denied
# access, etc.); default is Accessible until a partner explicitly reports
# otherwise. This reclassifies the already-delivered clusters partners are
# actually fielding — it is NOT a new sample design, no clusters have been
# added/removed/reallocated. Map layer + completeness indicator only for
# now (2026-08-25) — the sampling frame itself isn't tagged with
# accessibility yet in this dashboard, that's a deliberate separate
# follow-up (Jack: pending decisions there).
#
# The source data spells partner names differently ("IMC", "Solidarités")
# than this dashboard's canonical org_id/ORG_LABELS pair — this table
# reconciles the two so hover popups and the completeness count below stay
# consistent with the rest of the dashboard.
#
# FIXED 2026-08-28: this key was "Solidarité" (missing the trailing "s")
# until today - stale since 1_sampling renamed the partner everywhere on
# 2026-08-27 (a truncated name in their raw source data, unrelated to this
# dashboard). The mismatch meant accessibility_partner_label() silently
# produced the literal string "NA" in the Coverage Map's hover popup for
# any ward Solidarités reported on, and accessibility_reported_org_ids
# counted a phantom NA "partner" instead of crediting "si" (the national
# total happened to still read 9 either way - one NA swapped for one real
# entry - so this wasn't visible from the headline count alone). Re-
# verified 2026-08-28 against the live, current-day ward CSV: every
# distinct partner string maps 1:1 onto a real org_id, none unmapped.
ACCESSIBILITY_PARTNER_TO_ORG <- c(
  "ACF" = "acf", "CARE" = "care", "COOPI" = "coopi", "CRS" = "crs", "DRC" = "drc",
  "FACT" = "fact", "FHI 360" = "fhi360", "IMC" = "imc", "INTERSOS" = "intersos",
  "IRC" = "irc", "LHI" = "lhi", "Malteser" = "malteser", "MDM" = "mdm",
  "NRC" = "nrc", "PLAN" = "plan", "Save the Children" = "sci",
  "Solidarités" = "si", "Street Child of Nigeria" = "street_child", "ZOA" = "zoa"
)

# splits a "; "-separated multi-partner cell (joint-coverage LGAs, same
# irc/lhi-style arrangement ORG_LABELS' header note describes — none of the
# joint cells have actually been reported on yet as of 2026-08-25, but the
# split handles it correctly whenever one does) into canonical ORG_LABELS
# names; "" for a blank/NA cell (nothing reported yet on that ward portion).
accessibility_partner_label <- function(raw) {
  vapply(raw, function(x) {
    if (is.na(x) || !nzchar(x)) return("")
    org_ids <- unname(ACCESSIBILITY_PARTNER_TO_ORG[trimws(strsplit(x, ";")[[1]])])
    paste(unname(ORG_LABELS[org_ids]), collapse = ", ")
  }, character(1))
}

# Source shapefile is in a projected metre CRS (Yoff/UTM zone 28N, used
# upstream for its own area_km2/pop_total zonal stats) — st_transform(4326)
# before reduce_coord_precision() so it renders correctly in Leaflet, same
# as every other boundary layer here. DBF's 10-character field name limit
# truncated the source attribute names (confirmed against the shapefile's
# own .csv sidecar) — renamed back to their full/readable form immediately
# so the rest of the app never has to know about the truncation.
# Reads the PRECOMPUTED, already-repaired file (2026-09-02, emergency perf
# fix — dashboard failed to start on shinyapps.io, "startup took too
# long"). Was previously st_read(the raw .shp) %>% st_transform(4326) %>%
# reduce_coord_precision() %>% repair_accessibility_geometry() run fresh
# on every single app startup (~3.7s locally, likely much more on a
# shared/constrained shinyapps.io worker) — loading the precomputed file
# back takes ~0.15s instead. That exact pipeline now runs at the END of
# cleaning/prep/prep_accessibility_layer.R instead, right after it copies
# in a fresh accessible_area_lga_ward_portions.shp from 1_sampling — so
# this .gpkg regenerates automatically every time that prep script is
# rerun (i.e. every accessibility refresh) rather than needing a separate
# manual precompute step to remember. Don't repoint this line at the raw
# .shp again — that reintroduces the startup cost this fixed.
accessibility_sf <- st_read(file.path(INPUT_DIR, "accessibility/accessible_area_lga_ward_portions_repaired.gpkg"), quiet = TRUE) %>%
  rename(
    adm2_pcode = adm2_pc, adm2_name = adm2_nm, adm1_pcode = adm1_pc, adm1_name = adm1_nm,
    wardname = wardnam, area_km2 = are_km2, pop_total = pop_ttl, pop_type = pop_typ,
    accessible_status = accssb_, status_source = stts_sr,
    reporting_partners = rprtng_, reason_category = rsn_ctg, covering_partners = cvrng_p
  ) %>%
  mutate(
    reporting_partner_label = accessibility_partner_label(reporting_partners),
    covering_partner_label = accessibility_partner_label(covering_partners)
  )

# Ward-level table (not the shapefile) is the source for the completeness
# indicator below — one row per partner's own LGA-ward portion, the actual
# grain a partner reports against (the shapefile's rows are the same
# information geometrically re-split by LGA boundary for mapping, a
# different portioning of the same underlying reports).
accessibility_ward_df <- read_csv(
  file.path(INPUT_DIR, "accessibility/master_accessibility_status_ward_level.csv"),
  show_col_types = FALSE
)

# "X of 19 partners reported" — the completeness indicator every view of
# this data must carry (Jack, 2026-08-25: as of the last copy only a
# subset of partners have submitted a report, so this is a live, partial,
# evolving picture that must never be presented as final). Computed live
# off accessibility_ward_df each time it's refreshed, not hardcoded, so it
# self-corrects as more reports land. TOTAL_ACCESSIBILITY_PARTNERS is the
# dashboard's own canonical list of actually-active partners
# (partner_lga_assignment's distinct org_id, the same 19 used everywhere
# else, e.g. partner_adm2 above) — NOT ORG_LABELS itself (which also lists
# "jrs" and "other", neither an active assigned partner) and NOT derived
# from accessibility_ward_df (that would silently shrink if a partner
# simply has no ward portion in a given extract).
TOTAL_ACCESSIBILITY_PARTNERS <- length(unique(partner_lga_assignment$org_id))
accessibility_reported_org_ids <- accessibility_ward_df %>%
  filter(`Status source` == "confirmed_by_partner_report") %>%
  pull(`Reporting partner(s)`) %>%
  strsplit(";") %>%
  unlist() %>%
  trimws() %>%
  {unique(unname(ACCESSIBILITY_PARTNER_TO_ORG[.]))}
N_ACCESSIBILITY_PARTNERS_REPORTED <- length(accessibility_reported_org_ids)

# ---- per-LGA accessibility summary for the Coverage Map's LGA hover popup
# (2026-08-26): ward-portion accessible/inaccessible counts, and population
# remaining accessible split by pop type. Both source files (copied by
# prep_accessibility_layer.R) join cleanly against this dashboard's own
# sampling frame with NO name-fuzzy-matching needed, since both come from
# the same 1_sampling pipeline that produced the frame itself — verified
# 2026-08-26: the LGA-level CSV's 176 (State, LGA) pairs all exact-match
# strata_frame's own adm1_name/adm2_name, and the strata-level CSV's own
# "Strata ID" column already matches strata_frame$strata_id's exact format.
#
# The population-remaining-accessible figure specifically comes from the
# impact workbook's "Strata Level" sheet, NOT the LGA-level CSV's own
# population columns — those turned out to be the unreduced full design
# population (verified directly against the sampling frame: Mobbar's LGA-
# CSV figure matched strata_frame's n_pop exactly, despite Mobbar being
# 100% reported inaccessible), not a remaining-accessible figure.
accessibility_lga_ward_counts <- read_csv(
  file.path(INPUT_DIR, "accessibility/master_accessibility_status_lga_level.csv"),
  show_col_types = FALSE
) %>%
  left_join(
    strata_frame %>% distinct(adm1_name, adm2_name, adm2_pcode),
    by = c("State" = "adm1_name", "LGA" = "adm2_name")
  ) %>%
  filter(!is.na(adm2_pcode)) %>%
  transmute(
    adm2_pcode,
    n_ward_portions = `Total wards (LGA-scoped portions)`,
    n_ward_portions_inaccessible = `Wards reported inaccessible`
  )

# One label per adm2_pcode, e.g. "Non-IDP: 92% (154,568 of 167,331) | IDP:
# 88% (12,345 of 14,029)" — an LGA with only one pop-type stratum (most
# LGAs) just shows that one; omitted (not shown as "0%") for a pop type the
# LGA never had a stratum for at all, same sparse non_idp/idp coverage
# strata_frame itself has.
accessibility_pop_remaining_label <- read_csv(
  file.path(INPUT_DIR, "accessibility/accessibility_strata_level.csv"),
  show_col_types = FALSE
) %>%
  left_join(strata_frame %>% distinct(strata_id, adm2_pcode), by = c("Strata ID" = "strata_id")) %>%
  filter(!is.na(adm2_pcode)) %>%
  transmute(
    adm2_pcode,
    label = paste0(
      `Pop type`, ": ", round(`% of population remaining`), "% (",
      formatC(round(`Updated population within accessible area`), big.mark = ",", format = "d"), " of ",
      formatC(round(`Total population (design, n_pop)`), big.mark = ",", format = "d"), ")"
    )
  ) %>%
  group_by(adm2_pcode) %>%
  summarise(pop_remaining_label = paste(label, collapse = " | "), .groups = "drop")

accessibility_lga_summary <- accessibility_lga_ward_counts %>%
  left_join(accessibility_pop_remaining_label, by = "adm2_pcode") %>%
  mutate(pop_remaining_label = coalesce(pop_remaining_label, "n/a"))

# submitted admin2 -> canonical (adm1_pcode, adm2_pcode) via the frame, used
# to join submissions (which only carry names, as typed/selected in KoBo) to
# the boundary/target data (keyed by pcode).
adm2_name_lookup <- household_frame %>%
  distinct(adm1_name, adm2_name, adm2_pcode, adm1_pcode)

# ---- mutual cross-filtering (Region / State / LGA / Partner / Pop. group) --
# One row per (region, state, LGA, pop_type, partner) combination that
# actually exists in the design — the single source of truth every sidebar
# filter's available choices are computed from. Region/State/LGA/Partner/
# Pop.group all mutually narrow each other (only Ward stays downstream-only,
# see get_ward_choices/ward_to_lga above) — each filter's own choices are
# computed by filtering this table by every *other* currently-selected
# filter and reading off the distinct remaining values for its own column.
# The one LGA with no confirmed partner match (see
# cleaning/prep/prep_partner_lga_assignment.R) is coalesced to "other" here,
# matching how the mock submissions themselves are tagged.
filter_base <- strata_frame %>%
  left_join(
    partner_lga_assignment %>% select(adm2_pcode, org_id),
    by = "adm2_pcode",
    relationship = "many-to-many"
  ) %>%
  mutate(org_id = coalesce(org_id, "other"))

# LGAs (adm2_pcode) assigned to each partner — used to scope a partner's view
# to "their" LGAs (not just LGAs where they happen to have a submission
# yet). Derived from filter_base (not raw partner_lga_assignment directly)
# so the one LGA with no confirmed partner match is consistently reachable
# under "other" here too, not just in the filter choice lists above.
partner_adm2 <- split(filter_base$adm2_pcode, filter_base$org_id)

# `current` is a named list with any of region/state/lga/poptype/partner ->
# a character vector of that dimension's currently selected values (or NULL/
# absent to mean "no constraint from this dimension"). `dimension` is the
# one being computed *for* — deliberately excluded from the filtering below,
# since a filter obviously can't narrow its own choices by its own selection.
# Returns a choices vector ready for use in update*Input(choices = ...)
# (label = value, per the convention noted above).
compute_filter_choices <- function(dimension, current) {
  df <- filter_base
  if (dimension != "region" && length(current$region) > 0) df <- df %>% filter(region %in% current$region)
  if (dimension != "state" && length(current$state) > 0) df <- df %>% filter(adm1_name %in% current$state)
  if (dimension != "lga" && length(current$lga) > 0) df <- df %>% filter(adm2_name %in% current$lga)
  if (dimension != "poptype" && length(current$poptype) > 0) df <- df %>% filter(pop_type %in% current$poptype)
  if (dimension != "partner" && length(current$partner) > 0) df <- df %>% filter(org_id %in% current$partner)

  switch(dimension,
    region = {
      codes <- sort(unique(df$region))
      setNames(codes, unname(REGION_LABELS[codes]))
    },
    state = sort(unique(df$adm1_name)),
    lga = sort(unique(df$adm2_name)),
    poptype = {
      codes <- sort(unique(df$pop_type))
      setNames(codes, unname(POP_TYPE_LABELS[codes]))
    },
    partner = {
      codes <- unique(df$org_id)
      codes <- codes[order(codes == "other", unname(ORG_LABELS[codes]))]
      setNames(codes, unname(ORG_LABELS[codes]))
    }
  )
}

# Preserves a manually-narrowed selection across a choices recompute: keeps
# whatever's still valid; if nothing valid remains (or nothing was selected
# to begin with), falls back to "select all of the newly available choices"
# — this is what makes the sidebar default to "everything selected" and
# stay that way through cascading narrowing, without a separate "All X"
# pseudo-choice the user has to manually deselect (see app.R).
smart_selection <- function(current_values, new_choices) {
  still_valid <- intersect(current_values, new_choices)
  if (length(still_valid) == 0) new_choices else still_valid
}

# Initial (unconstrained) choice lists — the starting point before any
# filter has narrowed anything, and the full universe each filter's
# selectizeInput is initialised with (all pre-selected by default).
region_choices <- compute_filter_choices("region", list())
state_choices <- compute_filter_choices("state", list())
pop_type_choices <- compute_filter_choices("poptype", list())
org_id_choices <- compute_filter_choices("partner", list())

# ---- derived: LGA x pop_type progress table --------------------------------

# Takes a submissions data frame (any subset — e.g. date-range-filtered)
# and returns the strata_frame joined with achieved counts computed from
# just that subset. This is what makes every LGA-level view (Coverage Map's
# LGA choropleth, Progress by LGA table, Progress Overview's region chart)
# date-range aware: app.R's `filtered_stratum` reactive calls this on
# `filtered_subs()` (already scoped by date range + every other filter)
# rather than on the full, unfiltered `submissions_raw`.
# Two definitions, deliberately kept separate everywhere the dashboard
# reports numbers (added 2026-08-24, per Jack — teams were treating
# oversampling in easy clusters as compensating for undersampling
# elsewhere, and the dashboard's own "% of target" figures were
# unintentionally reinforcing that belief by counting the surplus):
#
# - COLLECTED: every completed interview that actually happened in the
#   field, full stop — no dedup, no match requirement, no cap. "How much
#   work was done." Use is_collected() for this.
# - ACHIEVED: only what counts toward the sample frame — completed, not a
#   duplicate, matched to a real point, not a confirmed quality exclusion,
#   AND capped at each CLUSTER's own target_households before being summed
#   up to stratum/LGA/partner level. Capping has to happen at the cluster
#   grain, not after summing to stratum: an oversampled cluster's surplus
#   would otherwise still mask an undersampled cluster in the same LGA
#   even after this fix, just one level up. Use is_achieved() +
#   compute_progress_by_stratum() for this — never write either filter
#   condition out again by hand.
#   flagged_deletion_reason (added 2026-08-30 as quality_exclusion_reason,
#   redefined 2026-09-06 per the deletion/recovery-confirmation model,
#   STALE COMMENT FIXED 2026-09-11): a row currently flagged for deletion by
#   any of the five ACTIVE deletion reasons (no_consent, duration floor,
#   duplicate point, listing missing, percentage missing) — independently
#   recomputed by cleaning/real/independent_deletion_checks.R as of
#   2026-09-11, no longer sourced from the DO's deletion_log.R directly, see
#   CLAUDE.md's "Independent deletion checks" section — via
#   recovery_issue_tracker.csv — REGARDLESS of whether that flag has been
#   confirmed, contested, or is still awaiting a partner's response.
#   fcs_zero downgraded 2026-09-10 from an automatic deletion reason to a
#   no-op logical-error flag — it no longer excludes anything here; see
#   issue_tracker.R's NO_APPEAL_DELETION_REASONS header comment for the full
#   history. This is deliberately the WIDER of two possible
#   bases: the intended incentive is that a partner sees a flagged interview
#   drop out of Achieved immediately, before any recovery-workbook round has
#   even gone out, not just once it's finally settled. Deliberately excluded
#   from Achieved only, NOT Collected — Collected stays "did the interview
#   happen in the field," full stop.
#   Resampling reads a DIFFERENT, narrower basis — data/
#   CONFIRMED_DELETIONS_OVERLAY.csv, only settled (confirmed/contested)
#   deletions — since a flagged-but-still-open record might yet be
#   recovered and shouldn't be treated as gone for that purpose. The two
#   numbers WILL disagree while anything is pending; that's by design, not a
#   bug — see cleaning/real/build_confirmed_deletions_overlay.R's header for
#   the full reasoning and both overlays.
is_collected <- function(df) {
  df$interview_outcome == "completed"
}
# POLICY CHANGE 2026-09-11 (Jack, explicit, donor-facing decision — traced
# back to a conversation the night of 2026-09-10 that got lost in that
# night's session mix-up, then re-confirmed directly the next day):
# Achieved now excludes ONLY settled/confirmed deletions - a pending or
# unresolved flag of ANY kind (duplicate, unmatched, still-open tracker
# item) counts as Achieved until it's actually confirmed. Reasoning, in
# Jack's own words: real, limited time/money to collect data, hopeful most
# pending items resolve favourably, and the team would rather risk asking
# a field team to go back for a specific interview later than have them
# oversample/waste effort now against a pessimistic count that includes
# items likely to turn out fine. This is a full reversal of the "pessimistic
# dashboard" policy documented everywhere in this file/CLAUDE.md before
# today - is_achieved() is now defined as exactly "collected, and not a
# confirmed deletion", nothing else, by construction (calls
# is_confirmed_deletion() directly below so the two can never drift apart).
#
# Practical consequence, quantified against live data before this changed
# (2026-09-11): national Achieved jumped from 14,749 to 15,995 (+1,246)
# the moment this flipped. 1,110 of that 1,246 (89%) is completed
# interviews the raw, automated is_duplicate key-match flags as a likely
# duplicate but that have NOT yet been through the tracker/recovery
# process at all - these now count as Achieved immediately, same as any
# other not-yet-confirmed item, per the letter of Jack's decision. 19 are
# currently-unmatched (matched_survey_id NA) rows - notable because
# crs_unmatched has no independent check built yet (see CLAUDE.md), so
# these currently have NO path to ever being registered/reviewed/
# confirmed at all; they'll simply sit counted as Achieved indefinitely
# until that check exists. Flagged to Jack; standing until told otherwise.
#
# The old is_duplicate/matched_survey_id checks were REMOVED from this
# function entirely (not just loosened) - keeping either would have meant
# Achieved excludes more than "only confirmed deletions", contradicting
# the policy as stated. A genuinely confirmed duplicate (deletion_reason=
# duplicate_point, status=confirmed) is still excluded correctly, via
# is_confirmed_deletion() below - this only changes what happens BEFORE
# that confirmation.
is_achieved <- function(df) {
  df$interview_outcome == "completed" & !is_confirmed_deletion(df)
}
# Settled deletion (status confirmed/contested) - a SUBSET of "flagged"
# (is.na(deletion_status) is FALSE), used to split the Collected-Achieved
# gap into Confirmed vs Pending Deletion (2026-09-09) - see
# compute_progress_by_stratum()'s confirmed_deletion_n/pending_deletion_n
# below for the full breakdown and why Pending also absorbs duplicates/
# unmatched/oversampling surplus (Jack, 2026-09-09: none of those three
# currently have any partner-facing review path either, same as a genuinely
# pending tracker row - "not yet confirmed gone, not yet saved" either way;
# revisit giving duplicates/unmatched an actual review path separately).
is_confirmed_deletion <- function(df) {
  # interview_outcome check added defensively, matching is_collected()/
  # is_achieved()'s own scoping - a tracker row keys purely on uuid, so
  # nothing stops one existing (in principle) for a consent_refused uuid,
  # which is_collected() would already exclude; without this, such a row
  # would inflate confirmed_deletion_n with no matching presence in
  # collected_n, silently breaking the Collected = Achieved + Confirmed +
  # Pending identity for that uuid's stratum (masked by pending_deletion_n's
  # own floor at 0, not caught). Not observed in real data as of 2026-09-09
  # (checked), but the condition costs nothing and removes the possibility.
  df$interview_outcome == "completed" & !is.na(df$deletion_status) & df$deletion_status %in% c("confirmed", "contested")
}

# cluster_id -> target_households, used only to CAP achieved at the
# cluster level below — same source (psu_hexagons_sf/psu_sites_sf) the
# Coverage Map's oversampled-cluster border and the partner digest's
# "Oversampled clusters" sheet already use, so all three agree on what
# counts as a cluster's target. Static (doesn't depend on subs), computed
# once rather than inside compute_progress_by_stratum().
#
# FULL-frame fallback (2026-09-01, per Jack): the WORKING frame is
# deliberately a shrinking candidate pool — 1_sampling's own build log
# confirms it drops a cluster's remaining rows once a) it's fully achieved
# (nothing left to nominate) or b) its ward is newly marked inaccessible.
# Both are expected outcomes of a resample, not data loss — but
# psu_hexagons_sf/psu_sites_sf are geometry layers that may not have been
# regenerated for every such cluster, so a handful drop out of the lookup
# above entirely. Without this, an unrecognised cluster's target defaults
# to 0 (see coalesce() below), silently zeroing every achieved interview
# in it rather than leaving it uncapped — caught 2026-09-01 via a 361-
# interview/37-cluster gap, 92% of it FACT. The FULL frame (unlike
# WORKING) never drops a row regardless of achieved/accessibility status,
# so it's a complete source for exactly the clusters WORKING no longer
# carries. Only fills gaps — bind_rows() + distinct() keeps the spatial
# layers' own value wherever they already have one.
# stage2_frame_v5_full fallback REMOVED (2026-09-02, emergency perf fix
# ahead of a live presentation — dashboard was failing to start on
# shinyapps.io: "unable to connect to worker... startup took too long").
# This was a 47MB full-column CSV read added as a target_households
# fallback for clusters missing from the spatial layers. It's no longer
# needed: prep_psu_geometries.R was fixed the same day to source its
# cluster universe from FULL (not the shrinking WORKING pool), so
# psu_hexagons_sf/psu_sites_sf now carry a target for 100% of covered
# clusters on their own — verified this fallback was contributing 0 extra
# rows before removing it. If a future resampling batch reintroduces a
# gap here, re-run prep_psu_geometries.R first (that's the real fix) —
# don't re-add this fallback as a bandage, it cost real startup time for
# a case that shouldn't exist once the geometry source is current.
cluster_targets <- bind_rows(
  st_drop_geometry(psu_hexagons_sf) %>% select(cluster_id, strata_id, target_households),
  st_drop_geometry(psu_sites_sf) %>% select(cluster_id, strata_id, target_households)
) %>%
  distinct(cluster_id, .keep_all = TRUE) %>%
  mutate(target_households = as.numeric(target_households))

# ---- current (live) stratum target, 2026-09-08 rebuild ---------------------
# strata_frame$target_sample is the ORIGINAL design-time figure and is
# deliberately never touched again (kept as a stable baseline for "Original
# target" in the dashboard). It never grew when resampling added
# supplementary/replacement clusters, which let a stratum read "Complete"
# once a skewed subset of the REAL roster cleared the OLD, now-too-low bar,
# while other real, currently-open clusters sat untouched (found 2026-09-07,
# Augie/Kebbi: 5 real open clusters at zero achieved, LGA still read
# Complete). target_sample_current is the live figure - sum of
# target_households across the CURRENT cluster roster per stratum, from the
# same cluster_targets source the achieved-capping above already uses, so
# both numbers are always computed from the one live roster, never two
# separately-drifting sources. This is what "Complete" is now tied to;
# target_sample stays purely for the "Original target" display column.
strata_target_current <- cluster_targets %>%
  group_by(strata_id) %>%
  summarise(target_sample_current = sum(target_households, na.rm = TRUE), .groups = "drop")

# TOTAL_PLANNED_INTERVIEWS_CURRENT - the live-roster counterpart to
# TOTAL_PLANNED_INTERVIEWS (2026-09-09). Defined here, not alongside
# TOTAL_PLANNED_INTERVIEWS above, because strata_target_current (like
# cluster_targets) isn't available until psu_hexagons_sf/psu_sites_sf have
# loaded - can't move earlier without moving those too. TOTAL_PLANNED_
# INTERVIEWS itself is left untouched (still sum(strata_frame$target_sample)
# - the frozen original) rather than repurposed, since smoke_test.R already
# has regression tests asserting it against target_sample-based sums; adding
# a second constant is the non-breaking way to get both numbers available.
# Filtered to strata_frame's own covered-strata universe first (inner_join,
# not a bare sum over every strata_id in cluster_targets) so a stray/
# excluded stratum's clusters can't inflate this beyond what strata_frame
# itself would ever count.
# Filtered to coverage_status=="covered" (2026-09-11): now that strata_frame
# includes Dropped strata (see its own header above), the live active total
# must explicitly exclude them - same reasoning as TOTAL_PLANNED_INTERVIEWS.
TOTAL_PLANNED_INTERVIEWS_CURRENT <- strata_frame %>%
  filter(coverage_status == "covered") %>%
  inner_join(strata_target_current, by = "strata_id") %>%
  pull(target_sample_current) %>%
  sum(na.rm = TRUE)

compute_progress_by_stratum <- function(subs) {
  completed_matched <- subs %>% filter(is_achieved(.))

  # ---- ACHIEVED: cap at cluster level FIRST, then sum to stratum ----------
  achieved_by_cluster <- completed_matched %>%
    filter(!is.na(matched_cluster_id)) %>%
    count(matched_cluster_id, matched_strata_id, name = "cluster_achieved_n") %>%
    left_join(cluster_targets, by = c("matched_cluster_id" = "cluster_id")) %>%
    mutate(
      target_households = coalesce(target_households, 0),
      # a cluster with no real target (missing/0) contributes nothing
      # counted — never lets an unrecognised cluster inflate achieved
      capped_achieved_n = pmin(cluster_achieved_n, target_households)
    )
  achieved <- achieved_by_cluster %>%
    group_by(matched_strata_id) %>%
    summarise(achieved_n = sum(capped_achieved_n), .groups = "drop")

  # separate count (not pivot_wider) so a filtered subset with zero reserve
  # rows just produces a zero-row table, not a missing/erroring column.
  # NOT capped the same way as achieved_n — this is a diagnostic ratio
  # (how much of the counted total came from the reserve list), not part
  # of the target-tracking arithmetic, so it's out of scope for this fix.
  achieved_reserve <- completed_matched %>%
    filter(matched_status == "reserve") %>%
    count(matched_strata_id, name = "achieved_reserve_n")
  achieved <- achieved %>% left_join(achieved_reserve, by = "matched_strata_id")

  # ---- COLLECTED: raw, uncapped, includes duplicates — matched to a
  # stratum via the same (pop_type + admin2) key achieved_n uses, which
  # (unlike matched_survey_id/matched_cluster_id) doesn't require a
  # specific-point match, just that pop_type and admin2 were both present.
  collected <- subs %>% filter(is_collected(.)) %>% count(matched_strata_id, name = "collected_n")

  # ---- CONFIRMED DELETION: settled (status confirmed/contested) tracker
  # rows only - genuinely, permanently gone, feeds resampling too (2026-09-09,
  # Jack's 3-status model). Counted directly (a real per-row condition),
  # unlike Pending below.
  confirmed_deletion <- subs %>% filter(is_confirmed_deletion(.)) %>%
    count(matched_strata_id, name = "confirmed_deletion_n")

  # ---- OVERSAMPLING SURPLUS (renamed 2026-09-11, was "pending_deletion_n"):
  # collected_n - achieved_n - confirmed_deletion_n is STILL a meaningful
  # residual, but it no longer means "pending deletion" now that
  # is_achieved() (above) already counts every not-yet-confirmed row as
  # achieved. The only thing that can still make achieved_n fall short of
  # collected_n - confirmed_deletion_n is the per-cluster capping above
  # (pmin(cluster_achieved_n, target_households)) - i.e. real completed
  # interviews beyond what a cluster's target calls for. Kept as an exact
  # residual (not independently summed) for the same reason as before: no
  # risk of a double-counted row breaking the identity.
  # Collected = Achieved + Confirmed Deletion + Oversampling Surplus,
  # exactly, by construction - the SAME 3-term identity as before, just
  # with its third term meaning something different now.
  #
  # ---- PENDING DELETION (redefined 2026-09-11): now a genuinely
  # independent, directly-counted INFORMATIONAL subset of Achieved, not a
  # peer bucket in the identity above - how many of this stratum's
  # achieved interviews still carry an unresolved tracker flag (pending/
  # sent/rejected, not yet confirmed/contested). Jack's explicit intent:
  # keep this visible so it's obvious how much of "achieved" could still
  # move if a pending item resolves as a real deletion, without it being
  # subtracted from the headline number the way it used to be. Not capped
  # the same way achieved_n is (a genuinely different question - "how much
  # of what's currently counted is still at risk", not part of the
  # target-tracking arithmetic).
  pending_flagged <- subs %>%
    filter(interview_outcome == "completed", !is.na(deletion_status),
           !deletion_status %in% c("confirmed", "contested")) %>%
    count(matched_strata_id, name = "pending_deletion_n")

  strata_frame %>%
    left_join(achieved, by = c("strata_id" = "matched_strata_id")) %>%
    left_join(collected, by = c("strata_id" = "matched_strata_id")) %>%
    left_join(confirmed_deletion, by = c("strata_id" = "matched_strata_id")) %>%
    left_join(pending_flagged, by = c("strata_id" = "matched_strata_id")) %>%
    left_join(strata_target_current, by = "strata_id") %>%
    mutate(
      achieved_n = coalesce(achieved_n, 0L),
      collected_n = coalesce(collected_n, 0L),
      confirmed_deletion_n = coalesce(confirmed_deletion_n, 0L),
      oversampling_surplus_n = pmax(collected_n - achieved_n - confirmed_deletion_n, 0L),
      pending_deletion_n = coalesce(pending_deletion_n, 0L),
      achieved_reserve_n = coalesce(achieved_reserve_n, 0L),
      pct_reserve_used = ifelse(achieved_n > 0, achieved_reserve_n / achieved_n, NA_real_),
      # 2026-09-08: target_sample kept, unrenamed, as "Original target" - the
      # untouched design-time figure (naming convention used consistently
      # across this file - never let it mean something else elsewhere).
      # target_sample_current (just joined) is the live roster total;
      # Complete/coloring/pct_achieved now key off THAT, not the frozen
      # original - see strata_target_current's own note above for why.
      # coalesce guards a stratum with no live cluster in cluster_targets at
      # all (shouldn't happen, but 0 is the safe fallback, same convention
      # as achieved_n/collected_n above).
      target_sample_current = coalesce(target_sample_current, 0),
      pct_achieved = ifelse(target_sample_current > 0, achieved_n / target_sample_current, NA_real_),
      # DROPPED status (2026-09-11): a stratum currently excluded for
      # accessibility_loss_below_population_threshold - see strata_frame's
      # own header above. Checked FIRST: such a stratum's target_sample_
      # current can legitimately read 0 (nothing currently accessible),
      # which would otherwise misleadingly read "Complete".
      status = case_when(
        coverage_status == "excluded" ~ "Dropped",
        target_sample_current <= 0 | achieved_n >= target_sample_current ~ "Complete",
        achieved_n > 0 ~ "In progress",
        TRUE ~ "Not started"
      )
    )
}

# Static/unfiltered default — used by the Partner Report (deliberately
# cumulative-to-date rather than windowed by the sidebar's date filter,
# since a report handed to a partner should reflect total progress, not
# whatever date range happened to be selected when it was generated).
progress_by_stratum <- compute_progress_by_stratum(submissions_raw)

# ---- per-cluster Confirmed/Pending Deletion (2026-09-09, Coverage Map's
# per-cluster popup) — deliberately NOT capped the way achieved_n is at
# stratum grain: capping exists to stop one cluster's surplus masking
# ANOTHER cluster's shortfall when SUMMING across several - a non-issue at
# a single cluster's own grain, where there's nothing else to mask. So
# achieved_n here is the same raw, uncapped figure the Coverage Map's
# oversampled-cluster border already uses (mod_map.R's existing
# cluster_achieved()), and there's no oversampling-excess term in Pending
# here either (unlike the stratum version) - a cluster's own surplus is
# still genuinely "achieved" at its own grain, just flagged separately via
# the existing oversampled border/badge. Pending is still the residual
# (collected - achieved - confirmed), for the same double-counting-proof
# reason as compute_progress_by_stratum() above. Unmatched submissions
# (no matched_cluster_id at all) can't appear in ANY cluster's numbers here,
# same limitation cluster-level achieved already had before this change.
compute_cluster_progress <- function(subs) {
  scoped <- subs %>% filter(!is.na(matched_cluster_id))
  achieved <- scoped %>% filter(is_achieved(.)) %>% count(matched_cluster_id, name = "achieved_n")
  collected <- scoped %>% filter(is_collected(.)) %>% count(matched_cluster_id, name = "collected_n")
  confirmed_deletion <- scoped %>% filter(is_confirmed_deletion(.)) %>% count(matched_cluster_id, name = "confirmed_deletion_n")
  # 2026-09-11: same split as compute_progress_by_stratum() above - see
  # that function's own comments for the full reasoning.
  pending_flagged <- scoped %>%
    filter(interview_outcome == "completed", !is.na(deletion_status),
           !deletion_status %in% c("confirmed", "contested")) %>%
    count(matched_cluster_id, name = "pending_deletion_n")

  cluster_targets %>%
    select(cluster_id) %>%
    left_join(achieved, by = c("cluster_id" = "matched_cluster_id")) %>%
    left_join(collected, by = c("cluster_id" = "matched_cluster_id")) %>%
    left_join(confirmed_deletion, by = c("cluster_id" = "matched_cluster_id")) %>%
    left_join(pending_flagged, by = c("cluster_id" = "matched_cluster_id")) %>%
    mutate(
      achieved_n = coalesce(achieved_n, 0L),
      collected_n = coalesce(collected_n, 0L),
      confirmed_deletion_n = coalesce(confirmed_deletion_n, 0L),
      oversampling_surplus_n = pmax(collected_n - achieved_n - confirmed_deletion_n, 0L),
      pending_deletion_n = coalesce(pending_deletion_n, 0L)
    )
}

# ---- oversampled clusters (2026-08-27) — moved here from reports_partner_
# digest.R (that file's own copy removed, this is now the single source
# both use) so the dashboard can show the same oversampling analytics the
# partner digest already had — one cluster's surplus submissions can't
# count toward or mask under-coverage elsewhere (see compute_progress_by_
# stratum() above), but the surplus itself, and which partner is
# responsible for it, was previously only visible in the digest workbook
# and the Coverage Map's purple border/tooltip — no count, no table, no
# assigned-vs-submitting-partner mismatch check anywhere else. A sampling-
# DESIGN question (achieved vs. target_households), not a response-quality
# one, so computed from cluster_targets (same source the Coverage Map's
# border and Progress by LGA capping already use), not the cleaning logs.
compute_oversampled_clusters <- function(subs) {
  achieved_flag <- is_achieved(subs)

  # FULL-frame fallback removed (2026-09-02, see cluster_targets above) —
  # psu_hexagons_sf/psu_sites_sf alone now cover 100% of covered clusters.
  cluster_target <- bind_rows(
    st_drop_geometry(psu_hexagons_sf) %>% select(cluster_id, adm1_name, adm2_name, adm2_pcode, pop_type, target_households),
    st_drop_geometry(psu_sites_sf) %>% select(cluster_id, adm1_name, adm2_name, adm2_pcode, pop_type, target_households)
  ) %>%
    distinct(cluster_id, .keep_all = TRUE) %>%
    mutate(target_households = as.numeric(target_households))

  achieved_by_cluster <- subs[achieved_flag, ] %>%
    group_by(matched_cluster_id) %>%
    summarise(achieved_n = n(), submitting_org_ids = paste(sort(unique(org_id)), collapse = ", "), .groups = "drop")

  cluster_target %>%
    left_join(achieved_by_cluster, by = c("cluster_id" = "matched_cluster_id")) %>%
    mutate(achieved_n = coalesce(achieved_n, 0L), submitting_org_ids = coalesce(submitting_org_ids, "")) %>%
    filter(target_households > 0, achieved_n > target_households) %>%
    mutate(surplus = achieved_n - target_households, pct_over_target = achieved_n / target_households - 1) %>%
    arrange(desc(surplus))
}

# Static/unfiltered default, same spirit as progress_by_stratum above — the
# Home page's national headline and the Partner Report's per-partner count
# both want total-to-date, not whatever the sidebar's date filter happens
# to show.
oversampled_clusters <- compute_oversampled_clusters(submissions_raw)

# ---- partners with zero submissions so far (2026-08-27) — moved here from
# reports_partner_digest.R (same reasoning as oversampled_clusters above).
# "Assigned" means actually has an LGA in partner_lga_assignment (excludes
# "other", the coalesce fallback for the one LGA with no confirmed match —
# not a partner anyone can actually follow up with).
PARTNERS_ASSIGNED <- setdiff(names(partner_adm2)[lengths(partner_adm2) > 0], "other")
PARTNERS_NOT_STARTED <- setdiff(PARTNERS_ASSIGNED, submissions_raw$org_id)

# ---- partner-vs-partner progress comparison (Progress Overview tab, added
# 2026-08-30 at Jack's request) — one row per assigned partner: target vs
# achieved to date, their OWN pace since their OWN first submission (not
# the global FIELDING_START — a partner that started late shouldn't look
# artificially behind just because the x-axis starts from day one of the
# whole assessment), and a naive linear projection of their finish date
# against the hard FIELDING_PLANNED_END deadline. v1 only: current pace is
# a whole-period average since the partner's own start, not a trailing
# window — Jack confirmed this is fine for now, a recent-pace variant can
# follow later if the whole-period average proves too slow to react to a
# partner actually speeding up or slowing down.
#
# "Target" here matches partner_progress_by_lga's definition below: every
# stratum in every LGA assigned to this partner (partner_lga_assignment),
# not just LGAs where this partner's own org_id has actually shown up —
# consistent with how the rest of the dashboard scopes a partner's target.
today_for_pace <- max(submissions_raw$submission_date, na.rm = TRUE)

partner_progress_summary <- lapply(PARTNERS_ASSIGNED, function(org) {
  my_adm2 <- partner_adm2[[org]]
  if (is.null(my_adm2)) my_adm2 <- character(0)
  # 2026-09-08: now sums both target_sample (original) and
  # target_sample_current (live) from progress_by_stratum - remaining/
  # pace/status below key off _current, same reasoning as compute_progress_
  # by_stratum()'s own switch above. target_sample (original) carried
  # through to the output tibble for display only.
  totals <- progress_by_stratum %>%
    filter(adm2_pcode %in% my_adm2) %>%
    summarise(target_sample = sum(target_sample, na.rm = TRUE),
              target_sample_current = sum(target_sample_current, na.rm = TRUE),
              achieved_n = sum(achieved_n, na.rm = TRUE),
              collected_n = sum(collected_n, na.rm = TRUE),
              confirmed_deletion_n = sum(confirmed_deletion_n, na.rm = TRUE),
              pending_deletion_n = sum(pending_deletion_n, na.rm = TRUE),
              oversampling_surplus_n = sum(oversampling_surplus_n, na.rm = TRUE))

  start_date <- suppressWarnings(min(submissions_raw$submission_date[submissions_raw$org_id == org], na.rm = TRUE))
  has_started <- is.finite(start_date)
  days_active <- if (has_started) as.numeric(today_for_pace - start_date) + 1 else NA_real_
  current_pace <- if (has_started && days_active > 0) totals$achieved_n / days_active else NA_real_
  remaining <- max(totals$target_sample_current - totals$achieved_n, 0)
  days_left_to_deadline <- as.numeric(FIELDING_PLANNED_END - today_for_pace) + 1
  required_pace <- if (days_left_to_deadline > 0) remaining / days_left_to_deadline else NA_real_
  projected_finish <- if (!is.na(current_pace) && current_pace > 0 && remaining > 0) {
    today_for_pace + ceiling(remaining / current_pace)
  } else if (remaining <= 0) {
    as.Date(NA)
  } else {
    as.Date(NA)
  }

  status <- case_when(
    totals$target_sample_current <= 0 ~ "Complete",
    totals$achieved_n >= totals$target_sample_current ~ "Complete",
    !has_started ~ "Not started",
    is.na(current_pace) || current_pace <= 0 ~ "Behind pace",
    projected_finish <= FIELDING_PLANNED_END ~ "On pace",
    TRUE ~ "Behind pace"
  )

  # Who else is assigned any of this partner's LGAs, if anyone (same
  # coverage_orgs_by_adm2 lookup partner_progress_by_lga's own shared_with
  # uses below) — surfaced because achieved_n/pct_achieved above is the
  # WHOLE LGA's progress, not this partner's own submissions alone. Without
  # this, a partner who hasn't submitted anything yet but shares an LGA
  # with an active partner shows a confusing "Not started" + nonzero %
  # combination with no visible explanation (caught by Jack 2026-08-30:
  # LHI showing ~5% while also "Not started").
  shared_with <- {
    others <- setdiff(unique(unlist(coverage_orgs_by_adm2[my_adm2])), org)
    if (length(others) == 0) "" else paste(unname(ORG_LABELS[others]), collapse = ", ")
  }

  tibble(
    org_id = org, partner_label = unname(ORG_LABELS[org]),
    # Naming convention, consistent with compute_progress_by_stratum() above
    # and partner_progress_by_lga() below: target_sample = ORIGINAL (frozen),
    # target_sample_current = live. Don't let "target_sample" silently mean
    # different things in different functions - that ambiguity is exactly
    # the kind of thing this rebuild exists to close.
    target_sample = totals$target_sample, target_sample_current = totals$target_sample_current,
    achieved_n = totals$achieved_n, collected_n = totals$collected_n,
    confirmed_deletion_n = totals$confirmed_deletion_n, pending_deletion_n = totals$pending_deletion_n,
    oversampling_surplus_n = totals$oversampling_surplus_n,
    pct_achieved = ifelse(totals$target_sample_current > 0, totals$achieved_n / totals$target_sample_current, NA_real_),
    shared_with = shared_with,
    start_date = if (has_started) start_date else as.Date(NA),
    days_active = days_active, current_daily_pace = current_pace, required_daily_pace = required_pace,
    projected_finish_date = projected_finish, status = status
  )
}) %>%
  dplyr::bind_rows() %>%
  # sorted by % of target achieved, lowest first (2026-08-30, per Jack — not
  # by pace: besides being a second, redundant sort key once this one's in
  # place, pace naturally reads as a partner ranking ("worst pace") in a way
  # that could land badly, whereas sorting on the plain % figure doesn't
  # editorialise beyond the number itself).
  arrange(pct_achieved)

# ---- baseline sampling target + revision history (added 2026-08-30, ahead
# of the resampling/exclusion-area changes about to start) — see
# cleaning/real/sanity_checks.R's check_target_revision() for the write
# side. First row is always the original fielding-start baseline (31,506);
# any later row is a dated, reasoned change to the live total. The live
# total itself is never frozen anywhere — it's always just
# sum(strata_frame$target_sample) as computed above — this is purely the
# "here's what it used to be, and why it changed" narration layer for the
# UI, so a partner (or Jack) glancing at Home doesn't just see 31,506
# quietly become a different number with no explanation.
target_revision_log <- read_csv(file.path(DATA_DIR, "TARGET_REVISION_LOG.csv"), show_col_types = FALSE) %>%
  arrange(date)
BASELINE_TARGET_SAMPLE <- target_revision_log$total_target[1]
BASELINE_TARGET_DATE <- target_revision_log$date[1]
HAS_TARGET_REVISION <- nrow(target_revision_log) > 1
LATEST_TARGET_REVISION <- if (HAS_TARGET_REVISION) tail(target_revision_log, 1) else NULL

# ---- "figures as of" caption source — the sampling frame's own version
# stamp (written by 1_sampling, already copied in alongside the frame
# files; see cleaning/real/sanity_checks.R's read_frame_version()), not
# previously surfaced anywhere in the dashboard itself. Falls back to NA
# gracefully if the stamp file isn't present for some reason — every UI
# use of this must handle that (omit the caption, don't error).
FRAME_AS_OF_DATE <- {
  stamp_path <- file.path(INPUT_DIR, "sampling_frame/_frame_version.txt")
  if (file.exists(stamp_path)) {
    lines <- readLines(stamp_path, warn = FALSE)
    m <- grep("^stamped_at:", lines, value = TRUE)
    if (length(m) == 1) sub("^stamped_at: ", "", m) else NA_character_
  } else {
    NA_character_
  }
}
# ready-to-drop-in caption text for any tab showing targets/achieved figures
FRAME_AS_OF_LABEL <- if (!is.na(FRAME_AS_OF_DATE)) {
  paste0("Sampling frame as of ", format(as.Date(substr(FRAME_AS_OF_DATE, 1, 10)), "%d %b %Y"))
} else {
  NA_character_
}

# ---- per-partner progress (for the Partner Report tab) ----------------------

# NB: a partner's "target" here is every stratum (both pop_types) in the
# LGAs assigned to them in partner_lga_assignment — not just LGAs where a
# submission with their org_id has shown up so far, so a partner with zero
# progress in an assigned LGA still sees it listed as a focus area.
partner_progress_by_lga <- function(org_id_val) {
  my_adm2 <- partner_adm2[[org_id_val]]
  if (is.null(my_adm2)) my_adm2 <- character(0)

  progress_by_stratum %>%
    filter(adm2_pcode %in% my_adm2) %>%
    group_by(region, adm1_name, adm2_pcode, adm2_name) %>%
    summarise(
      # 2026-09-08: target_sample = original (unchanged convention),
      # target_sample_current = live - Complete/pct_achieved below now key
      # off the live figure, same as compute_progress_by_stratum() and
      # partner_progress_summary above.
      target_sample = sum(target_sample, na.rm = TRUE),
      target_sample_current = sum(target_sample_current, na.rm = TRUE),
      achieved_n = sum(achieved_n, na.rm = TRUE),
      collected_n = sum(collected_n, na.rm = TRUE),
      confirmed_deletion_n = sum(confirmed_deletion_n, na.rm = TRUE),
      pending_deletion_n = sum(pending_deletion_n, na.rm = TRUE),
      oversampling_surplus_n = sum(oversampling_surplus_n, na.rm = TRUE), .groups = "drop"
    ) %>%
    mutate(
      pct_achieved = ifelse(target_sample_current > 0, achieved_n / target_sample_current, NA_real_),
      status = case_when(
        target_sample_current <= 0 | achieved_n >= target_sample_current ~ "Complete",
        achieved_n > 0 ~ "In progress",
        TRUE ~ "Not started"
      ),
      # who else covers this LGA, if anyone — achieved_n above already
      # includes every covering org's submissions, not just org_id_val's own
      # (see shared_coverage_adm2 above), so this is what makes that visible
      # rather than silently attributed to whichever org's report it's on.
      shared_with = vapply(adm2_pcode, function(pc) {
        others <- setdiff(coverage_orgs_by_adm2[[pc]], org_id_val)
        if (length(others) == 0) "" else paste(unname(ORG_LABELS[others]), collapse = ", ")
      }, character(1))
    ) %>%
    arrange(pct_achieved)
}

partner_quality_summary <- function(org_id_val) {
  df <- submissions_raw %>% filter(org_id == org_id_val)
  tibble(
    submissions = nrow(df),
    completed = sum(df$interview_outcome == "completed"),
    consent_refused = sum(df$interview_outcome == "consent_refused"),
    flagged = sum(df$any_quality_flag),
    flag_rate = ifelse(nrow(df) > 0, mean(df$any_quality_flag), NA_real_),
    avg_duration = mean(df$duration_min, na.rm = TRUE)
  )
}

# ---- per-enumerator rollup (Enumerator Performance tab) ---------------------

compute_enumerator_stats <- function(subs) {
  subs %>%
    filter(!is_duplicate) %>%
    group_by(enum_id) %>%
    summarise(
      org_id = first(org_id),
      state = first(admin1),
      submissions = n(),
      completed = sum(interview_outcome == "completed"),
      consent_refused = sum(interview_outcome == "consent_refused"),
      avg_duration = mean(duration_min, na.rm = TRUE),
      median_duration = median(duration_min, na.rm = TRUE),
      flag_rate = mean(any_quality_flag),
      flagged = sum(any_quality_flag),
      avg_sync_lag_min = mean(sync_lag_min, na.rm = TRUE),
      first_date = min(submission_date, na.rm = TRUE),
      last_date = max(submission_date, na.rm = TRUE),
      days_active = n_distinct(submission_date),
      max_in_a_day = max(table(submission_date)),
      .groups = "drop"
    ) %>%
    mutate(
      avg_per_active_day = ifelse(days_active > 0, submissions / days_active, NA_real_),
      org_label = unname(ORG_LABELS[org_id])
    )
}

# A single interviewer conducting a full ~40min household survey can only
# fit so many in a working day — used to flag implausible daily counts as
# an integrity signal, not proof of fabrication (could also be a very long
# field day, or several short/refused interviews).
MAX_PLAUSIBLE_INTERVIEWS_PER_DAY <- 12

# ---- age heaping (Whipple's Index) — classic demographic data-quality check.
# Ratio of ages ending in 0 or 5 (23-62 range, the standard Whipple age
# band) to what you'd expect if terminal digits were uniform, x100.
# 100 = no heaping, 500 = everyone's age rounded to a multiple of 5.
# UN convention: <105 highly accurate, 105-109.9 fairly accurate,
# 110-124.9 approximate, 125-174.9 rough, 175+ very rough.
whipples_index <- function(ages) {
  ages <- ages[!is.na(ages) & ages >= 23 & ages <= 62]
  if (length(ages) == 0) return(NA_real_)
  heaped <- sum(ages %% 10 %in% c(0, 5))
  (heaped / length(ages)) * 500
}

whipples_label <- function(w) {
  case_when(
    is.na(w) ~ "n/a",
    w < 105 ~ "Highly accurate",
    w < 110 ~ "Fairly accurate",
    w < 125 ~ "Approximate",
    w < 175 ~ "Rough",
    TRUE ~ "Very rough"
  )
}

# ---- exact-GPS-reuse detection (possible fabrication signal) ----------------
# Bit-identical submitted coordinates across >1 submission — continuous GPS
# jitter essentially never coincides by chance, so this is a real signal,
# not a rounding artifact (mirrors how a real cleaning script would compute
# it — there's no upstream "is_fabricated" flag to just read).
find_gps_duplicate_groups <- function(subs) {
  subs %>%
    filter(interview_outcome == "completed", !is.na(latitude_submitted)) %>%
    group_by(latitude_submitted, longitude_submitted) %>%
    filter(n() > 1) %>%
    summarise(
      n_submissions = n(),
      n_enumerators = n_distinct(enum_id),
      enumerators = paste(unique(enum_id), collapse = ", "),
      admin1 = first(admin1),
      admin2_submitted = first(admin2_submitted),
      dates = paste(sort(unique(as.character(submission_date))), collapse = ", "),
      .groups = "drop"
    ) %>%
    arrange(desc(n_submissions))
}

# ---- design assumption: average household size, from the sampling frame's
# own n_pop/N_hh (population / household count used to derive targets) —
# a genuine design assumption to compare the achieved sample against, not
# an external benchmark.
design_avg_hh_size <- function(strata_df = strata_frame) {
  strata_df %>%
    group_by(region, pop_type) %>%
    summarise(design_avg_hh_size = sum(n_pop, na.rm = TRUE) / sum(N_hh, na.rm = TRUE), .groups = "drop")
}
DESIGN_AVG_HH_SIZE_NATIONAL <- sum(strata_frame$n_pop, na.rm = TRUE) / sum(strata_frame$N_hh, na.rm = TRUE)

# ---- shared helpers ----------------------------------------------------------

pct_color <- function(pct) {
  case_when(
    is.na(pct) ~ "#9AA3AF",
    pct >= 1 ~ "#1E7B4D",
    pct >= 0.75 ~ "#4C9A6A",
    pct >= 0.35 ~ "#D99A2B",
    TRUE ~ "#C1443C"
  )
}

fmt_pct <- function(x) ifelse(is.na(x), "-", percent(x, accuracy = 1))
# NA-safe numeric rounding for KPI tiles — added 2026-08-25 after finding
# several KPIs (mod_representativeness.R's household-size boxes,
# mod_enumerator.R's avg-submissions box) rendered the literal string
# "NaN" on an empty filtered slice instead of the app's usual "-", because
# they called round(mean(...)) directly with no NA guard. is.na(NaN) is
# TRUE in R, so this catches both a genuine NA and an empty-vector NaN.
fmt_num <- function(x, digits = 1) ifelse(is.na(x), "-", round(x, digits))

# Small (i) icon + hover-tooltip, for attaching a plain-language definition
# to any figure that could otherwise be misread (added 2026-08-24, for the
# Collected/Achieved distinction — see is_collected()/is_achieved() above).
# Use inside a value_box title or card_header: title = info_title("Label",
# "definition text"). Bare info_icon() is for composing into a header that
# already has its own layout (e.g. a table column name).
#
# `color`: the default (text-muted, a mid-grey) only reads well on light
# backgrounds. bslib's value_box(theme=...) themes here (bs_theme() in
# app.R: primary="#1B2A4A" navy, success="#1E7B4D", warning="#D99A2B")
# render "primary" as a solid dark fill but "success"/"warning" as a much
# lighter tint — text-muted grey has poor contrast on the first, fine on
# the other two (confirmed 2026-08-25, Jack). Pass color = "white" (or
# similar) for a tile on a dark/saturated theme instead of changing the
# shared default, which would just break the cases that already work.
info_icon <- function(definition, color = NULL) {
  bslib::tooltip(
    icon(
      "circle-info",
      class = if (is.null(color)) "text-muted" else NULL,
      style = paste0(
        "font-size: 0.75em; margin-left: 6px; cursor: help;",
        if (!is.null(color)) paste0(" color: ", color, ";") else ""
      )
    ),
    definition,
    placement = "top"
  )
}
info_title <- function(label, definition, icon_color = NULL) {
  div(
    style = "display: flex; align-items: center; justify-content: space-between;",
    span(label), info_icon(definition, color = icon_color)
  )
}

# ---- server-side histogram binning -----------------------------------------
# plotly's type="histogram" ships the RAW column to the browser and bins it
# in JavaScript — fine at today's ~900 rows, but scales linearly with
# submissions (a genuinely avoidable cost once the full ~31,500-row sample
# is in, found in the 2026-08-17 "weak internet" performance review).
# These two helpers pre-bin server-side (one row per bin, not per
# submission) so the four raw-value histograms (mod_integrity.R's hour/
# duration/age, mod_representativeness.R's household size) can use
# type="bar" on the bin counts instead — same visual result, a few dozen
# rows sent instead of tens of thousands.

# One bin per integer value across [from, to] inclusive, zero-filled where
# a value in range has no observations (so the bar chart's x-axis doesn't
# silently skip a gap the way a plain count() would) — matches the old
# xbins = list(start = from - 0.5, end = to + 0.5, size = 1) behaviour
# used by every one of the four charts this replaces.
bin_integer_counts <- function(x, from, to) {
  tibble(value = from:to) %>%
    left_join(tibble(value = round(x)) %>% filter(!is.na(value), value >= from, value <= to) %>% count(value), by = "value") %>%
    mutate(n = coalesce(n, 0L))
}

# Equal-width bins spanning the observed range, matching plotly's own
# nbinsx auto-binning behaviour (used by duration_min, whose range isn't a
# fixed known set of integers the way hour/age/household-size are).
bin_continuous_counts <- function(x, bins = 40) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(tibble(center = numeric(0), n = integer(0)))
  if (min(x) == max(x)) return(tibble(center = x[1], n = length(x))) # single value: no spread to bin over
  breaks <- seq(min(x), max(x), length.out = bins + 1)
  h <- hist(x, breaks = breaks, plot = FALSE, include.lowest = TRUE)
  tibble(center = h$mids, n = h$counts)
}

days_elapsed <- as.numeric(max(submissions_raw$submission_date, na.rm = TRUE) - FIELDING_START) + 1
days_total <- as.numeric(FIELDING_PLANNED_END - FIELDING_START) + 1
days_remaining <- max(0, days_total - days_elapsed)

# ---- modules -----------------------------------------------------------
for (f in list.files("R", pattern = "\\.R$", full.names = TRUE)) source(f)
