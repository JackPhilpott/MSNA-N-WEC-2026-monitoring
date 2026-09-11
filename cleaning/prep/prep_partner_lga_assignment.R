# One-time prep: reshape input_data/partner_coverage/Partnerscoverage.xlsx
# (wide, one column per partner org, one sheet per region: NE/NW/NC) into a
# long adm2_pcode x org_id assignment table, matched against the sampling
# frame's own admin names/pcodes (same source file 1_sampling used to derive
# coverage_status, but raw LGA spellings here predate that reconciliation,
# so fuzzy-matching per state is used as a fallback after exact matching).
#
# Output: input_data/partner_coverage/partner_lga_assignment.csv
# One row per (adm1_pcode, adm2_pcode, org_id) the raw file marks assigned.
# Not every LGA has a partner marked (matches the 176/323 WORKING coverage
# split) — LGAs with no row here are just not partner-assigned.
#
# **"IRC/LHI" joint column**: Partnerscoverage.xlsx tracks 4 LGAs (Isa, Sabon
# Birni, Tangaza, Zuru) under one combined "IRC/LHI" column — a coordination-
# level decision, confirmed 2026-08-15: these two orgs share the workload in
# these LGAs and haven't fixed how they'll split individual sample points
# between themselves. But IRC and LHI are separate organisations with their
# own enumeration teams, and the KoBo tool's org_id question (`l_org_id`) is
# a single-select with `irc` and `lhi` as two distinct real values — there is
# no "irc_lhi" option an enumerator could ever submit. So instead of writing
# one row with a made-up "irc_lhi" code (which would never match a real
# submission), each "IRC/LHI"-marked LGA is expanded into two rows, one for
# `irc` and one for `lhi` — both orgs see the LGA as fully theirs (matching
# how neither has claimed specific points), and a real submission from
# either org attributes correctly regardless of which of them collected it.
#
# Rerun only if Partnerscoverage.xlsx changes.
#
# 2026-08-21: hardened after a real, live bug — CARE's "Eggon" (Nasarawa)
# row wasn't matching the frame's "Nasarawa-Eggon" by exact OR fuzzy match,
# so that LGA was silently showing as "Not partner-assigned" on the
# dashboard. Added a substring-containment match tier (see the
# fuzzy_matched block below for the full story and why direction matters),
# and any column or LGA row that still can't be matched now writes to the
# same persistent, loudly-re-announced data/SANITY_WARNINGS.txt that
# prep_real_submissions.R uses, instead of a console cat() nobody may be
# watching (this script isn't part of the automated daily chain).

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(stringdist)
  library(readr)
})

# Reused for its persistent, loudly-re-announced warning file (data/
# SANITY_WARNINGS.txt) — added 2026-08-21 so the two failure classes below
# (an unmapped partner column, an LGA name that can't be matched to the
# frame) can no longer just scroll past in a console nobody's watching.
# This script is a manual one-off ("rerun only if Partnerscoverage.xlsx
# changes", not part of the daily chain), which is exactly why a
# console-only warning here is riskier than the equivalent in
# prep_real_submissions.R: there's no guarantee anyone's even looking at
# stdout when it runs.
source("cleaning/real/sanity_checks.R")

ORG_COL_MAP <- c(
  "FACT" = "fact", "IMC" = "imc", "FHI 360" = "fhi360", "PLAN" = "plan",
  "Street Child of Nigeria" = "street_child", "INTERSOS" = "intersos",
  "JRS" = "jrs", "NRC" = "nrc", "CARE" = "care", "ZOA" = "zoa", "ACF" = "acf",
  "COOPI" = "coopi", "DRC" = "drc", "Save the Children" = "sci",
  "Solidarité" = "si", "IRC" = "irc", "IRC/LHI" = "irc_lhi", "CRS" = "crs",
  "Malteser" = "malteser", "MDM" = "mdm"
)

# Non-partner "chrome" columns present alongside the org columns on every
# region sheet (running totals, notes) — always expected to be absent from
# org_cols below, not a sign of anything wrong. Anything ELSE missing from
# both this and ORG_COL_MAP above IS a sign something's wrong (a new/
# renamed partner column) and used to vanish with zero warning — exactly
# the failure shape that caused the "irc_lhi" mis-mapping this file's
# header already documents. See KNOWN_NON_ORG_COLUMNS usage in
# read_region_sheet() below.
KNOWN_NON_ORG_COLUMNS <- c("Region", "State", "LGA", "COUNT", "Number of Partners", "Surveys")

# "irc_lhi" isn't a real, submittable org_id (see header note) — every row
# tagged with it is expanded into one `irc` row and one `lhi` row instead.
expand_joint_irc_lhi <- function(df) {
  joint <- df %>% filter(org_id == "irc_lhi")
  bind_rows(
    df %>% filter(org_id != "irc_lhi"),
    joint %>% mutate(org_id = "irc"),
    joint %>% mutate(org_id = "lhi")
  )
}

frame_lga <- read_csv(
  "input_data/sampling_frame/NGA_MSNA_2026_stage2_sampling_frame_v5_WORKING.csv",
  show_col_types = FALSE, col_types = cols(.default = "c")
) %>%
  distinct(adm1_name, adm1_pcode, adm2_name, adm2_pcode) %>%
  mutate(norm_key = paste0(str_to_lower(adm1_name), "|", str_squish(str_to_lower(adm2_name))))

norm <- function(x) str_squish(str_to_lower(x))

read_region_sheet <- function(sheet) {
  raw <- read_excel("input_data/partner_coverage/Partnerscoverage.xlsx", sheet = sheet)
  names(raw) <- str_squish(names(raw))
  org_cols <- intersect(names(ORG_COL_MAP), names(raw))

  # readxl auto-names a blank header "...N" (N = column position) — always
  # expected, filtered out before checking for anything genuinely unknown.
  unexpected <- setdiff(names(raw), c(KNOWN_NON_ORG_COLUMNS, org_cols))
  unexpected <- unexpected[!str_detect(unexpected, "^\\.\\.\\.\\d+$")]
  if (length(unexpected) > 0) {
    msg <- paste0(
      "PARTNER SHEET '", sheet, "': column(s) not recognised as a partner org or known chrome column, silently ignored until now: ",
      paste(unexpected, collapse = ", "),
      ". If this is a new or renamed partner, add it to ORG_COL_MAP in cleaning/prep/prep_partner_lga_assignment.R."
    )
    cat("WARNING: ", msg, "\n", sep = "")
    write_sanity_warnings(msg, source_label = "prep_partner_lga_assignment.R")
  }

  raw %>%
    select(Region, State, LGA, all_of(org_cols)) %>%
    pivot_longer(cols = all_of(org_cols), names_to = "org_label", values_to = "marked") %>%
    filter(!is.na(marked) & str_squish(marked) != "") %>%
    mutate(org_id = unname(ORG_COL_MAP[org_label])) %>%
    select(region = Region, state = State, lga = LGA, org_id)
}

partner_long <- bind_rows(
  read_region_sheet("NE"),
  read_region_sheet("NW"),
  read_region_sheet("NC")
) %>%
  expand_joint_irc_lhi() %>%
  mutate(norm_key = paste0(norm(state), "|", norm(lga)))

# exact match first
matched_exact <- partner_long %>% inner_join(frame_lga, by = "norm_key", suffix = c("", "_frame"))

unmatched <- partner_long %>% anti_join(frame_lga, by = "norm_key")

# fuzzy fallback: nearest LGA name within the same state (by normalized state match).
# A substring-containment check runs FIRST, ahead of Jaro-Winkler distance —
# added 2026-08-21 after "Eggon" (Partnerscoverage.xlsx, Nasarawa, marked
# for CARE) failed to match the frame's "Nasarawa-Eggon" by either exact or
# JW-fuzzy match (JW distance 0.58 — WORSE than an unrelated LGA, because
# Winkler's prefix bonus only rewards a SHARED PREFIX; "eggon" shares none
# with "nasarawa-eggon" despite being a perfect suffix match). JW is built
# for typo-style near-misses (confirmed still working correctly on this
# sheet's actual typo/spelling cases: curly-vs-straight apostrophes in
# "Mai'adua"/"Jema'a", "Kauran"/"Kaura", "Barkin"/"Barikin"), not for an
# informal short name vs. a formal compound one — substring containment
# catches that class instead.
#
# Direction matters and must stay ONE-WAY: the partner sheet's (possibly
# informal/short) name must be contained IN the frame's name, never the
# reverse. Checking both directions initially seemed safe (manually traced
# against all 8 pre-existing JW-matched rows with no apparent change) but
# broke a REAL row on first actual run: Kebbi has both a standalone "Dandi"
# LGA and a separate "Arewa-Dandi" LGA, and the partner sheet's "Arewa
# Dandi" row contains "Dandi" as a substring — the reverse direction
# matched it to the wrong, unrelated "Dandi" LGA and silently dropped the
# correct "Arewa-Dandi" (FACT) assignment. Exact matching already runs
# BEFORE this, so this substring tier only ever sees rows that already
# failed to exact-match anything — meaning "candidate contained in row" is
# inherently the risky direction (a short real LGA name coincidentally
# substring-matching a longer, unrelated row) while "row contained in
# candidate" stays safe (exact match already ruled out row itself being a
# real, different, standalone LGA).
fuzzy_matched <- unmatched %>%
  rowwise() %>%
  do({
    row <- .
    candidates <- frame_lga %>% filter(str_to_lower(adm1_name) == norm(row$state))
    if (nrow(candidates) == 0) {
      tibble()
    } else {
      norm_row <- norm(row$lga)
      norm_candidates <- norm(candidates$adm2_name)
      contains_hit <- which(str_detect(norm_candidates, fixed(norm_row)))
      if (length(contains_hit) == 1) {
        bind_cols(row, candidates[contains_hit, ])
      } else {
        d <- stringdist(norm_row, norm_candidates, method = "jw")
        best <- which.min(d)
        if (d[best] < 0.25) {
          bind_cols(row, candidates[best, ])
        } else {
          tibble()
        }
      }
    }
  }) %>%
  ungroup()

still_unmatched <- unmatched %>%
  anti_join(bind_rows(matched_exact, fuzzy_matched) %>% select(region, state, lga, org_id), by = c("region", "state", "lga", "org_id"))

if (nrow(still_unmatched) > 0) {
  msg <- paste0(
    nrow(still_unmatched), " partner-LGA row(s) could not be matched to the sampling frame (tried exact, substring, and fuzzy): ",
    paste(unique(paste0(still_unmatched$state, "/", still_unmatched$lga)), collapse = "; "),
    ". These will show as 'Not partner-assigned' on the dashboard until fixed — check for a naming mismatch against input_data/sampling_frame/NGA_MSNA_2026_stage2_sampling_frame_v5_WORKING.csv."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  write_sanity_warnings(msg, source_label = "prep_partner_lga_assignment.R")
}

out <- bind_rows(matched_exact, fuzzy_matched) %>%
  distinct(adm1_pcode, adm1_name, adm2_pcode, adm2_name, org_id) %>%
  arrange(adm1_name, adm2_name, org_id)

write_csv(out, "input_data/partner_coverage/partner_lga_assignment.csv")

# Mirrors real_meta.rds's shape/purpose — see prep_psu_geometries.R's
# header note (2026-08-21) for why: no output file here previously recorded
# when/from-what it was generated, so a stale or silently-changed
# assignment was undetectable after the fact.
saveRDS(
  list(
    generated_at = Sys.time(),
    source_file = normalizePath("input_data/partner_coverage/Partnerscoverage.xlsx"),
    source_modified = file.info("input_data/partner_coverage/Partnerscoverage.xlsx")$mtime,
    n_rows = nrow(out),
    n_lgas = length(unique(out$adm2_pcode)),
    n_partners = length(unique(out$org_id)),
    n_unmatched = nrow(still_unmatched)
  ),
  "input_data/partner_coverage/partner_lga_assignment_meta.rds"
)

cat("\nWrote", nrow(out), "partner-LGA assignment rows,",
    length(unique(out$adm2_pcode)), "distinct LGAs,",
    length(unique(out$org_id)), "distinct partners.\n")
print(out %>% count(org_id, sort = TRUE))
