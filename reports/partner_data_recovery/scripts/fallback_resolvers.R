# ==============================================================================
# fallback_resolvers.R - recovery-workbook CLOSEOUT system, built 2026-09-28
# per Jack's spec (relayed by Coordinator, 28 Sep - the final partner-
# response deadline day, most partners expected to send nothing back). Goal:
# by the time tomorrow's real partner responses are ingested (as usual,
# unchanged - real_data_recovery_response.py etc.), whatever is STILL open
# gets a pre-computed, defensible fallback resolution instead of quietly
# staying lost data, and the whole thing produces one CSV Jack can sanity-
# check before it goes to the data officer at midday.
#
# GENERIC FRAMEWORK: a resolver registry keyed by (issue_type, deletion_
# reason), not hardcoded to the two mechanisms below - see FALLBACK_
# RESOLVERS. Anything with no registered resolver comes out of the sweep as
# "no_fallback_defined", never silently guessed at. Deliberately
# UNREGISTERED right now (per Jack, via Coordinator):
#   - pct_missing_flagged, idp_listing_duplicate - Jack is working out the
#     fallback logic for these himself, separately, later today.
#   - confirmed_deletion/{listing_missing, crs_unmatched, date_outlier} -
#     not asked for; date_outlier already has its own separate resolver
#     (resolve_stale_date_outlier_rows.R) for its 2 genuinely-stale rows.
#   - fcs_zero - not a deletion reason any more at all (2026-09-10 policy,
#     see CLAUDE.md) - completely out of this system, never touched here.
#
# TWO MECHANISMS BUILT NOW:
#   1. missing_hh_listing (IDP, cluster-level, zero Achieved impact) -> the
#      cluster's IOM DTM site-level household count/listing, joined via the
#      sampling frame's own iom_site_id (input_data/sampling_frame/*_FULL,
#      already carries iom_site_id per cluster) against 1_sampling/input_
#      data/population/iom/'s two LIVE DTM files (not _archive/).
#   2. confirmed_deletion/duplicate_point AND gps_duplicate (interview-
#      level) -> nearest real, unclaimed, still-accessible household point.
#      Non-IDP: genuine haversine GIS distance, reusing full_batch_
#      pipeline.R's own vetted frame_nonidp/claimed_ids_national/haversine_m
#      definitions (a fallback candidate must never disagree with what a
#      partner already saw offered as "available" in their own workbook).
#      IDP: nearest unclaimed household NUMBER in the cluster's real HH-
#      listing drawn pool (real_hh_listing.R's compute_real_avail_pools() /
#      resolve_avail_list()) - IDP sites have exactly one GPS point per
#      SITE, not per household, so there is no household-level lat/lon to
#      run GIS matching on; listing-number proximity within the site's own
#      real drawn pool is the established, correct analogue here (the same
#      one build_workbook_fn.R's own IDP Listing Duplicates dropdown uses),
#      not a simplification standing in for GIS.
#   Known scope simplification, stated plainly rather than hidden: the Non-
#   IDP "still-accessible" check here is ward_accessible_status only (a
#   direct frame column) - it does NOT reproduce 1_sampling/scripts/shared/
#   frame_status.R's full compute_cluster_accessibility() stack (below-4-
#   accessible-primary-HH threshold, cluster-overlay exclusions, target-
#   correction drops). Adding that full stack was judged not worth the
#   same-day risk for a proxy this close already; flagged here, not
#   silently assumed equivalent.
#
# FRAMEWORK RULES (Jack, via Coordinator - non-negotiable):
#   1. A fallback resolution is NEVER a real "confirmed" resolution. It is
#      written to NEW tracker columns only - fallback_status/fallback_
#      mechanism/fallback_resolution/fallback_applied_date (issue_tracker.R
#      schema, extended 2026-09-28) - and NEVER touches `status`/
#      `confirmed_by`/`recovery_type`. apply_resolution() is never called
#      from this file, directly or indirectly.
#   2. A real partner response always wins, at any time, including AFTER a
#      fallback has already been applied - nothing here marks an issue
#      TERMINAL, and nothing in apply_resolution()/register_issues() reads
#      fallback_status before acting, so a late partner response is never
#      blocked by a fallback having run first.
#   3. Same preview -> explicit confirm -> snapshot-before-apply -> undo
#      safety discipline as resolve_live_claimant_duplicates.R / resolve_
#      stale_date_outlier_rows.R - structure only, see those files' own
#      headers for the pattern. apply_fallback_sweep() only ever writes a
#      row whose fallback_status is still blank, so re-running it (e.g. a
#      second sweep after more partner responses land) is a safe no-op for
#      anything already processed and only fills genuinely new gaps.
#
# USAGE:
#   source("reports/partner_data_recovery/scripts/issue_tracker.R")
#   source("reports/partner_data_recovery/scripts/fallback_resolvers.R")
#   preview_fallback_sweep()               # read-only, safe to run any time (today included)
#   apply_fallback_sweep(confirm = TRUE)   # snapshot -> write fallback_* columns -> log
#   restore_fallback_sweep("<snapshot csv>")  # undo, one call
#   build_do_deletion_log()                # writes the DO-facing CSV + prints a sanity crosstab
#
# NOTHING here runs on source(). Tested read-only 2026-09-28 against the
# live tracker and current real_submissions.csv/v14 sampling frame.
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(purrr); library(stringr); library(tidyr)})

MON_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring"
source(file.path(MON_DIR, "reports/partner_data_recovery/scripts/real_hh_listing.R"))

# Same formula as full_batch_pipeline.R's own haversine_m() - an independent
# copy rather than source()-ing that whole (multi-hundred-line, workbook-
# generation-specific) file just for one function.
.fb_haversine_m <- function(lat1, lon1, lat2, lon2) {
  R <- 6371000; to_rad <- pi / 180
  dlat <- (lat2 - lat1) * to_rad; dlon <- (lon2 - lon1) * to_rad
  a <- sin(dlat / 2)^2 + cos(lat1 * to_rad) * cos(lat2 * to_rad) * sin(dlon / 2)^2
  2 * R * asin(pmin(1, sqrt(a)))
}

# Dynamic highest-version frame resolution - same convention as full_batch_
# pipeline.R's resolve_latest_frame() / prep_real_submissions.R's
# latest_frame_file(), so this can't silently rot at the next resample.
.fb_resolve_latest_frame <- function(pattern, dir = file.path(MON_DIR, "input_data/sampling_frame")) {
  files <- list.files(dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0) stop(".fb_resolve_latest_frame(): no file matching '", pattern, "' in ", dir)
  versions <- as.integer(str_match(basename(files), "_v(\\d+)_")[, 2])
  files[which.max(versions)]
}

# ---- IOM DTM site-level lookup (mechanism 1) --------------------------------
# LIVE files only (not 1_sampling/input_data/population/iom/_archive/, and
# not the dated .bak sitting next to IMPACT_IOM_NGA_R51_NE.csv) - the two
# regions' files use slightly different column names for the same fields.
.fb_load_dtm <- function() {
  iom_dir <- file.path(dirname(MON_DIR), "1_sampling/input_data/population/iom")
  rd <- function(path, source_label) {
    df <- read_csv(path, show_col_types = FALSE, col_types = cols(.default = "c"))
    tibble(
      iom_site_id = df[["Site ID (SSID)"]], site_name = df[["Site Name"]],
      state = df[["State"]], lga = df[["LGA"]], ward = df[["Ward"]],
      households = suppressWarnings(as.numeric(df[["Households"]])),
      dtm_source = source_label
    )
  }
  bind_rows(
    rd(file.path(iom_dir, "IMPACT_IOM_DTM_NCNW_R18.csv"), "DTM NCNW Round 18"),
    rd(file.path(iom_dir, "IMPACT_IOM_NGA_R51_NE.csv"), "DTM NGA Round 51 (NE)")
  ) %>% filter(!is.na(iom_site_id), nzchar(iom_site_id))
}

# ---- shared context, loaded once per sweep (both preview and apply run this
# fresh every time, deliberately - the correct candidate pool shrinks as real
# responses/earlier fallback picks consume it, so a stale cached context
# would be wrong, not just slow) ----------------------------------------------
.load_fallback_context <- function() {
  subs <- read_csv(file.path(MON_DIR, "data/real_submissions.csv"), show_col_types = FALSE, guess_max = 100000)
  frame_all <- read_csv(.fb_resolve_latest_frame("^NGA_MSNA_2026_stage2_sampling_frame_v\\d+_FULL\\.csv$"), show_col_types = FALSE)

  frame_nonidp <- frame_all %>% filter(pop_type == "non_idp") %>%
    select(survey_id, cluster_id, strata_id, latitude, longitude, ward_accessible_status)
  # Same "claimed" definition full_batch_pipeline.R's own GPS Duplicates /
  # Non-IDP Duplicates sheets already use and show partners today - a
  # fallback candidate must never disagree with what a partner already saw
  # offered as "available" in their own workbook.
  claimed_ids_national <- unique(subs$non_idp_point_id[!is.na(subs$non_idp_point_id) & nzchar(subs$non_idp_point_id)])

  cluster_site_lookup <- frame_all %>% filter(pop_type == "idp") %>%
    distinct(cluster_id, .keep_all = TRUE) %>% select(cluster_id, iom_site_id, iom_site_name)

  # Real per-cluster IDP available-number pool - identical construction to
  # full_batch_pipeline.R's own claimed_by_cluster_all (real_hh_listing.R
  # header has the full rationale for why this, not a target_households
  # proxy, is the right "available" pool).
  idp_real_pools <- compute_real_avail_pools()
  idp_claims <- subs %>% filter(pop_type == "idp", !is.na(idp_hh_number_from_listing)) %>%
    transmute(idp_cluster_id = matched_cluster_id, idp_hh_number_from_listing)
  target_hh_lookup <- frame_all %>% distinct(cluster_id, .keep_all = TRUE) %>%
    transmute(idp_cluster_id = cluster_id, target_hh = target_households)
  claimed_by_cluster <- idp_claims %>%
    group_by(idp_cluster_id) %>%
    summarise(claimed = list(unique(idp_hh_number_from_listing)), .groups = "drop") %>%
    left_join(target_hh_lookup, by = "idp_cluster_id") %>%
    rowwise() %>%
    mutate(real_avail = list(resolve_avail_list(idp_cluster_id, target_hh, claimed, idp_real_pools))) %>%
    ungroup()

  # Mutable, shared across EVERY call to .propose_duplicate_fallback() within
  # one sweep (confirmed_deletion/duplicate_point and gps_duplicate are two
  # separate registry buckets, so this function is called once per bucket -
  # a plain local accumulator reset at each call would let the two buckets
  # hand out the SAME replacement point to two different duplicates, found
  # empirically 2026-09-28 as 3 collisions in a 646-candidate run; an
  # environment persists across those separate calls, a local vector does not).
  claimed_state <- new.env()
  claimed_state$nonidp <- character(0)
  claimed_state$idp <- list()

  list(
    subs = subs, frame_nonidp = frame_nonidp, claimed_ids_national = claimed_ids_national,
    cluster_site_lookup = cluster_site_lookup, dtm = .fb_load_dtm(), claimed_by_cluster = claimed_by_cluster,
    claimed_state = claimed_state
  )
}

# ---- mechanism 1: missing_hh_listing -> IOM DTM site -------------------------
.propose_missing_hh_listing <- function(rows, ctx) {
  site <- ctx$cluster_site_lookup[match(rows$cluster_id, ctx$cluster_site_lookup$cluster_id), ]
  dtm_hit <- ctx$dtm[match(site$iom_site_id, ctx$dtm$iom_site_id), ]
  found <- !is.na(site$iom_site_id) & !is.na(dtm_hit$iom_site_id)
  resolution <- ifelse(
    found,
    sprintf(
      "IOM DTM site '%s' (Site ID %s, %s/%s/%s): %s households per %s. Used as the household-listing source in place of a partner-submitted HH listing (no real listing available for this cluster).",
      coalesce(dtm_hit$site_name, site$iom_site_name, "unnamed site"), site$iom_site_id,
      coalesce(dtm_hit$state, "?"), coalesce(dtm_hit$lga, "?"), coalesce(dtm_hit$ward, "?"),
      ifelse(is.na(dtm_hit$households), "unknown count of", format(dtm_hit$households, big.mark = ",")), dtm_hit$dtm_source
    ),
    ifelse(
      is.na(site$iom_site_id) | !nzchar(coalesce(site$iom_site_id, "")),
      "No iom_site_id recorded on this cluster in the current sampling frame - cannot look up a DTM site for it.",
      sprintf("Cluster's iom_site_id (%s) was not found in either current IOM DTM file (DTM NCNW R18 / DTM NGA R51 NE).", site$iom_site_id)
    )
  )
  tibble(
    issue_id = rows$issue_id, fallback_mechanism = "iom_dtm_listing", fallback_resolution = resolution,
    outcome = ifelse(found, "applied_candidate", "no_candidate_available")
  )
}

# ---- mechanism 2: duplicate_point / gps_duplicate -> nearest available HH ---
.propose_duplicate_fallback <- function(rows, ctx) {
  s <- ctx$subs[match(rows$uuid, ctx$subs$submission_uuid), ]
  # ctx$claimed_state persists across BOTH registry buckets that call this
  # function (confirmed_deletion/duplicate_point and gps_duplicate) - see
  # .load_fallback_context()'s own comment for why this must be shared
  # state, not a local accumulator reset per call.

  out <- vector("list", nrow(rows))
  for (i in seq_len(nrow(rows))) {
    if (is.na(s$submission_uuid[i])) {
      out[[i]] <- list(mechanism = "gis_nearest_household", resolution = "uuid not found in the current real_submissions.csv - cannot look up its point/cluster.", outcome = "no_candidate_available")
      next
    }
    cl <- s$matched_cluster_id[i]
    if (is.na(cl) || !nzchar(cl)) {
      out[[i]] <- list(mechanism = "gis_nearest_household", resolution = "Interview has no matched_cluster_id - cannot scope a candidate pool to search.", outcome = "no_candidate_available")
      next
    }
    if (isTRUE(s$pop_type[i] == "idp")) {
      num <- s$idp_hh_number_from_listing[i]
      pool_row <- ctx$claimed_by_cluster[!is.na(ctx$claimed_by_cluster$idp_cluster_id) & ctx$claimed_by_cluster$idp_cluster_id == cl, ]
      avail <- if (nrow(pool_row) == 1) pool_row$real_avail[[1]] else integer(0)
      avail <- setdiff(avail, ctx$claimed_state$idp[[cl]])
      if (length(avail) == 0 || is.na(num)) {
        out[[i]] <- list(
          mechanism = "gis_nearest_household",
          resolution = sprintf("IDP cluster %s: no unclaimed household number left in the real HH-listing drawn pool (or this interview has no idp_hh_number_from_listing to compare against) - no substitute available.", cl),
          outcome = "no_candidate_available"
        )
      } else {
        pick <- avail[which.min(abs(avail - num))]
        ctx$claimed_state$idp[[cl]] <- c(ctx$claimed_state$idp[[cl]], pick)
        out[[i]] <- list(
          mechanism = "gis_nearest_household",
          resolution = sprintf("IDP cluster %s: nearest unclaimed household number in the real HH-listing drawn pool is #%d (claimed number was #%s).", cl, pick, as.character(num)),
          outcome = "applied_candidate"
        )
      }
    } else {
      # Anchor point for the distance search: prefer the device's OWN
      # submitted GPS reading (real observed location) when it exists - the
      # whole premise of a gps_duplicate/"Distant Pts" row. Most confirmed_
      # deletion/duplicate_point rows carry NO device GPS at all (2_
      # monitoring's own anonymised export has raw coordinates for only a
      # minority of rows - CLAUDE.md's "Independent deletion checks"
      # section), so for those, fall back to the DISPUTED point's own known
      # frame coordinate (non_idp_point_id, looked up in frame_nonidp by
      # survey_id) - geographically the right anchor anyway for "who really
      # visited point X", and always available whenever a key-based
      # duplicate exists at all (found empirically 2026-09-28: without this
      # fallback, 0 of 739 non-IDP duplicate_point candidates were found -
      # every one of them had NA device GPS).
      lat <- s$latitude_submitted[i]; lon <- s$longitude_submitted[i]
      if (is.na(lat) || is.na(lon)) {
        claimed_pt <- s$non_idp_point_id[i]
        if (!is.na(claimed_pt) && nzchar(claimed_pt)) {
          anchor <- ctx$frame_nonidp[ctx$frame_nonidp$survey_id == claimed_pt, ]
          if (nrow(anchor) >= 1) { lat <- anchor$latitude[1]; lon <- anchor$longitude[1] }
        }
      }
      pool <- ctx$frame_nonidp %>%
        filter(cluster_id == cl, !(survey_id %in% ctx$claimed_ids_national), !(survey_id %in% ctx$claimed_state$nonidp),
               ward_accessible_status != "Inaccessible")
      widened <- FALSE
      if (nrow(pool) == 0) {
        strata <- ctx$frame_nonidp$strata_id[ctx$frame_nonidp$cluster_id == cl][1]
        if (!is.na(strata)) {
          pool <- ctx$frame_nonidp %>%
            filter(strata_id == strata, !(survey_id %in% ctx$claimed_ids_national), !(survey_id %in% ctx$claimed_state$nonidp),
                   ward_accessible_status != "Inaccessible")
          widened <- TRUE
        }
      }
      if (nrow(pool) == 0 || is.na(lat) || is.na(lon)) {
        out[[i]] <- list(
          mechanism = "gis_nearest_household",
          resolution = sprintf("Non-IDP cluster %s: no unclaimed, ward-accessible household point available (checked same cluster, then same stratum), or no usable anchor coordinate (neither a submitted GPS reading nor a resolvable claimed point) to search from.", cl),
          outcome = "no_candidate_available"
        )
      } else {
        pool$d_m <- round(.fb_haversine_m(lat, lon, pool$latitude, pool$longitude), 0)
        best <- pool %>% arrange(d_m) %>% slice(1)
        ctx$claimed_state$nonidp <- c(ctx$claimed_state$nonidp, best$survey_id)
        out[[i]] <- list(
          mechanism = "gis_nearest_household",
          resolution = sprintf("Non-IDP: nearest real, unclaimed, ward-accessible household point is %s, %.0fm away%s.", best$survey_id, best$d_m, ifelse(widened, " (widened search to the same stratum - none available in this cluster)", "")),
          outcome = "applied_candidate"
        )
      }
    }
  }
  tibble(
    issue_id = rows$issue_id, fallback_mechanism = map_chr(out, "mechanism"),
    fallback_resolution = map_chr(out, "resolution"), outcome = map_chr(out, "outcome")
  )
}

# ---- generic registry --------------------------------------------------------
FALLBACK_RESOLVERS <- list(
  "missing_hh_listing::" = list(mechanism = "iom_dtm_listing", propose = .propose_missing_hh_listing),
  "confirmed_deletion::duplicate_point" = list(mechanism = "gis_nearest_household", propose = .propose_duplicate_fallback),
  "gps_duplicate::" = list(mechanism = "gis_nearest_household", propose = .propose_duplicate_fallback)
)

.fb_bucket_key <- function(issue_type, deletion_reason) paste0(issue_type, "::", ifelse(is.na(deletion_reason), "", deletion_reason))

# Core computation shared by preview and apply, so the two can never
# disagree - always fresh against the CURRENT tracker/data, never cached
# across calls (see .load_fallback_context()'s own note on why).
.compute_fallback_sweep <- function() {
  tracker <- read_tracker()
  open <- tracker %>% filter(!status %in% TERMINAL_STATUSES, is.na(fallback_status) | !nzchar(fallback_status))
  if (nrow(open) == 0) {
    return(tibble(issue_id = character(), fallback_mechanism = character(), fallback_resolution = character(),
                  outcome = character(), issue_type = character(), deletion_reason = character(),
                  org_id = character(), cluster_id = character(), uuid = character()))
  }
  ctx <- .load_fallback_context()
  open$bucket <- .fb_bucket_key(open$issue_type, open$deletion_reason)
  buckets <- split(open, open$bucket)
  results <- map(names(buckets), function(k) {
    rows <- buckets[[k]]
    resolver <- FALLBACK_RESOLVERS[[k]]
    if (is.null(resolver)) {
      tibble(
        issue_id = rows$issue_id, fallback_mechanism = NA_character_,
        fallback_resolution = "No fallback mechanism defined for this issue_type/deletion_reason yet - needs Jack's review.",
        outcome = "no_fallback_defined"
      )
    } else {
      resolver$propose(rows, ctx)
    }
  })
  bind_rows(results) %>%
    left_join(open %>% select(issue_id, issue_type, deletion_reason, org_id, cluster_id, uuid), by = "issue_id")
}

# ---- preview / apply / restore -----------------------------------------------
preview_fallback_sweep <- function() {
  result <- .compute_fallback_sweep()
  cat(sprintf("preview_fallback_sweep(): %d currently-open tracker row(s) without a fallback_status yet.\n", nrow(result)))
  if (nrow(result) == 0) { cat("Nothing to preview.\n"); return(invisible(result)) }
  cat("\nBy issue_type / deletion_reason / outcome:\n")
  print(as.data.frame(result %>% count(issue_type, deletion_reason, outcome, sort = TRUE)), row.names = FALSE)
  cat(sprintf("\nOverall: %d applied_candidate | %d no_candidate_available | %d no_fallback_defined\n",
              sum(result$outcome == "applied_candidate"), sum(result$outcome == "no_candidate_available"),
              sum(result$outcome == "no_fallback_defined")))
  cat("\nNothing has been changed. To apply (only after real partner responses are ingested): apply_fallback_sweep(confirm = TRUE).\n")
  invisible(result)
}

apply_fallback_sweep <- function(confirm = FALSE, decided_by = "Jack (recovery-workbook closeout, via Coordinator spec 2026-09-28)",
                                  log_dir = "reports/partner_data_recovery/outputs/_review_decisions_log") {
  if (!isTRUE(confirm)) {
    stop("apply_fallback_sweep(): pass confirm = TRUE explicitly - this writes fallback_* columns and needs Jack's word (per the closeout spec: only after real partner-response ingestion).")
  }
  result <- .compute_fallback_sweep()
  if (nrow(result) == 0) { cat("apply_fallback_sweep(): nothing to apply (every open issue already has a fallback_status, or nothing is open).\n"); return(invisible(NULL)) }

  dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)
  stamp <- format(Sys.Date(), "%Y-%m-%d")
  tracker <- read_tracker()
  snapshot_path <- file.path(log_dir, paste0(stamp, "_fallback_sweep_BEFORE.csv"))
  if (file.exists(snapshot_path)) snapshot_path <- file.path(log_dir, paste0(stamp, "_", format(Sys.time(), "%H%M%S"), "_fallback_sweep_BEFORE.csv"))
  write_csv(tracker[tracker$issue_id %in% result$issue_id, TRACKER_COLUMNS], snapshot_path, na = "")  # BEFORE any change

  idx <- match(result$issue_id, tracker$issue_id)
  tracker$fallback_status[idx] <- result$outcome
  tracker$fallback_mechanism[idx] <- result$fallback_mechanism
  tracker$fallback_resolution[idx] <- result$fallback_resolution
  tracker$fallback_applied_date[idx] <- stamp
  write_tracker(tracker)

  outcome_tbl <- table(result$outcome)
  cat(paste0(sprintf(
    "%s | decided_by=%s | n=%d | snapshot=%s | outcomes=%s\n",
    format(Sys.time(), "%Y-%m-%d %H:%M:%S"), decided_by, nrow(result), basename(snapshot_path),
    paste(names(outcome_tbl), as.integer(outcome_tbl), sep = "=", collapse = ";")
  )), file = file.path(log_dir, paste0(stamp, ".log")), append = TRUE)
  cat(sprintf("apply_fallback_sweep(): wrote fallback_status for %d row(s); snapshot: %s\n", nrow(result), snapshot_path))
  print(as.data.frame(result %>% count(issue_type, deletion_reason, outcome, sort = TRUE)), row.names = FALSE)
  invisible(list(n = nrow(result), snapshot = snapshot_path))
}

restore_fallback_sweep <- function(snapshot_path, decided_by = "Jack (recovery-workbook closeout)",
                                    log_dir = "reports/partner_data_recovery/outputs/_review_decisions_log") {
  snap <- read_csv(snapshot_path, show_col_types = FALSE, col_types = cols(.default = "c"))
  for (col in setdiff(TRACKER_COLUMNS, names(snap))) snap[[col]] <- NA_character_
  tracker <- read_tracker()
  idx <- match(snap$issue_id, tracker$issue_id)
  if (anyNA(idx)) warning("restore_fallback_sweep(): ", sum(is.na(idx)), " snapshot row(s) no longer exist in the tracker - skipped.")
  ok <- !is.na(idx)
  # Only the 4 fallback_* columns - apply_fallback_sweep() never touches
  # anything else, so restoring the full row would be equivalent but this
  # is more precise/self-documenting about what's actually being undone.
  fb_cols <- c("fallback_status", "fallback_mechanism", "fallback_resolution", "fallback_applied_date")
  for (col in fb_cols) tracker[[col]][idx[ok]] <- snap[[col]][ok]
  write_tracker(tracker)
  dir.create(log_dir, showWarnings = FALSE, recursive = TRUE)
  cat(paste0(sprintf(
    "%s | decided_by=%s | RESTORE n=%d from %s | issue_ids=%s\n",
    format(Sys.time(), "%Y-%m-%d %H:%M:%S"), decided_by, sum(ok), basename(snapshot_path), paste(snap$issue_id[ok], collapse = ";")
  )), file = file.path(log_dir, paste0(format(Sys.Date(), "%Y-%m-%d"), ".log")), append = TRUE)
  cat(sprintf("restore_fallback_sweep(): restored %d row(s)' fallback_* columns to their pre-sweep state.\n", sum(ok)))
  invisible(sum(ok))
}

# ---- the DO-facing output: one row per tracker issue, three-way split obvious
build_do_deletion_log <- function(out_path = NULL) {
  tracker <- read_tracker()
  resolution_path <- case_when(
    tracker$status %in% TERMINAL_STATUSES & (is.na(tracker$fallback_status) | !nzchar(tracker$fallback_status)) ~ "partner_or_internal_confirmed",
    tracker$fallback_status == "applied_candidate" ~ "fallback_sweep",
    tracker$fallback_status == "no_candidate_available" ~ "fallback_attempted_no_candidate",
    tracker$fallback_status == "no_fallback_defined" ~ "no_fallback_defined",
    TRUE ~ "unresolved_pending_sweep"
  )
  out <- tracker %>%
    mutate(resolution_path = resolution_path) %>%
    select(issue_id, issue_type, deletion_reason, org_id, cluster_id, strata_id, uuid, status, resolution_path,
           resolution, confirmed_by, recovery_type, fallback_mechanism, fallback_resolution, fallback_applied_date,
           rounds_outstanding, detected_date, resolution_date, notes)
  if (is.null(out_path)) {
    out_path <- file.path(MON_DIR, "reports/partner_data_recovery/outputs", sprintf("deletion_log_for_DO_%s.csv", format(Sys.Date(), "%Y-%m-%d")))
  }
  dir.create(dirname(out_path), showWarnings = FALSE, recursive = TRUE)
  write_csv(out, out_path, na = "")
  cat(sprintf("build_do_deletion_log(): wrote %d row(s) to %s\n\n", nrow(out), out_path))
  cat("Sanity crosstab (resolution_path x issue_type/deletion_reason):\n")
  print(as.data.frame(out %>% count(issue_type, deletion_reason, resolution_path, sort = TRUE)), row.names = FALSE)
  invisible(out)
}
