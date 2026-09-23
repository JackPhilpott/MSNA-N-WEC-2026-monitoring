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
# FIX 2026-09-11: frame_lga below was hardcoded to "_v5_", which no longer
# exists (current: v7) - would have failed outright the next time this
# one-time prep script was rerun, same bug class as prep_admin3_wards.R.
source("scripts/shared/latest_frame_file.R")

# 2026-09-20 fix: "Solidarité" (missing the trailing "s") was this map's
# key for Partnerscoverage.xlsx's Solidarités column - stale since the
# 2026-08-27 source-file rename (1_sampling/CLAUDE.md, "Solidarités
# partner-name fix"), which corrected the raw Excel header cell itself.
# Every OTHER consumer of that Excel file already uses the corrected
# spelling; this script's own hardcoded copy was simply never updated when
# that rename propagated everywhere else, so `intersect(names(ORG_COL_MAP),
# names(raw))` silently dropped the real "Solidarités" column below,
# meaning their whole LGA assignment fell out with zero warning fired
# (their column read as an unrecognised "chrome" column instead of a
# missing-mapping error, since it partially matched neither list cleanly
# until traced directly). Same failure shape flagged before, still not
# grep'd for across every hardcoded partner-name literal in this repo -
# worth doing that sweep, not just patching this one instance again.
ORG_COL_MAP <- c(
  "FACT" = "fact", "IMC" = "imc", "FHI 360" = "fhi360", "PLAN" = "plan",
  "Street Child of Nigeria" = "street_child", "INTERSOS" = "intersos",
  "JRS" = "jrs", "NRC" = "nrc", "CARE" = "care", "ZOA" = "zoa", "ACF" = "acf",
  "COOPI" = "coopi", "DRC" = "drc", "Save the Children" = "sci",
  "Solidarités" = "si", "IRC" = "irc", "IRC/LHI" = "irc_lhi", "CRS" = "crs",
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
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"),
  show_col_types = FALSE, col_types = cols(.default = "c")
) %>%
  distinct(adm1_name, adm1_pcode, adm2_name, adm2_pcode) %>%
  mutate(norm_key = paste0(str_to_lower(adm1_name), "|", str_squish(str_to_lower(adm2_name))))

norm <- function(x) str_squish(str_to_lower(x))

# MOVED HERE 2026-09-22 (was read below, next to the excluded-LGA lookups;
# before that it sat after still_unmatched - see those blocks' own notes):
# the fuzzy fallback has to be able to recognise a real-but-inactive LGA
# BEFORE it starts guessing, and full_frame is the only source that still
# carries LGAs the design has excluded. frame_lga above is deliberately
# still WORKING-based - that is the ACTIVE-coverage universe that
# partner_lga_assignment.csv is supposed to describe, and widening it would
# make an excluded LGA look actively covered dashboard-wide (see the
# excluded-LGA block's own warning about exactly that).
full_frame <- read_csv(
  latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"),
  show_col_types = FALSE, col_types = cols(.default = "c")
)

# Every (state, LGA) the frame knows AT ALL, active or excluded. A partner
# row naming one of these is a real LGA that simply isn't in the active
# WORKING universe - it must never be fuzzy-matched onto a DIFFERENT,
# active LGA.
#
# FIX 2026-09-22 (Jack, found via the INTERSOS/FACT reconciliation): FACT's
# "Kankara" row (Katsina, excluded from the design) could not exact-match,
# because frame_lga is WORKING-based and WORKING omits excluded LGAs
# entirely. The Jaro-Winkler fallback then found "Kankia" - a different,
# real, ACTIVE Katsina LGA that belongs to IMC - at distance 0.1508, under
# the 0.25 threshold, and silently assigned FACT to it. That credited FACT
# with Kankia's entire 198-interview target plus its achieved interviews on
# the dashboard, and made FACT's dashboard total disagree with their own
# workbook. Kukawa sat at exactly 0.250 and escaped only because the
# threshold test is a strict `<` - i.e. the class of bug was one rounding
# step away from firing twice. Keyed on "the frame knows this name" rather
# than a Kankara/Kankia special case, so every current and future
# excluded-LGA row is protected by the same rule.
frame_known_lga_keys <- full_frame %>%
  distinct(adm1_name, adm2_name) %>%
  mutate(norm_key = paste0(str_to_lower(adm1_name), "|", str_squish(str_to_lower(adm2_name)))) %>%
  pull(norm_key)

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
    # see frame_known_lga_keys above (2026-09-22 Kankara->Kankia fix): a row
    # naming an LGA the frame genuinely has, just not in the active WORKING
    # universe, is NOT a naming mismatch and must not be guessed at. It
    # falls through to still_unmatched, where the severity split already
    # classifies it as expected/by-design. Tested here rather than with an
    # early return(), which isn't reliable inside do()'s evaluation.
    if (nrow(candidates) == 0 || row$norm_key %in% frame_known_lga_keys) {
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

# 2026-09-16 (Jack, via cross-session flag): Guzamala showed "Not partner-
# assigned" on the dashboard despite FACT covering it - traced to this
# script relying EXCLUSIVELY on the manually-maintained Partnerscoverage.xlsx,
# which predates the MSNA Light arrangement and was simply never updated for
# it (no naming-mismatch warning fired above because this isn't a mismatch
# case, it's a complete absence - Guzamala never appears in the spreadsheet
# at all). Root-cause fix, not a patch: derive assignment ALSO from the
# sampling frame's own `partners_covering` column (covered rows only) and
# UNION it with the spreadsheet-derived rows above, so any future gap of
# this shape (a new arrangement added to the frame but not yet to the
# spreadsheet) closes itself automatically instead of needing someone to
# remember a second place to update. Verified before writing this: of
# Guzamala/Abadam/Nganzai (the three MSNA Light LGAs), only Guzamala was
# actually missing - Abadam and Nganzai already had a correct `fact` row via
# the spreadsheet path, so this union is additive, not a replacement of
# rows that were already right.
#
# Moved earlier (2026-09-20, Jack's decision relayed via Coordinator) from
# its original position after `still_unmatched` below: the excluded-LGA
# lookups built from `full_frame` are now needed BEFORE still_unmatched
# fires its warning, not just after, so the severity-split below can check
# each still-unmatched row against them. See that block's own comment for
# the full reasoning.
# full_frame itself is read further up now (2026-09-22) - the fuzzy
# fallback needs it before it guesses. FRAME_PARTNER_NAME_MAP and the
# excluded-LGA lookups below are unchanged and still use it here.

# Name -> org_id, reusing ORG_COL_MAP (the same spreadsheet-column vocabulary,
# now that its "Solidarités" key matches the frame's own spelling directly -
# see the 2026-09-20 fix above) plus one alias the frame's own
# partners_covering spelling still needs that ORG_COL_MAP doesn't cover on
# its own: standalone "LHI" (ORG_COL_MAP only ever had the joint "IRC/LHI"
# spreadsheet column, never a standalone "LHI" one, since Partnerscoverage.xlsx
# never had one - expand_joint_irc_lhi() above already treats "lhi" as a real,
# valid org_id for the joint case, so reusing it here for the frame's own
# "IRC, LHI" multi-partner cell, comma-separated - a different separator from
# the spreadsheet's single joint column, checked directly against the frame's
# actual distinct values before writing this, not assumed). Used by both the
# excluded-LGA lookups right below and the Guzamala-style union further down.
FRAME_PARTNER_NAME_MAP <- c(ORG_COL_MAP, "LHI" = "lhi")

# 2026-09-16 (Jack, via cross-session flag): 8 LGAs that ARE genuinely
# excluded from the design (accessibility_loss_below_population_threshold,
# zero covered rows — Borno/Gubio+Kukawa, Yobe/Gujba, Sokoto/Isa+Kebbe+
# Sabon Birni, Kebbi/Sakaba+Shanga) showed bare "Not partner-assigned" on
# the dashboard — technically accurate (no ACTIVE org_id above covers
# them) but loses the "was assigned, then excluded" context, which reads
# as ambiguous/worse than it is. NOT the same bug shape as Guzamala above
# (that was a stale-derived-file gap for a LGA that's actually covered);
# this is structural — these LGAs correctly have zero rows in `out` below
# because `frame_lga` (used for exact/fuzzy matching above) is built from
# the WORKING frame, which omits excluded LGAs entirely, so their
# Partnerscoverage.xlsx row can never match and always lands in
# still_unmatched even though it's not a naming bug. Two SEPARATE, small
# lookups derived here (deliberately NOT unioned into `out`/
# partner_lga_assignment.csv itself, which drives real active-coverage
# logic — target scoping, shared_coverage_adm2, TOTAL_ACCESSIBILITY_PARTNERS,
# filter_base — dashboard-wide; folding a historical/excluded partner in
# there would make an excluded LGA look ACTIVELY covered everywhere, not
# just relabel it): one flags which adm2_pcodes are excluded at all
# (regardless of whether a historical partner is on record), the other
# carries the historical partner(s) when known. Both read from the FULL
# frame's own `partners_covering` (same vocabulary/mapping as frame_derived
# further down), not Partnerscoverage.xlsx, since the FULL frame retains
# partners_covering on excluded rows and the xlsx's raw declaration would
# need the same re-matching machinery that's structurally guaranteed to
# fail here. Consumed by dashboard_app/global.R's partner_coverage_label()
# fallback, AND (2026-09-20) by the still_unmatched severity-split below.
excluded_lgas <- full_frame %>%
  filter(coverage_status == "excluded") %>%
  distinct(adm1_pcode, adm1_name, adm2_pcode, adm2_name)

excluded_long <- full_frame %>%
  filter(coverage_status == "excluded", !is.na(partners_covering), partners_covering != "") %>%
  distinct(adm1_pcode, adm1_name, adm2_pcode, adm2_name, partners_covering) %>%
  separate_rows(partners_covering, sep = ",\\s*") %>%
  mutate(partner_name = str_squish(partners_covering))

unmapped_excluded_names <- setdiff(unique(excluded_long$partner_name), names(FRAME_PARTNER_NAME_MAP))
if (length(unmapped_excluded_names) > 0) {
  msg <- paste0(
    "prep_partner_lga_assignment.R: excluded LGAs' partners_covering has name(s) not recognised: ",
    paste(unmapped_excluded_names, collapse = ", "),
    ". Add to FRAME_PARTNER_NAME_MAP or ORG_COL_MAP, or these LGAs' 'Excluded (was: ...)' label silently falls back to 'no prior assignment on record'."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  write_sanity_warnings(msg, source_label = "prep_partner_lga_assignment.R")
}

excluded_lga_prior_partners <- excluded_long %>%
  filter(partner_name %in% names(FRAME_PARTNER_NAME_MAP)) %>%
  mutate(org_id = unname(FRAME_PARTNER_NAME_MAP[partner_name])) %>%
  distinct(adm1_pcode, adm1_name, adm2_pcode, adm2_name, org_id) %>%
  arrange(adm1_name, adm2_name, org_id)

write_csv(excluded_lgas, "input_data/partner_coverage/excluded_lgas.csv")
write_csv(excluded_lga_prior_partners, "input_data/partner_coverage/excluded_lga_prior_partners.csv")

cat("\nWrote", nrow(excluded_lgas), "excluded-LGA row(s) (",
    length(unique(excluded_lgas$adm2_pcode)), "distinct excluded LGAs ), of which",
    length(unique(excluded_lga_prior_partners$adm2_pcode)), "have a historical partner on record.\n")

still_unmatched <- unmatched %>%
  anti_join(bind_rows(matched_exact, fuzzy_matched) %>% select(region, state, lga, org_id), by = c("region", "state", "lga", "org_id"))

# 2026-09-20 (Jack's decision, relayed via Coordinator, in response to a
# review flag that this warning's own wording ("will show as 'Not partner-
# assigned'") was misleading for the 8 excluded LGAs above — they don't
# actually show that bare label, they show "Excluded (was: X)" via the
# excluded_lga_prior_partners.csv fallback, so the warning read as an open
# problem when it wasn't one). Jack chose the logic fix over a wording-only
# edit: split still_unmatched by whether it's already expected, structural,
# by-design behavior (excluded from the design AND a historical partner is
# already on record — genuinely nothing to fix, silence is correct) versus
# everything else (a real naming mismatch on a still-fieldable LGA, or an
# excluded LGA with no prior partner on record — both worth a human
# actually looking at, same as before).
excluded_with_partner_keys <- excluded_lga_prior_partners %>%
  distinct(adm1_name, adm2_name) %>%
  mutate(norm_key = paste0(str_to_lower(adm1_name), "|", str_squish(str_to_lower(adm2_name)))) %>%
  pull(norm_key)

still_unmatched <- still_unmatched %>%
  mutate(expected_excluded = norm_key %in% excluded_with_partner_keys)

still_unmatched_quiet <- still_unmatched %>% filter(expected_excluded)
still_unmatched_loud <- still_unmatched %>% filter(!expected_excluded)

if (nrow(still_unmatched_quiet) > 0) {
  cat("INFO: ", nrow(still_unmatched_quiet),
      " partner-LGA row(s) map to LGA(s) already excluded from the design with a historical partner on record (expected, by-design - see excluded_lga_prior_partners.csv / the dashboard's 'Excluded (was: ...)' label, not a bug): ",
      paste(unique(paste0(still_unmatched_quiet$state, "/", still_unmatched_quiet$lga)), collapse = "; "), ".\n", sep = "")
}

if (nrow(still_unmatched_loud) > 0) {
  msg <- paste0(
    nrow(still_unmatched_loud), " partner-LGA row(s) could not be matched to the sampling frame (tried exact, substring, and fuzzy): ",
    paste(unique(paste0(still_unmatched_loud$state, "/", still_unmatched_loud$lga)), collapse = "; "),
    ". These will show as 'Not partner-assigned' on the dashboard until fixed — check for a naming mismatch against the current stage2 sampling frame (input_data/sampling_frame/, latest _v<N>_WORKING.csv)."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  write_sanity_warnings(msg, source_label = "prep_partner_lga_assignment.R")
}

frame_covering <- full_frame %>%
  filter(coverage_status == "covered", !is.na(partners_covering), partners_covering != "") %>%
  distinct(adm1_pcode, adm1_name, adm2_pcode, adm2_name, partners_covering)

# FRAME_PARTNER_NAME_MAP already defined above, alongside full_frame and the
# excluded-LGA lookups (moved up 2026-09-20 so still_unmatched's severity
# split could use them) — reused here unchanged.
frame_long <- frame_covering %>%
  separate_rows(partners_covering, sep = ",\\s*") %>%
  mutate(partner_name = str_squish(partners_covering))

unmapped_names <- setdiff(unique(frame_long$partner_name), names(FRAME_PARTNER_NAME_MAP))
if (length(unmapped_names) > 0) {
  msg <- paste0(
    "prep_partner_lga_assignment.R: frame's partners_covering has name(s) not recognised: ",
    paste(unmapped_names, collapse = ", "),
    ". Add to FRAME_PARTNER_NAME_MAP or ORG_COL_MAP, or these LGAs' frame-derived assignment is silently skipped."
  )
  cat("WARNING: ", msg, "\n", sep = "")
  write_sanity_warnings(msg, source_label = "prep_partner_lga_assignment.R")
}

frame_derived <- frame_long %>%
  filter(partner_name %in% names(FRAME_PARTNER_NAME_MAP)) %>%
  mutate(org_id = unname(FRAME_PARTNER_NAME_MAP[partner_name])) %>%
  select(adm1_pcode, adm1_name, adm2_pcode, adm2_name, org_id)

spreadsheet_only <- bind_rows(matched_exact, fuzzy_matched) %>%
  select(adm1_pcode, adm1_name, adm2_pcode, adm2_name, org_id) %>%
  distinct()

out <- spreadsheet_only %>%
  bind_rows(frame_derived) %>%
  distinct(adm1_pcode, adm1_name, adm2_pcode, adm2_name, org_id) %>%
  arrange(adm1_name, adm2_name, org_id)

cat("\nFrame-derived union added", nrow(out) - nrow(spreadsheet_only),
    "row(s) the spreadsheet alone didn't already have.\n")

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
    # 2026-09-20: split into the two severities still_unmatched now carries
    # (see that block's own comment above) rather than one combined count -
    # n_unmatched_loud is the one actually worth watching; n_unmatched_quiet
    # is expected, by-design "excluded with a known prior partner" noise.
    n_unmatched_loud = nrow(still_unmatched_loud),
    n_unmatched_quiet_excluded = nrow(still_unmatched_quiet)
  ),
  "input_data/partner_coverage/partner_lga_assignment_meta.rds"
)

cat("\nWrote", nrow(out), "partner-LGA assignment rows,",
    length(unique(out$adm2_pcode)), "distinct LGAs,",
    length(unique(out$org_id)), "distinct partners.\n")
print(out %>% count(org_id, sort = TRUE))
