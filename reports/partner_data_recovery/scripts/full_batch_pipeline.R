# ==============================================================================
# Rebuilt 2026-09-06 (was FROZEN since 2026-09-03 — see git history for the
# original, kept as reference/no longer here). Two things were wrong with the
# frozen version, both fixed here:
#   1. It read three precomputed intermediates (gps_full_nonidp.rds/idp_full.
#      rds/full_metrics_final.rds) from a session-tied Claude scratchpad that
#      no longer exists, plus the sampling frame's superseded v2 files.
#   2. Confirmed Deletions / Missing HH Listings were built from two static,
#      disconnected snapshots (revised_deletion_log_for_resampling_2026-08-30_
#      v2.csv, cleaning/combined_deletion_log.rds) instead of the live
#      recovery_issue_tracker.csv state machine.
# Every OTHER sheet's actual matching/scoring/flagging logic (haversine
# candidate search, scorecard, enumerator-flag rules) is unchanged from the
# frozen version — only where its inputs come from changed.
#
# ---- Sources (read-only) ----------------------------------------------------
# - data/real_submissions.csv — replaces gps_full_nonidp.rds/idp_full.rds/
#   full_metrics_final.rds entirely. Extended 2026-09-06 (prep_real_
#   submissions.R) to carry the raw claim fields (non_idp_point_id,
#   idp_hh_number_from_listing, idp_walk_position, claim_group_size,
#   dist_to_claimed_device_m) these sheets need — these are the ENUMERATOR'S
#   OWN claimed point/listing identity (already NG037-repaired), a different
#   concept from matched_survey_id/matched_cluster_id (the post-hoc GPS
#   match) — the two can legitimately disagree, which is exactly what these
#   sheets exist to catch. admin1/admin2_submitted/admin3_submitted/
#   submission_date are already-translated real names, so no separate
#   raw_data.xlsx/geo_lookup.rds join is needed any more either (both
#   removed).
# - input_data/sampling_frame/*_v{N}_FULL.csv / *_v{N}_WORKING.csv — highest
#   version number present is used (resolve_latest_frame() below), not a
#   hardcoded version, so this can't silently rot at the next resample the
#   way the v2 hardcode did.
# - reports/partner_data_recovery/scripts/recovery_issue_tracker.csv (via
#   issue_tracker.R) — Confirmed Deletions / Missing HH Listings source, per
#   the deletion/recovery-confirmation model (see issue_tracker.R's header).
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(purrr); library(openxlsx); library(scales); library(stringr); library(tidyr); library(readxl)})
mon_dir <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring"
source(file.path(mon_dir, "reports/partner_data_recovery/scripts/issue_tracker.R"))

# BUG FIX 2026-09-06 22:xx (found while reviewing DRC/ACF/FACT's returned
# workbooks - all three showed CONFIRMED Listing Numbers wildly exceeding
# "Total Numbers Available in Cluster", which turned out to be a REAL,
# already-diagnosed-and-fixed bug this rebuild had silently reintroduced.
# The original frozen full_batch_pipeline.R capped IDP availability at
# seq_len(target_households) - Jack found this exact bug 2026-09-03
# inspecting ZOA's copy (target_households is a downstream SAMPLE size, not
# the real household listing size a Tier-1 enumerator produces) and it was
# fixed same day in real_hh_listing.R, which reads the actual HH Listing
# RandomSelect KoBo tool export (primary_list + reserve_list = the real
# drawn pool) rather than assuming a 1..target_households range. This
# rebuild didn't know real_hh_listing.R existed and reverted to the
# original buggy seq_len(target_households) approach - fixed by wiring it
# in properly here instead. See real_hh_listing.R's own header for the full
# history/rationale.
source(file.path(mon_dir, "reports/partner_data_recovery/scripts/real_hh_listing.R"))

haversine_m <- function(lat1, lon1, lat2, lon2) {
  R <- 6371000; to_rad <- pi/180
  dlat <- (lat2-lat1)*to_rad; dlon <- (lon2-lon1)*to_rad
  a <- sin(dlat/2)^2 + cos(lat1*to_rad)*cos(lat2*to_rad)*sin(dlon/2)^2
  2*R*asin(pmin(1, sqrt(a)))
}

# ---- dynamic frame version resolution (2026-09-06) -------------------------
# Picks the highest _v<N>_ file present rather than a hardcoded version - the
# frozen script's own hardcoded v2 (superseded by v5 before anyone rebuilt
# it) is exactly the rot this avoids at the next resample.
frame_dir <- file.path(mon_dir, "input_data/sampling_frame")
resolve_latest_frame <- function(pattern) {
  files <- list.files(frame_dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0) stop("resolve_latest_frame(): no file matching '", pattern, "' in ", frame_dir)
  versions <- as.integer(str_match(basename(files), "_v(\\d+)_")[, 2])
  files[which.max(versions)]
}
frame_all <- read_csv(resolve_latest_frame("^NGA_MSNA_2026_stage2_sampling_frame_v\\d+_FULL\\.csv$"), show_col_types = FALSE)
strata_frame <- read_csv(resolve_latest_frame("^NGA_MSNA_2026_strata_level_sampling_frame_v\\d+_WORKING\\.csv$"), show_col_types = FALSE)
partner_lga <- read_csv(file.path(mon_dir, "input_data/partner_coverage/partner_lga_assignment.csv"), show_col_types = FALSE)

frame_nonidp <- frame_all %>% filter(pop_type == "non_idp") %>%
  select(survey_id, cluster_id, adm1_pcode, adm1_name, adm2_name, adm3_name, latitude, longitude)

# ---- shared reference data ----
full_all <- read_csv(file.path(mon_dir, "data/real_submissions.csv"), show_col_types = FALSE, guess_max = 100000) %>%
  rename(uuid = submission_uuid)
claimed_ids_national <- unique(full_all$non_idp_point_id[!is.na(full_all$non_idp_point_id)])

gps_all <- full_all %>%
  filter(pop_type == "non_idp", !is.na(dist_to_claimed_device_m)) %>%
  rename(cluster_id = matched_cluster_id, lat = latitude_submitted, lon = longitude_submitted,
         dist_to_claimed_device = dist_to_claimed_device_m)

t1_all <- full_all %>%
  filter(pop_type == "idp", !is.na(idp_hh_number_from_listing)) %>%
  rename(idp_cluster_id = matched_cluster_id, n_claims = claim_group_size)

cluster_geo_lookup <- frame_all %>%
  distinct(cluster_id, .keep_all = TRUE) %>%
  select(cluster_id, adm1_name, adm2_name, adm3_name, target_households, households_in_cluster, iom_site_name, iom_site_ward)

idp_real_pools <- compute_real_avail_pools()

claimed_by_cluster_all <- t1_all %>%
  group_by(idp_cluster_id) %>%
  summarise(claimed = list(unique(idp_hh_number_from_listing)), .groups = "drop") %>%
  left_join(cluster_geo_lookup %>% select(idp_cluster_id = cluster_id, target_hh = target_households), by = "idp_cluster_id") %>%
  rowwise() %>%
  mutate(real_avail = list(resolve_avail_list(idp_cluster_id, target_hh, claimed, idp_real_pools))) %>%
  ungroup()

partner_adm2 <- split(partner_lga$adm2_pcode, partner_lga$org_id)
ORG_LABELS <- c(
  acf = "Action Against Hunger (ACF)", care = "CARE", coopi = "COOPI",
  crs = "Catholic Relief Services", drc = "Danish Refugee Council",
  fact = "FACT Foundation", fhi360 = "FHI 360", imc = "International Medical Corps",
  intersos = "INTERSOS", irc = "International Rescue Committee", jrs = "Jesuit Refugee Service",
  lhi = "Legacy Humanitarian Initiative (LHI)", malteser = "Malteser International",
  mdm = "Médecins du Monde", nrc = "Norwegian Refugee Council", plan = "PLAN International",
  sci = "Save the Children", si = "Solidarités International", street_child = "Street Child",
  zoa = "ZOA", other = "Other"
)

# ---- tracker-sourced Confirmed Deletions / Missing HH Listings (2026-09-06) -
# Replaces del_all/combined_del entirely. One row per confirmed_deletion
# tracker issue, enriched with real names from full_all (same reasoning the
# frozen version already used for this exact join - full_all's names are
# already-translated, del_all's own were pcodes).
tracker <- read_tracker()
confirmed_deletion_all <- tracker %>%
  filter(issue_type == "confirmed_deletion") %>%
  left_join(full_all %>% select(uuid, del_state = admin1, del_lga = admin2_submitted,
                                 del_ward = admin3_submitted, del_cluster_id = matched_cluster_id,
                                 del_pop_type = pop_type, del_enum_id = enum_id),
            by = "uuid")

# Jack's refinement (2026-09-06): a submission already confirmed-deleted
# under a no-appeal reason should be excluded from every OTHER flagged-issue
# sheet's candidate population globally, not just for uuids that happen to
# still be sitting in del_sheet's date-scoped no-appeal FYI window (see
# build_partner_package() - no-appeal FYI rows are deliberately shown only in
# the batch where they were newly confirmed, to avoid an ever-growing list,
# so a no-appeal confirmation from a PAST batch would otherwise silently keep
# looking "still actionable" here). Appealable-reason confirmations don't
# have this gap - a confirmed appealable row stays in del_sheet permanently -
# so this set only needs to cover the no-appeal reasons specifically.
no_appeal_confirmed_uuids <- tracker %>%
  filter(issue_type == "confirmed_deletion", status == "confirmed",
         deletion_reason %in% NO_APPEAL_DELETION_REASONS) %>%
  pull(uuid)

# ================================================================
build_partner_package <- function(org) {
  # FIXED 2026-09-11: was just excluding "listing_missing" - date_outlier/
  # crs_unmatched (new tonight) would otherwise flow straight into del_sheet
  # below with a generic Yes/No Contest box, since neither is in
  # NO_APPEAL_DELETION_REASONS. Both get their own sheet instead (below) -
  # see other_issues_sheet_design_2026-09-11.md in _working_files/.
  del_all_org <- confirmed_deletion_all %>% filter(org_id == org, !deletion_reason %in% c("listing_missing", "date_outlier", "crs_unmatched") | is.na(deletion_reason))
  # is_appealable (2026-09-06, per Jack's refinement): duration_under_20/
  # fcs_zero are validated methodology thresholds, already auto-confirmed at
  # registration (see issue_tracker.R's NO_APPEAL_DELETION_REASONS +
  # register_deletion_log_issues.R) - shown as FYI only, no real appeal.
  # Everything else keeps the real Contest This? flow. See build_workbook_fn.R
  # for how this drives the sheet's presentation.
  del_sheet <- del_all_org %>%
    filter(status %in% c(TERMINAL_STATUSES, "pending", "sent", "rejected")) %>%
    mutate(
      enum_id = del_enum_id, reason = deletion_reason,
      is_appealable = !deletion_reason %in% NO_APPEAL_DELETION_REASONS
    ) %>%
    # FYI (no-appeal) rows: only ones newly confirmed as of this batch, not
    # every no-appeal confirmation ever made - avoids an ever-growing
    # informational list on every future round (2026-09-06 scoping decision,
    # flagged to Jack - not otherwise specified). Appealable rows: any not
    # yet resolved, same as before.
    filter(is_appealable | resolution_date == as.character(Sys.Date())) %>%
    arrange(desc(is_appealable), uuid)

  # excluded_uuids (2026-09-06, Jack's refinement): del_sheet$uuid alone
  # misses a no-appeal confirmation from a past batch (see note above
  # no_appeal_confirmed_uuids's definition) - union with the all-time,
  # global no-appeal set closes that gap for every sheet below.
  excluded_uuids <- union(del_sheet$uuid, no_appeal_confirmed_uuids)

  gps_o <- gps_all %>% filter(org_id == org, dist_to_claimed_device > 150, !uuid %in% excluded_uuids)
  if (nrow(gps_o) > 0) {
    res <- pmap(list(gps_o$cluster_id, gps_o$lat, gps_o$lon), function(cl, lat, lon) {
      pool <- frame_nonidp %>% filter(cluster_id == cl, !(survey_id %in% claimed_ids_national))
      if (nrow(pool) == 0) return(list(top3 = tibble(cand1=NA_character_,cand1_dist=NA_real_,cand2=NA_character_,cand2_dist=NA_real_,cand3=NA_character_,cand3_dist=NA_real_), n_avail = 0L, avail = character(0)))
      pool$d_m <- round(haversine_m(lat, lon, pool$latitude, pool$longitude), 0)
      pool <- pool %>% arrange(d_m)
      top <- pool %>% slice_head(n = 3)
      list(top3 = tibble(cand1=top$survey_id[1], cand1_dist=top$d_m[1],
                          cand2=ifelse(nrow(top)>=2,top$survey_id[2],NA), cand2_dist=ifelse(nrow(top)>=2,top$d_m[2],NA),
                          cand3=ifelse(nrow(top)>=3,top$survey_id[3],NA), cand3_dist=ifelse(nrow(top)>=3,top$d_m[3],NA)),
           n_avail = nrow(pool), avail = pool$survey_id)
    })
    gps_o$n_available_in_cluster <- map_int(res, "n_avail")
    top3_df <- map_dfr(res, "top3")
    match_confidence <- case_when(
      is.na(top3_df$cand1_dist) ~ "No available household in cluster",
      top3_df$cand1_dist <= 150 ~ "Likely match",
      top3_df$cand1_dist <= 500 ~ "Possible match",
      TRUE ~ "No nearby match - please help us understand"
    )
    gps_sheet <- bind_cols(gps_o %>% select(uuid, enum_id, non_idp_point_id, cluster_id, dist_to_claimed_device, n_available_in_cluster,
                                             submission_date, ward_name = admin3_submitted, state_name = admin1, lga_name = admin2_submitted),
                            top3_df) %>%
      mutate(match_confidence = match_confidence) %>%
      arrange(cluster_id, non_idp_point_id)
    cluster_lookup_nonidp <- tibble(cluster_id = gps_o$cluster_id, avail = map(res, "avail")) %>% distinct(cluster_id, .keep_all = TRUE)
  } else {
    gps_sheet <- tibble(); cluster_lookup_nonidp <- tibble(cluster_id = character(), avail = list())
  }

  idp_o <- t1_all %>% filter(org_id == org, n_claims > 1, !uuid %in% excluded_uuids)
  if (nrow(idp_o) > 0) {
    idp_o$avail_list <- map2(idp_o$idp_cluster_id, idp_o$idp_hh_number_from_listing, function(cl, num) {
      row <- claimed_by_cluster_all %>% filter(idp_cluster_id == cl)
      if (nrow(row) == 0) return(integer(0))
      row$real_avail[[1]]
    })
    idp_o$n_available <- lengths(idp_o$avail_list)
    idp_o$nearby_unclaimed <- map2_chr(idp_o$avail_list, idp_o$idp_hh_number_from_listing, function(av, num) {
      near <- av[abs(av - num) <= 3]; if (length(near) == 0) return(NA_character_); paste(near, collapse = ",")
    })
    idp_sheet <- idp_o %>%
      select(uuid, enum_id, idp_cluster_id, ward_name = admin3_submitted, state_name = admin1, lga_name = admin2_submitted,
             submission_date, idp_hh_number_from_listing, nearby_unclaimed, n_available) %>%
      arrange(idp_cluster_id, idp_hh_number_from_listing)
    cluster_lookup_idp <- idp_o %>% distinct(idp_cluster_id, .keep_all = TRUE) %>% select(idp_cluster_id, avail_list)
  } else {
    idp_sheet <- tibble(); cluster_lookup_idp <- tibble(idp_cluster_id = character(), avail_list = list())
  }

  nonidp_clusters <- unique(gps_o$cluster_id)
  if (length(nonidp_clusters) > 0) {
    nonidp_avail <- frame_nonidp %>% filter(cluster_id %in% nonidp_clusters) %>%
      mutate(claimed_flag = survey_id %in% claimed_ids_national) %>% group_by(cluster_id) %>%
      summarise(type = "Non-IDP", total_points = n(), covered = paste(sort(survey_id[claimed_flag]), collapse=", "),
                available = paste(sort(survey_id[!claimed_flag]), collapse=", "), .groups = "drop")
  } else nonidp_avail <- tibble()
  idp_clusters <- unique(idp_o$idp_cluster_id)
  if (length(idp_clusters) > 0) {
    idp_avail <- claimed_by_cluster_all %>% filter(idp_cluster_id %in% idp_clusters) %>% rowwise() %>%
      mutate(type = "IDP", total_points = length(real_avail) + length(claimed), covered = paste(sort(claimed), collapse=", "),
             available = paste(sort(real_avail), collapse=", ")) %>% ungroup() %>%
      select(cluster_id = idp_cluster_id, type, total_points, covered, available)
  } else idp_avail <- tibble()
  cluster_avail <- bind_rows(nonidp_avail, idp_avail)
  if (nrow(cluster_avail) > 0) {
    cluster_avail <- cluster_avail %>%
      left_join(cluster_geo_lookup %>% select(cluster_id, adm1_name, adm2_name, adm3_name), by = "cluster_id") %>%
      rename(state = adm1_name, lga = adm2_name, ward = adm3_name)
  }

  # ---- Missing HH Listings — tracker-sourced (2026-09-06) --------------------
  # !uuid %in% no_appeal_confirmed_uuids is a no-op today (deletion_reason is
  # one value per uuid, so a listing_missing row can't also be a no-appeal
  # row in the same tracker entry) - kept for the same general rule as
  # gps_o/idp_o above, in case a future change stops that mutual exclusion
  # from holding.
  lm <- confirmed_deletion_all %>% filter(org_id == org, deletion_reason == "listing_missing", !uuid %in% no_appeal_confirmed_uuids)
  listing_sheet <- if (nrow(lm) > 0) {
    lm %>%
      mutate(del_cluster_id = coalesce(del_cluster_id, "(not identified -- contact IMPACT)")) %>%
      group_by(del_cluster_id) %>%
      summarise(
        state = first(del_state), lga = first(del_lga), ward = first(del_ward), pop_type = first(del_pop_type),
        affected_interviews = n(), interview_ids = paste(uuid, collapse = ", "),
        .groups = "drop"
      ) %>%
      left_join(cluster_geo_lookup, by = c("del_cluster_id" = "cluster_id")) %>%
      rename(cluster_id = del_cluster_id) %>%
      arrange(cluster_id)
  } else tibble()

  # ---- Missing HH Listings — cluster-level gap (added 2026-09-11) -----------
  # Tonight's redesign split listing_missing into two distinct things: the
  # per-interview case above (this specific interview's household isn't
  # found in a listing the cluster DOES have) stays keyed on
  # deletion_reason=="listing_missing"; a cluster with ZERO listing
  # submissions at all is now its own issue_type, "missing_hh_listing",
  # cluster-keyed (uuid is NA by design, see issue_tracker.R's
  # build_issue_id()), zero achieved impact. The block above never sees
  # these rows at all - confirmed_deletion_all (line ~129) is filtered to
  # issue_type=="confirmed_deletion" only, and missing_hh_listing rows have
  # no deletion_reason value to match on either. Without this block,
  # run_full_batch.R would silently show only the 113 stale, already-
  # resolved cluster rows here and miss all 62 real current gaps. Found by
  # Monitoring while tracing this script, fixed here - not yet run for a
  # real partner round, so nothing partner-facing has shipped with the bug.
  mh <- tracker %>%
    filter(issue_type == "missing_hh_listing", org_id == org) %>%
    left_join(cluster_geo_lookup, by = "cluster_id")
  missing_hh_sheet <- if (nrow(mh) > 0) {
    n_completed_by_cluster <- full_all %>%
      filter(org_id == org, interview_outcome == "completed") %>%
      count(matched_cluster_id, name = "affected_interviews")
    mh %>%
      transmute(
        cluster_id,
        state = adm1_name, lga = adm2_name, ward = adm3_name,
        pop_type = "idp",
        target_households, households_in_cluster, iom_site_name, iom_site_ward
      ) %>%
      left_join(n_completed_by_cluster, by = c("cluster_id" = "matched_cluster_id")) %>%
      mutate(
        affected_interviews = coalesce(affected_interviews, 0L),
        interview_ids = "(cluster-wide gap - no listing submissions at all for this site, not tied to specific flagged interviews)"
      )
  } else tibble()
  # bind_rows() fills NA for columns only one side has (e.g. the per-
  # interview rows don't have target_households/iom_site_name) - harmless,
  # whatever writes this sheet reads by column name, not position.
  listing_sheet <- bind_rows(listing_sheet, missing_hh_sheet) %>% arrange(cluster_id)

  # ---- Other Issues — date_outlier / crs_unmatched (added 2026-09-11) -----
  # Unlike del_sheet above (which resurfaces resolved appealable rows in
  # every future batch, per that block's own comment), Other Issues
  # STRICTLY excludes already-terminal (confirmed/contested) rows - Jack's
  # explicit call: date_outlier/crs_unmatched genuinely resolve and move
  # on, unlike Confirmed Deletions' own permanent-record framing. See
  # _working_files/other_issues_sheet_design_2026-09-11.md for the full
  # design. Text/presentation deliberately left to build_workbook_fn.R
  # (reason_text_map lookup at render time), matching how del_sheet passes
  # through raw `reason` rather than pre-formatting it here.
  other_sheet <- confirmed_deletion_all %>%
    filter(org_id == org, deletion_reason %in% c("date_outlier", "crs_unmatched"), !status %in% TERMINAL_STATUSES) %>%
    transmute(
      uuid, enum_id = del_enum_id,
      state = del_state, lga = del_lga, ward = del_ward, cluster_id = del_cluster_id,
      reason = deletion_reason
    ) %>%
    arrange(reason, uuid)

  # ---- target/achieved (for the email + workbook overview) ----
  my_adm2 <- partner_adm2[[org]]
  if (is.null(my_adm2)) my_adm2 <- character(0)
  target_sample <- sum(strata_frame$target_sample[strata_frame$adm2_pcode %in% my_adm2], na.rm = TRUE)

  full_o <- full_all %>% filter(org_id == org)
  gps_full_o <- gps_all %>% filter(org_id == org)
  idp_full_o <- t1_all %>% filter(org_id == org)
  n_achieved <- sum(!full_o$is_duplicate & !is.na(full_o$matched_survey_id) & !(full_o$uuid %in% del_sheet$uuid))

  oversampled_clusters <- full_o %>%
    filter(!is_duplicate, !is.na(matched_survey_id), !(uuid %in% del_sheet$uuid)) %>%
    count(matched_cluster_id, name = "n_achieved_cluster") %>%
    left_join(cluster_geo_lookup, by = c("matched_cluster_id" = "cluster_id")) %>%
    filter(!is.na(target_households), n_achieved_cluster > target_households) %>%
    mutate(surplus = n_achieved_cluster - target_households) %>%
    rename(cluster_id = matched_cluster_id) %>%
    arrange(desc(surplus))
  n_achieved_total_capped <- n_achieved - sum(oversampled_clusters$surplus)

  # n_duration_under_20 (deletion floor - CONFIRMED, from the tracker):
  # reconciles exactly with the Confirmed Deletions sheet. The retired
  # duration_under_30 reason string (pre-2026-09-01 floor) is no longer
  # registered at all as of tonight's fix - see issue_tracker.R/
  # register_deletion_log_issues.R headers - so this only ever needs to
  # check duration_under_20 now.
  # n_duration_20_30 (the NOT-yet-confirmed warning band): proper audit-based
  # computation is explicitly TOMORROW's integration work (Ak_data_cleaning_
  # msna.R's own duration_rushed=20/duration_lower=30 mechanism, per the
  # 2026-09-06 refinement) - duration_min here is real_submissions.csv's
  # simple start/end timestamp diff, NOT the audit-log-based duration
  # deletion_log.R/the tracker use, so this is a clearly-labelled provisional
  # approximation for tonight only, not the real integration.
  del_duration_ids <- del_sheet$uuid[del_sheet$reason == "duration_under_20"]

  scorecard <- full_o %>% group_by(enum_id) %>%
    summarise(
      n_collected = n(),
      n_achieved = sum(!is_duplicate & !is.na(matched_survey_id) & !(uuid %in% del_sheet$uuid)),
      n_duration_under_20 = sum(uuid %in% del_duration_ids),
      n_duration_20_30 = sum(!is.na(duration_min) & duration_min >= 20 & duration_min < 30),
      .groups = "drop"
    ) %>%
    left_join(del_sheet %>% count(enum_id, name = "n_confirmed_deletion"), by = "enum_id") %>%
    left_join(gps_full_o %>% filter(dist_to_claimed_device > 150) %>% count(enum_id, name = "n_gps_flagged"), by = "enum_id") %>%
    left_join(idp_full_o %>% filter(n_claims > 1) %>% distinct(uuid, enum_id) %>% count(enum_id, name = "n_idp_duplicate"), by = "enum_id")
  scorecard[is.na(scorecard)] <- 0
  scorecard$pct_flagged <- round(100 * (scorecard$n_confirmed_deletion + scorecard$n_gps_flagged + scorecard$n_idp_duplicate) / pmax(scorecard$n_collected,1), 1)

  GPS_MISMATCH_RATE_THRESHOLD <- 0.5; GPS_MISMATCH_MIN_N <- 5
  CONFIRMED_DELETION_RATE_THRESHOLD <- 0.3; CONFIRMED_DELETION_MIN_N <- 5
  ZERO_ACHIEVED_MIN_COLLECTED <- 10
  NOT_ACHIEVED_RATE_THRESHOLD <- 0.5; NOT_ACHIEVED_MIN_COLLECTED <- 5
  DURATION_20_30_RATE_THRESHOLD <- 0.3; DURATION_20_30_MIN_N <- 5

  scorecard$notes <- ""
  issue_fragments <- setNames(vector("list", nrow(scorecard)), scorecard$enum_id)
  flag_categories <- list()

  add_issue <- function(enum_ids, msg_fn) {
    for (i in seq_along(enum_ids)) {
      e <- enum_ids[i]
      issue_fragments[[e]] <<- c(issue_fragments[[e]], msg_fn(i))
    }
  }

  frozen <- gps_full_o %>% filter(dist_to_claimed_device > 150) %>% group_by(enum_id) %>% filter(n() >= 3) %>%
    summarise(n = n(), spread_m = {
      ll <- cbind(lat, lon); mx <- 0
      if (n() >= 2) for (i in 1:(n()-1)) for (j in (i+1):n()) mx <- max(mx, haversine_m(lat[i],lon[i],lat[j],lon[j]))
      round(mx, 0)
    }, dist_min = round(min(dist_to_claimed_device),0), dist_max = round(max(dist_to_claimed_device),0), .groups = "drop") %>%
    filter(spread_m <= 300)
  if (nrow(frozen) > 0) {
    add_issue(frozen$enum_id, function(i) sprintf(
      "%d submissions report near-identical GPS (within %dm of each other) despite being credited to households %d-%dm apart",
      frozen$n[i], frozen$spread_m[i], frozen$dist_min[i], frozen$dist_max[i]))
    flag_categories[["frozen"]] <- list(
      label = "Near-identical GPS reported across multiple submissions credited to different households (possible location freezing)",
      enum_ids = frozen$enum_id)
  }

  gps_rate <- scorecard %>% filter(n_gps_flagged >= GPS_MISMATCH_MIN_N, n_gps_flagged / n_collected >= GPS_MISMATCH_RATE_THRESHOLD)
  if (nrow(gps_rate) > 0) {
    add_issue(gps_rate$enum_id, function(i) sprintf(
      "%d of %d collected interviews (%s) have a GPS location more than 150m from the household they're credited to",
      gps_rate$n_gps_flagged[i], gps_rate$n_collected[i], percent(gps_rate$n_gps_flagged[i] / gps_rate$n_collected[i], accuracy = 1)))
    flag_categories[["gps_rate"]] <- list(
      label = paste0("GPS location more than 150m from the credited household in at least ",
                      percent(GPS_MISMATCH_RATE_THRESHOLD, accuracy = 1), " of their submissions"),
      enum_ids = gps_rate$enum_id)
  }

  del_rate <- scorecard %>% filter(n_confirmed_deletion >= CONFIRMED_DELETION_MIN_N, n_confirmed_deletion / n_collected >= CONFIRMED_DELETION_RATE_THRESHOLD)
  if (nrow(del_rate) > 0) {
    add_issue(del_rate$enum_id, function(i) sprintf(
      "%d of %d collected interviews (%s) are already confirmed for deletion",
      del_rate$n_confirmed_deletion[i], del_rate$n_collected[i], percent(del_rate$n_confirmed_deletion[i] / del_rate$n_collected[i], accuracy = 1)))
    flag_categories[["del_rate"]] <- list(
      label = paste0("At least ", percent(CONFIRMED_DELETION_RATE_THRESHOLD, accuracy = 1),
                      " of submissions already confirmed for deletion"),
      enum_ids = del_rate$enum_id)
  }

  zero_ach <- scorecard %>% filter(n_achieved == 0, n_collected >= ZERO_ACHIEVED_MIN_COLLECTED)
  if (nrow(zero_ach) > 0) {
    add_issue(zero_ach$enum_id, function(i) sprintf(
      "collected %d interviews but has 0 currently counting toward Achieved", zero_ach$n_collected[i]))
    flag_categories[["zero_ach"]] <- list(
      label = "Zero submissions currently counting toward Achieved despite real volume collected",
      enum_ids = zero_ach$enum_id)
  }

  not_ach <- scorecard %>% mutate(pct_not_achieved = (n_collected - n_achieved) / n_collected) %>%
    filter(n_collected >= NOT_ACHIEVED_MIN_COLLECTED, pct_not_achieved >= NOT_ACHIEVED_RATE_THRESHOLD, n_achieved > 0)
  if (nrow(not_ach) > 0) {
    add_issue(not_ach$enum_id, function(i) sprintf(
      "only %d of %d collected interviews (%s) currently count as Achieved, for a mix of reasons",
      not_ach$n_achieved[i], not_ach$n_collected[i], percent(not_ach$n_achieved[i] / not_ach$n_collected[i], accuracy = 1)))
    flag_categories[["not_ach"]] <- list(
      label = paste0("Fewer than ", percent(1 - NOT_ACHIEVED_RATE_THRESHOLD, accuracy = 1),
                      " of submissions currently count as Achieved, for a mix of reasons"),
      enum_ids = not_ach$enum_id)
  }

  borderline_rate <- scorecard %>% filter(n_duration_20_30 >= DURATION_20_30_MIN_N, n_duration_20_30 / n_collected >= DURATION_20_30_RATE_THRESHOLD)
  if (nrow(borderline_rate) > 0) {
    add_issue(borderline_rate$enum_id, function(i) sprintf(
      "%d of %d collected interviews (%s) are between 20 and 30 minutes -- not confirmed for deletion, but still a real warning sign worth watching",
      borderline_rate$n_duration_20_30[i], borderline_rate$n_collected[i], percent(borderline_rate$n_duration_20_30[i] / borderline_rate$n_collected[i], accuracy = 1)))
    flag_categories[["borderline_rate"]] <- list(
      label = paste0("At least ", percent(DURATION_20_30_RATE_THRESHOLD, accuracy = 1),
                      " of submissions fall in the 20-30 minute duration band (warning only, not yet confirmed for deletion)"),
      enum_ids = borderline_rate$enum_id)
  }

  flag_categories <- flag_categories[intersect(
    c("zero_ach", "del_rate", "not_ach", "gps_rate", "frozen", "borderline_rate"),
    names(flag_categories))]

  for (e in names(issue_fragments)) {
    frags <- issue_fragments[[e]]
    if (length(frags) == 0) next
    note <- paste0(
      "FLAGGED: ", paste0(frags, collapse = "; "),
      ". Needs direct follow-up with the enumerator - we can't tell from the data alone what's driving this, which is exactly why it needs a direct conversation, not us guessing from a distance."
    )
    scorecard$notes[scorecard$enum_id == e] <- note
  }
  scorecard <- scorecard %>% arrange(desc(pct_flagged))

  start_date <- suppressWarnings(min(full_o$submission_date[full_o$interview_outcome=="completed"], na.rm=TRUE))

  list(org = org, label = unname(ORG_LABELS[org]),
       gps_sheet = gps_sheet, idp_sheet = idp_sheet, del_sheet = del_sheet, listing_sheet = listing_sheet,
       other_sheet = other_sheet,
       cluster_avail = cluster_avail, scorecard = scorecard, flag_categories = flag_categories,
       oversampled_clusters = oversampled_clusters,
       cluster_lookup_nonidp = cluster_lookup_nonidp, cluster_lookup_idp = cluster_lookup_idp,
       n_collected_total = nrow(full_o), n_achieved_total = n_achieved, n_achieved_total_capped = n_achieved_total_capped,
       target_sample = target_sample,
       start_date = start_date, n_flagged_enums = sum(scorecard$notes != ""),
       n_duration_under_20_total = sum(scorecard$n_duration_under_20),
       n_duration_20_30_total = sum(scorecard$n_duration_20_30))
}

# GATED 2026-09-11: this self-test used to run unconditionally on every
# source() of this file - including every real Stage-1 batch run via
# run_full_batch.R, which silently also built and discarded a throwaway
# MDM package on top of whatever partner(s) it was actually asked for.
# Only run when this file is executed directly (Rscript full_batch_
# pipeline.R), matching the sys.nframe()==0 convention already used
# elsewhere in this pipeline (independent_deletion_checks.R).
if (sys.nframe() == 0) {
  cat("Pipeline loaded. Testing against MDM...\n")
  test <- build_partner_package("mdm")
  cat("MDM: collected=", test$n_collected_total, " achieved=", test$n_achieved_total, " target=", test$target_sample,
      " gps=", nrow(test$gps_sheet), " idp=", nrow(test$idp_sheet), " listing_missing_rows=", nrow(test$listing_sheet),
      " del=", nrow(test$del_sheet), " other=", nrow(test$other_sheet), " flagged_enums=", test$n_flagged_enums, "\n")
  cat("DONE\n")
}
