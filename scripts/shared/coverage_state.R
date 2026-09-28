# ==============================================================================
# coverage_state.R - which LGAs have NO partner and NO documented reason.
#
# WHY (2026-09-25, Jack via Coordinator): the dashboard used to fall back
# QUIETLY when an LGA had no partner - global.R coalesced a missing
# assignment to org_id "other" ("Other / unassigned") and partner_coverage_label()
# ended in "Not partner-assigned". Neither is a failure: a covered LGA that lost
# its assignment row (a reallocation typo, a renamed partner column) would read
# as a shrug, and an LGA nobody ever decided about (Marte, Borno - frame
# coverage_status not_covered / partner_coverage_declined, absent from the
# WORKING frame) sat behind the same neutral label. Jack wants ANY LGA or point
# without a partner flagged for immediate resolution.
#
# TWO FLAGGED STATES (everything else is OK):
#   UNASSIGNED - the frame says the LGA is COVERED (>= 1 covered stratum) but
#                there is no partner for it: no row in partner_lga_assignment.csv,
#                or a covered stratum whose partners_covering is blank.
#   UNRESOLVED - the frame says an LGA (or a stratum of it) is NOT covered
#                (coverage_status "not_covered") and there is NO documented decision
#                for it in config/coverage_decisions.csv. That file is the only
#                thing that turns "not covered" from an open question into a
#                choice somebody made.
# NOT flagged: an LGA whose every stratum is coverage_status "excluded" - that is
# already a documented design decision, carried in the frame's own
# exclusion_reason (accessibility loss, IDP population gone) and shown as
# "Excluded (was: ...)" by the dashboard.
#
# THE DECISION RECORD - config/coverage_decisions.csv (meant to be version-controlled: NOT
# gitignored, unlike input_data/ and data/ - though untracked until the working tree is
# committed; hand-maintained, never written by a pipeline):
#   scope          "state" or "lga"
#   pcode          adm1_pcode (scope = state) or adm2_pcode (scope = lga)
#   name           human-readable, for whoever reads the file
#   decision       must be "accepted_not_covered" - the ONLY decision that clears
#                  a not_covered LGA. "Assign a partner" is not a decision record,
#                  it is a Partnerscoverage.xlsx / frame change that makes the LGA
#                  covered. A deferral ("revisit later") must NOT clear the flag,
#                  so it is deliberately not an accepted value.
#   decided_by     who decided (required)
#   decision_date  YYYY-MM-DD (required)
#   note           free text: why
# A row missing any required field, or with an unknown scope/decision, is INVALID:
# it clears nothing, and the validity check reports it.
# A state-scope row covers every not_covered LGA in that state; an lga-scope row
# covers one LGA.
#
# The check works from the strata-level FULL frame (571 rows, one per LGA x pop
# type) - small, and it carries coverage_status/exclusion_reason/partners_covering
# for every LGA including the not-covered ones. It is re-run by
# refresh_coverage_state(), called from prep_partner_lga_assignment.R and from
# deploy_dashboard.R (so the flag is recomputed from the CURRENT frame every
# deploy, not only when the assignment prep is manually re-run).
#
# refresh_coverage_state() NEVER stops a normal refresh: it writes
# input_data/partner_coverage/coverage_state_by_lga.csv, prints a banner and (only
# when the flagged set changed) appends to data/SANITY_WARNINGS.txt. Set the
# environment variable STRICT_UNASSIGNED=1 to make it stop() instead.
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})

COVERAGE_DECISIONS_PATH <- "config/coverage_decisions.csv"
COVERAGE_STATE_PATH <- "input_data/partner_coverage/coverage_state_by_lga.csv"
COVERAGE_DECISION_COLUMNS <- c("scope", "pcode", "name", "decision", "decided_by", "decision_date", "note")
COVERAGE_DECISION_SCOPES <- c("state", "lga")
COVERAGE_DECISION_VALUES <- "accepted_not_covered"

.cov_blank <- function(x) is.na(x) | trimws(as.character(x)) %in% c("", "NA")

# -> list(valid, invalid, file_found). `invalid` carries a `problem` column.
read_coverage_decisions <- function(path = COVERAGE_DECISIONS_PATH) {
  empty <- as_tibble(setNames(rep(list(character()), length(COVERAGE_DECISION_COLUMNS)), COVERAGE_DECISION_COLUMNS))
  if (!file.exists(path)) return(list(valid = empty, invalid = mutate(empty, problem = character()), file_found = FALSE))
  d <- read_csv(path, show_col_types = FALSE, col_types = cols(.default = "c"), na = character())
  for (col in setdiff(COVERAGE_DECISION_COLUMNS, names(d))) d[[col]] <- rep(NA_character_, nrow(d))
  d <- d[, COVERAGE_DECISION_COLUMNS]
  d[] <- lapply(d, function(x) trimws(x))
  problem <- rep(NA_character_, nrow(d))
  problem[!(d$scope %in% COVERAGE_DECISION_SCOPES)] <- "scope must be 'state' or 'lga'"
  problem[is.na(problem) & .cov_blank(d$pcode)] <- "pcode is blank"
  problem[is.na(problem) & !(d$decision %in% COVERAGE_DECISION_VALUES)] <-
    paste0("decision must be one of: ", paste(COVERAGE_DECISION_VALUES, collapse = ", "))
  problem[is.na(problem) & .cov_blank(d$decided_by)] <- "decided_by is blank"
  problem[is.na(problem) & is.na(suppressWarnings(as.Date(d$decision_date, format = "%Y-%m-%d")))] <- "decision_date is not YYYY-MM-DD"
  list(valid = d[is.na(problem), ], invalid = mutate(d[!is.na(problem), ], problem = problem[!is.na(problem)]), file_found = TRUE)
}

# strata_full: one row per LGA x pop type - adm1_pcode, adm1_name, adm2_pcode,
#   adm2_name, coverage_status, partners_covering (target_sample optional).
# assignment: adm2_pcode (the partner_lga_assignment.csv shape).
# decisions_valid: read_coverage_decisions()$valid.
# active_clusters: optional adm2_pcode + cluster_id (the WORKING frame) - only used
#   to say how many active points a flagged LGA has.
compute_coverage_state <- function(strata_full, assignment, decisions_valid, active_clusters = NULL) {
  lga_dec <- decisions_valid$pcode[decisions_valid$scope == "lga"]
  state_dec <- decisions_valid$pcode[decisions_valid$scope == "state"]
  has_target <- "target_sample" %in% names(strata_full)
  out <- strata_full %>%
    mutate(.covered = coverage_status == "covered",
           .target = if (has_target) suppressWarnings(as.numeric(target_sample)) else NA_real_) %>%
    group_by(adm1_pcode, adm1_name, adm2_pcode, adm2_name) %>%
    summarise(
      n_strata = n(),
      n_covered = sum(.covered),
      n_excluded = sum(coverage_status == "excluded"),
      n_not_covered = sum(coverage_status == "not_covered"),
      n_covered_no_partner = sum(.covered & .cov_blank(partners_covering)),
      covered_target = if (has_target) sum(.target[.covered], na.rm = TRUE) else NA_real_,
      .groups = "drop"
    ) %>%
    mutate(
      has_assignment = adm2_pcode %in% assignment$adm2_pcode,
      frame_state = case_when(n_covered > 0 ~ "covered", n_not_covered > 0 ~ "not_covered", TRUE ~ "excluded"),
      decision_scope = case_when(adm2_pcode %in% lga_dec ~ "lga", adm1_pcode %in% state_dec ~ "state", TRUE ~ NA_character_),
      coverage_flag = case_when(
        n_covered > 0 & (!has_assignment | n_covered_no_partner > 0) ~ "UNASSIGNED",
        n_not_covered > 0 & is.na(decision_scope) ~ "UNRESOLVED",
        TRUE ~ "OK"
      ),
      coverage_flag_detail = case_when(
        coverage_flag == "UNASSIGNED" & !has_assignment ~
          paste0("Covered in the sampling frame (", n_covered, " covered stratum/strata) but has no partner in partner_lga_assignment.csv"),
        coverage_flag == "UNASSIGNED" ~
          paste0(n_covered_no_partner, " covered stratum/strata have no partners_covering in the sampling frame"),
        coverage_flag == "UNRESOLVED" & n_covered > 0 ~
          paste0(n_not_covered, " stratum/strata not covered inside an otherwise covered LGA, with no documented decision"),
        coverage_flag == "UNRESOLVED" ~
          # label-agnostic (2026-09-25): the frame's exclusion_reason for a not_covered LGA is no longer always
          # the design default partner_coverage_declined (Marte is now insecurity_related_inaccessibility)
          "Not covered by any partner in the sampling frame and no documented decision in config/coverage_decisions.csv",
        TRUE ~ NA_character_
      )
    )
  out$n_active_clusters <- if (is.null(active_clusters)) NA_integer_ else {
    counts <- active_clusters %>% distinct(adm2_pcode, cluster_id) %>% count(adm2_pcode, name = "n")
    n <- counts$n[match(out$adm2_pcode, counts$adm2_pcode)]
    ifelse(is.na(n), 0L, as.integer(n))
  }
  # constant on every row so the dashboard can tell "nobody has recorded any decision
  # yet" (record unseeded) from "decisions exist and these LGAs are still open"
  out$decisions_seeded <- nrow(decisions_valid) > 0
  out %>% arrange(desc(coverage_flag != "OK"), adm1_name, adm2_name)
}

.cov_flag_signature <- function(state_tbl) {
  if (is.null(state_tbl) || nrow(state_tbl) == 0) return(character())
  f <- state_tbl[state_tbl$coverage_flag != "OK" & !is.na(state_tbl$coverage_flag), ]
  sort(paste(f$adm2_pcode, f$coverage_flag))
}

.cov_list <- function(df, max_n = 12) {
  lab <- paste0(df$adm1_name, "/", df$adm2_name)
  if (length(lab) > max_n) paste0(paste(lab[seq_len(max_n)], collapse = "; "), "; +", length(lab) - max_n, " more (see coverage_state_by_lga.csv)")
  else paste(lab, collapse = "; ")
}

coverage_banner_lines <- function(state_tbl) {
  un <- state_tbl[state_tbl$coverage_flag == "UNASSIGNED", ]
  ur <- state_tbl[state_tbl$coverage_flag == "UNRESOLVED", ]
  lines <- character()
  if (nrow(un) > 0) {
    pts <- sum(un$n_active_clusters, na.rm = TRUE)
    lines <- c(lines, paste0(
      "UNASSIGNED COVERAGE: ", nrow(un), " covered LGA(s) have NO partner", if (pts > 0) paste0(" (", pts, " active points)"), ": ", .cov_list(un),
      " - covered in the sampling frame but absent from partner_lga_assignment.csv (or blank partners_covering). Fix Partnerscoverage.xlsx / the frame, then re-run prep_partner_lga_assignment.R."))
  }
  if (nrow(ur) > 0) {
    lines <- c(lines, paste0(
      "UNRESOLVED COVERAGE: ", nrow(ur), " not-covered LGA(s) have NO documented decision: ", .cov_list(ur),
      " - assign a partner, or record the decision in config/coverage_decisions.csv (decision = accepted_not_covered)."))
  }
  lines
}

# Recompute from the CURRENT mirrored frame / assignment / decision record, write
# the state CSV, print a banner, append to SANITY_WARNINGS only when the flagged
# set CHANGED (an append on every run would bury the file; write_warning = FALSE skips it
# entirely, for local test runs). Returns the state tibble.
refresh_coverage_state <- function(project_dir = ".", strict = identical(Sys.getenv("STRICT_UNASSIGNED"), "1"), quiet = FALSE, write_warning = TRUE) {
  old_wd <- setwd(project_dir); on.exit(setwd(old_wd))
  if (!exists("latest_frame_file", mode = "function")) source("scripts/shared/latest_frame_file.R")
  strata_full <- read_csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  assignment <- read_csv("input_data/partner_coverage/partner_lga_assignment.csv", show_col_types = FALSE, col_types = cols(.default = "c"))
  dec <- read_coverage_decisions()
  active <- tryCatch(
    read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"), show_col_types = FALSE,
             col_types = cols_only(cluster_id = "c", adm2_pcode = "c")),
    error = function(e) NULL)
  state_tbl <- compute_coverage_state(strata_full, assignment, dec$valid, active)

  previous <- if (file.exists(COVERAGE_STATE_PATH)) tryCatch(read_csv(COVERAGE_STATE_PATH, show_col_types = FALSE, col_types = cols(.default = "c")), error = function(e) NULL) else NULL
  changed <- !identical(.cov_flag_signature(previous), .cov_flag_signature(state_tbl))
  write_csv(state_tbl, COVERAGE_STATE_PATH, na = "")

  lines <- coverage_banner_lines(state_tbl)
  if (nrow(dec$invalid) > 0) {
    lines <- c(lines, paste0("COVERAGE DECISIONS: ", nrow(dec$invalid), " invalid row(s) in config/coverage_decisions.csv clear nothing: ",
                             paste0(dec$invalid$pcode, " (", dec$invalid$problem, ")", collapse = "; ")))
  }
  if (!quiet) {
    cat(sprintf("refresh_coverage_state(): %d LGAs | %d OK, %d UNASSIGNED, %d UNRESOLVED | %d valid decision row(s)%s\n",
                nrow(state_tbl), sum(state_tbl$coverage_flag == "OK"), sum(state_tbl$coverage_flag == "UNASSIGNED"),
                sum(state_tbl$coverage_flag == "UNRESOLVED"), nrow(dec$valid), if (!dec$file_found) " (decision file NOT FOUND)" else ""))
    if (length(lines) > 0) {
      bar <- strrep("!", 78)
      cat("\n", bar, "\n", paste0("!! ", lines, "\n"), bar, "\n\n", sep = "")
    }
  }
  if (write_warning && length(lines) > 0 && changed) {
    if (!exists("write_sanity_warnings", mode = "function")) source("cleaning/real/sanity_checks.R")
    write_sanity_warnings(lines, source_label = "coverage_state.R")
  }
  if (strict && length(lines) > 0) stop("STRICT_UNASSIGNED=1: ", paste(lines, collapse = " | "), call. = FALSE)
  invisible(state_tbl)
}

if (sys.nframe() == 0) refresh_coverage_state(if (basename(getwd()) == "shared") "../.." else ".")
