# ==============================================================================
# seed_coverage_decisions.R - populate config/coverage_decisions.csv from the
# CURRENT frame. PREPARED 2026-09-25, NOT RUN. Needs Jack's word on WHO decided
# and WHICH LGAs stay open (Marte, Borno, is the one that needs a real decision).
#
# Why seeding exists: the record starts empty, so every one of the frame's
# not_covered LGAs (147 on v13) reads UNRESOLVED. 146 of them are not open
# questions - they are the design as it stands (three states with no coverage at
# all: Kano [excluded 30 Jul], Niger, Kogi; and the partially covered states
# Benue, Kaduna, Nasarawa and Plateau, by original design). Seeding records
# those 146 as accepted so the flag then sweeps ONLY what is actually open.
#
# WHAT IT WRITES (59 rows on frame v13): a scope="state" row for each state in
# which EVERY LGA is not_covered (Kano, Kogi, Niger = 3 rows covering 90 LGAs), and
# a scope="lga" row for each remaining not_covered LGA (56 rows: Benue 17, Kaduna
# 21, Nasarawa 6, Plateau 12), except any pcode in `exclude_pcodes` (default
# Marte, NG008022 - left OPEN on purpose). A state row covers EVERY not_covered LGA
# of that state, including any that become not_covered later; an LGA row covers only
# itself, so a NEW not_covered LGA inside a partial state (Benue, Kaduna, Nasarawa,
# Plateau) reads UNRESOLVED until someone decides it. An LGA that becomes covered
# stops being flagged whatever the record says (covered wins) - the validity check's
# "superseded" WARN then points at the now-stale row.
#
#   source("scripts/shared/seed_coverage_decisions.R")
#   preview_coverage_decision_seed()                    # read-only: prints exactly what would be written
#   apply_coverage_decision_seed(decided_by = "<name>", confirm = TRUE)
#
# apply refuses unless confirm = TRUE, refuses if the record already has any row
# (it seeds an EMPTY record, it never merges), and takes decided_by with NO
# default - the record must name whoever actually decided. Undo = put the header-only file
# back (one line: scope,pcode,name,decision,decided_by,decision_date,note) and run
# refresh_coverage_state(). NB config/ is not gitignored but it is UNCOMMITTED until the
# working tree is committed, so `git checkout` cannot restore it yet (it can afterwards).
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source("scripts/shared/coverage_state.R")

# note_suffix: appended to EVERY row's note (e.g. who/when seeded it). overrides: a named list keyed by
# pcode, each element list(decision_date = "YYYY-MM-DD", note = "...") - REPLACES that row's date and note
# (used for a decision that pre-dates the seeding, e.g. Kano 2026-07-30, so the record carries its real date).
build_coverage_decision_seed <- function(exclude_pcodes = "NG008022", decided_by = "<decided_by>",
                                         decision_date = format(Sys.Date(), "%Y-%m-%d"), project_dir = ".",
                                         note_suffix = "", overrides = NULL) {
  old_wd <- setwd(project_dir); on.exit(setwd(old_wd))
  if (!exists("latest_frame_file", mode = "function")) source("scripts/shared/latest_frame_file.R")
  frame_file <- latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL")
  strata_full <- read_csv(frame_file, show_col_types = FALSE, col_types = cols(.default = "c"))
  assignment <- read_csv("input_data/partner_coverage/partner_lga_assignment.csv", show_col_types = FALSE, col_types = cols(.default = "c"))
  st <- compute_coverage_state(strata_full, assignment, read_coverage_decisions()$valid[0, ])   # ignore any existing rows
  nc <- st[st$frame_state == "not_covered" & !st$adm2_pcode %in% exclude_pcodes, ]
  states_all <- st %>% count(adm1_pcode, name = "n_all")
  whole <- st[st$frame_state == "not_covered", ] %>% count(adm1_pcode, adm1_name, name = "n_nc") %>%
    left_join(states_all, by = "adm1_pcode") %>% filter(n_nc == n_all, !adm1_pcode %in% substr(exclude_pcodes, 1, 5))
  lga <- nc[!nc$adm1_pcode %in% whole$adm1_pcode, ]
  frame_v <- sub(".*_v([0-9]+)_FULL\\.csv$", "v\\1", basename(frame_file))
  bind_rows(
    tibble(scope = "state", pcode = whole$adm1_pcode, name = whole$adm1_name,
           note = paste0("Whole state not covered in frame ", frame_v, " (partner_coverage_declined) - no LGA of it is in the MSNA N-WEC design")),
    tibble(scope = "lga", pcode = lga$adm2_pcode, name = paste0(lga$adm1_name, " / ", lga$adm2_name),
           note = paste0("Partially covered state by design; this LGA not covered in frame ", frame_v, " (partner_coverage_declined)"))
  ) %>% mutate(decision = "accepted_not_covered", decided_by = decided_by, decision_date = decision_date, note = paste0(note, note_suffix)) %>%
    select(all_of(COVERAGE_DECISION_COLUMNS)) -> out
  for (pc in names(overrides)) {
    i <- which(out$pcode == pc)
    if (length(i) != 1) stop("build_coverage_decision_seed(): override for '", pc, "' matches ", length(i), " seed row(s), expected exactly 1 - it is not in this seed.")
    if (!is.null(overrides[[pc]]$decision_date)) out$decision_date[i] <- overrides[[pc]]$decision_date
    if (!is.null(overrides[[pc]]$note)) out$note[i] <- overrides[[pc]]$note
  }
  out
}

preview_coverage_decision_seed <- function(exclude_pcodes = "NG008022", project_dir = ".", decided_by = "<decided_by>", note_suffix = "", overrides = NULL) {
  seed <- build_coverage_decision_seed(exclude_pcodes, decided_by = decided_by, project_dir = project_dir, note_suffix = note_suffix, overrides = overrides)
  cat(sprintf("preview_coverage_decision_seed(): %d row(s) would be written: %d state row(s), %d LGA row(s); left OPEN: %s\n",
              nrow(seed), sum(seed$scope == "state"), sum(seed$scope == "lga"), paste(exclude_pcodes, collapse = ", ")))
  print(as.data.frame(seed %>% group_by(scope) %>% summarise(n = n(), first = first(name), .groups = "drop")), row.names = FALSE)
  # what the flag would look like AFTER seeding, without writing anything
  old_wd <- setwd(project_dir); on.exit(setwd(old_wd))
  strata_full <- read_csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  assignment <- read_csv("input_data/partner_coverage/partner_lga_assignment.csv", show_col_types = FALSE, col_types = cols(.default = "c"))
  after <- compute_coverage_state(strata_full, assignment, seed)
  cat(sprintf("after seeding the flag would be: %d UNASSIGNED, %d UNRESOLVED%s\n", sum(after$coverage_flag == "UNASSIGNED"), sum(after$coverage_flag == "UNRESOLVED"),
              if (any(after$coverage_flag == "UNRESOLVED")) paste0(" (", paste0(after$adm1_name, "/", after$adm2_name)[after$coverage_flag == "UNRESOLVED"], ")") else ""))
  invisible(seed)
}

apply_coverage_decision_seed <- function(decided_by, exclude_pcodes = "NG008022", confirm = FALSE, project_dir = ".", note_suffix = "", overrides = NULL) {
  if (!isTRUE(confirm)) stop("apply_coverage_decision_seed(): pass confirm = TRUE explicitly - this records coverage decisions on Jack's behalf.")
  if (missing(decided_by) || is.na(decided_by) || !nzchar(trimws(decided_by))) stop("apply_coverage_decision_seed(): decided_by must name whoever decided.")
  old_wd <- setwd(project_dir); on.exit(setwd(old_wd))
  existing <- read_coverage_decisions()
  if (nrow(existing$valid) + nrow(existing$invalid) > 0) stop("apply_coverage_decision_seed(): the decision record already has rows - this only seeds an EMPTY record (edit the file by hand to add or change decisions).")
  seed <- build_coverage_decision_seed(exclude_pcodes, decided_by = decided_by, note_suffix = note_suffix, overrides = overrides)
  write_csv(seed, COVERAGE_DECISIONS_PATH, na = "")
  cat(sprintf("apply_coverage_decision_seed(): wrote %d row(s) to %s (decided_by = %s). Now run refresh_coverage_state().\n", nrow(seed), COVERAGE_DECISIONS_PATH, decided_by))
  invisible(seed)
}
