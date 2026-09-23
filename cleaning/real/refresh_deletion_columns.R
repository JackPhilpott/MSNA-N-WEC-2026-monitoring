# ==============================================================================
# refresh_deletion_columns.R - re-joins real_submissions.csv's three deletion
# columns from the CURRENT overlays, after the overlays have been rebuilt.
#
# WHY (found 2026-09-22 by the cross-format sweep, fixed per Jack the same
# day): real_submissions.csv carries quality_exclusion_reason,
# flagged_deletion_reason and deletion_status as a COPY of the two overlays,
# joined in by prep_real_submissions.R. deploy_dashboard.R's order is:
#
#   1. prep_real_submissions.R          <- copies the overlays as they stand
#   2. run_independent_*_check()        <- registers AND auto-confirms new
#                                          tracker issues (reads today's
#                                          real_submissions.csv, so it can't
#                                          run before step 1)
#   3. build_confirmed_deletions_overlay.R  <- rebuilds both overlays
#
# so every run's own new confirmations reached the overlays - which the
# partner workbooks and 1_sampling's resampling read DIRECTLY, and are
# therefore current - but not the copy the dashboard's is_achieved() reads,
# until the NEXT run's step 1. The dashboard was a full pipeline run behind
# the tracker, every run. Measured on the 2026-09-21 run: 110 completed
# interviews (99 duration_under_20, 11 duplicate_point, all resolved that
# day, across 25 strata) were confirmed deletions in the overlay but still
# counted as Achieved on the dashboard only; 128 rows differed in total.
# National Achieved read 22,276 where the overlay basis gives 22,166.
#
# The circular dependency is real (step 2 needs step 1's output), so the
# fix isn't a reorder: this runs as step 4, re-joining the same three
# columns from the freshly-rebuilt overlays using the SAME rule
# prep_real_submissions.R uses (distinct(uuid, .keep_all = TRUE), first row
# per uuid wins). build_confirmed_deletions_overlay.R's own header says to
# run it "before cleaning/real/prep_real_submissions.R ... so Achieved
# reflects whatever's currently in the tracker" - that intent is what this
# restores, without breaking step 2's dependency on step 1.
#
# Scope: ONLY those three columns. Row count, row order and every other
# column are untouched (verified by the caller's own before/after counts),
# so data/real_meta.rds - which records n_rows/n_completed/n_unmatched, none
# of which this can change - stays valid without being rewritten.
# any_quality_flag is derived from the GPS/duration/hh-size/LGA-mismatch/
# duplicate flags only, not from these columns, so it can't go stale here.
#
# Reads the CSV as pure character with na = character() (nothing coerced to
# NA), so every other field is written back byte-identical rather than
# re-formatted by a parse/serialise round trip - a literal "NA" stays "NA"
# and an empty field stays empty, which is exactly how prep writes them.
#
# Usage (from the 2_monitoring root, as deploy_dashboard.R does):
#   source("cleaning/real/refresh_deletion_columns.R"); refresh_deletion_columns()
# ==============================================================================
library(dplyr)
library(readr)
source("scripts/shared/retry_file_write.R")

refresh_deletion_columns <- function(csv_path = "data/real_submissions.csv",
                                      confirmed_path = "data/CONFIRMED_DELETIONS_OVERLAY.csv",
                                      flagged_path = "data/FLAGGED_DELETIONS_OVERLAY.csv") {
  if (!file.exists(csv_path)) {
    cat("refresh_deletion_columns(): no", csv_path, "- nothing to refresh.\n")
    return(invisible(NULL))
  }
  subs <- read_csv(csv_path, show_col_types = FALSE, na = character(),
                    col_types = cols(.default = col_character()))
  needed <- c("submission_uuid", "quality_exclusion_reason", "flagged_deletion_reason", "deletion_status")
  missing <- setdiff(needed, names(subs))
  if (length(missing) > 0) {
    stop("refresh_deletion_columns(): ", csv_path, " is missing column(s): ", paste(missing, collapse = ", "),
         " - prep_real_submissions.R's output shape has changed, so this refresh needs revisiting rather than guessing.")
  }

  # Same first-row-per-uuid rule as prep_real_submissions.R's own joins.
  read_overlay <- function(p) {
    if (!file.exists(p)) return(NULL)
    read_csv(p, show_col_types = FALSE, na = character(), col_types = cols(.default = col_character())) %>%
      distinct(uuid, .keep_all = TRUE)
  }
  conf <- read_overlay(confirmed_path)
  fl <- read_overlay(flagged_path)
  if (is.null(conf) || is.null(fl)) {
    cat("refresh_deletion_columns(): one or both overlays missing - left real_submissions.csv untouched.\n")
    return(invisible(NULL))
  }

  # "NA" (the literal string) is what prep writes for a row with no overlay
  # entry - keep that exact convention, since every consumer already reads
  # it that way (read.csv/read_csv turn it back into a real NA downstream).
  blank <- function(x) ifelse(is.na(x), "NA", x)
  new_quality <- blank(conf$reason[match(subs$submission_uuid, conf$uuid)])
  new_flag_reason <- blank(fl$reason[match(subs$submission_uuid, fl$uuid)])
  new_status <- blank(fl$status[match(subs$submission_uuid, fl$uuid)])

  settled <- c("confirmed", "contested")
  changed <- subs$quality_exclusion_reason != new_quality |
    subs$flagged_deletion_reason != new_flag_reason |
    subs$deletion_status != new_status
  # the subset that actually moves Achieved: a completed interview whose
  # settled/not-settled state differs between the copy and the source
  moves_achieved <- changed & subs$interview_outcome == "completed" &
    ((subs$deletion_status %in% settled) != (new_status %in% settled))

  n_changed <- sum(changed)
  if (n_changed == 0) {
    cat("refresh_deletion_columns(): already current with both overlays - no rewrite needed.\n")
    return(invisible(list(changed = 0L, moves_achieved = 0L)))
  }

  # captured BEFORE the overwrite - the two directional counts below read
  # the old state, which subs$deletion_status stops carrying the moment it
  # is replaced.
  old_status <- subs$deletion_status
  subs$quality_exclusion_reason <- new_quality
  subs$flagged_deletion_reason <- new_flag_reason
  subs$deletion_status <- new_status
  retry_file_write(function(p) write_csv(subs, p, na = "NA"), csv_path)

  cat(sprintf(
    "refresh_deletion_columns(): updated %d of %d row(s) from the current overlays; %d completed interview(s) changed settled-state (these would otherwise have stayed a pipeline run behind on the dashboard: %d newly excluded from Achieved, %d newly restored to it).\n",
    n_changed, nrow(subs), sum(moves_achieved),
    sum(moves_achieved & new_status %in% settled),
    sum(moves_achieved & old_status %in% settled & !(new_status %in% settled))
  ))
  invisible(list(changed = n_changed, moves_achieved = sum(moves_achieved)))
}
