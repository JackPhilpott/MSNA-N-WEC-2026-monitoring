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

# Real data (cleaning/real/prep_real_submissions.R) is preferred whenever
# present; mock data (cleaning/mock/generate_mock_submissions.R) is the
# fallback for local dev/demoing before real submissions exist, or if the
# real adapter hasn't been re-run for the day. Same column contract either
# way, so nothing downstream needs to know which one it got.
USE_REAL_DATA <- file.exists(file.path(DATA_DIR, "real_submissions.csv"))
submissions_file <- if (USE_REAL_DATA) "real_submissions.csv" else "mock_submissions.csv"
meta_file <- if (USE_REAL_DATA) "real_meta.rds" else "mock_meta.rds"

submissions_raw <- read_csv(file.path(DATA_DIR, submissions_file), show_col_types = FALSE) %>%
  mutate(
    submission_date = as.Date(submission_date),
    start_datetime = as_datetime(start_datetime),
    end_datetime = as_datetime(end_datetime)
  )

mock_meta <- tryCatch(readRDS(file.path(DATA_DIR, meta_file)), error = function(e) list(is_mock_data = TRUE))
IS_MOCK_DATA <- isTRUE(mock_meta$is_mock_data)

FIELDING_START <- min(submissions_raw$submission_date, na.rm = TRUE)

strata_frame <- read_csv(
  file.path(INPUT_DIR, "sampling_frame/NGA_MSNA_2026_strata_level_sampling_frame_v2_WORKING.csv"),
  show_col_types = FALSE
)

# Single source of truth for the two headline design numbers — every place
# that used to hardcode or separately recompute these (Home's intro
# paragraph, "At a glance", "Today's snapshot") reads from here instead, so
# they can't drift out of sync with each other or with the sampling frame
# again the way the intro's hardcoded "31,051"/old FIELDING dates did.
TOTAL_PLANNED_INTERVIEWS <- sum(strata_frame$target_sample, na.rm = TRUE)
TOTAL_COVERED_LGAS <- length(unique(strata_frame$adm2_pcode))

household_frame <- read_csv(
  file.path(INPUT_DIR, "sampling_frame/NGA_MSNA_2026_stage2_sampling_frame_v2_WORKING.csv"),
  show_col_types = FALSE,
  col_types = cols(.default = "c")
) %>%
  mutate(across(c(latitude, longitude, target_households), as.numeric))

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
# The single definition of "achieved" (counts toward a stratum's target)
# used everywhere the dashboard reports achieved-vs-target: completed, not
# a later duplicate copy, AND successfully linked to a sampling frame point
# — an unmatched submission can't be attributed to any specific stratum's
# target, so it must never be counted as achieved anywhere, even in a
# tile/chart that isn't literally built from compute_progress_by_stratum()
# below. Use this instead of writing the filter condition out again.
is_achieved <- function(df) {
  df$interview_outcome == "completed" & !df$is_duplicate & !is.na(df$matched_survey_id)
}

compute_progress_by_stratum <- function(subs) {
  completed_matched <- subs %>% filter(is_achieved(.))

  achieved <- completed_matched %>% count(matched_strata_id, name = "achieved_n")
  # separate count (not pivot_wider) so a filtered subset with zero reserve
  # rows just produces a zero-row table, not a missing/erroring column
  achieved_reserve <- completed_matched %>%
    filter(matched_status == "reserve") %>%
    count(matched_strata_id, name = "achieved_reserve_n")
  achieved <- achieved %>% left_join(achieved_reserve, by = "matched_strata_id")

  strata_frame %>%
    left_join(achieved, by = c("strata_id" = "matched_strata_id")) %>%
    mutate(
      achieved_n = coalesce(achieved_n, 0L),
      achieved_reserve_n = coalesce(achieved_reserve_n, 0L),
      pct_reserve_used = ifelse(achieved_n > 0, achieved_reserve_n / achieved_n, NA_real_),
      pct_achieved = ifelse(target_sample > 0, achieved_n / target_sample, NA_real_),
      status = case_when(
        target_sample <= 0 | achieved_n >= target_sample ~ "Complete",
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
    summarise(target_sample = sum(target_sample, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE), .groups = "drop") %>%
    mutate(
      pct_achieved = ifelse(target_sample > 0, achieved_n / target_sample, NA_real_),
      status = case_when(
        target_sample <= 0 | achieved_n >= target_sample ~ "Complete",
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
