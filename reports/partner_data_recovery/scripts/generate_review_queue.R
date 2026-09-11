# ==============================================================================
# generate_review_queue() - the "classify + stage" half of the shared
# review-queue engine (2026-09-08 rebuild), deletion-recovery side.
#
# Produces ONE compact staging file (JSON) that a chat session reads to
# present the review queue to Jack - built specifically so that presentation
# is cheap: this script does the grouping/aggregation work up front, so the
# session isn't loading or processing raw per-row tracker data just to print
# a summary (Jack's explicit ask: token-efficient, plain-text, no raw dumps).
#
# Two sections per partner, matching exactly what Jack specified:
#   a) confirmed - already rule-confident, auto-applied (informational only,
#      nothing to decide)
#   b) needs_review - grouped as much as possible (by issue_type +
#      deletion_reason within a partner - checked against real current data,
#      2026-09-08: this groups FACT's 300 duplicate_point items into ONE
#      reviewable line instead of 300, which is the whole point), each group
#      carrying a representative example + count, not every row's full detail
#
# Does NOT decide anything and does NOT write to the tracker - purely the
# staging step. The "apply decisions" half (apply_review_decisions() in
# apply_review_decisions.R) is what a session calls after Jack responds.
#
# Usage: Rscript generate_review_queue.R [output_path]
#   (defaults to reports/partner_data_recovery/outputs/_review_queue_<date>.json)
# ==============================================================================
# FIX 2026-09-11: PROJECT_DIR/setwd() used to be hardcoded here directly -
# now shared with apply_review_decisions.R via one file instead of two
# independent copies of the same literal path.
source("c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring/scripts/shared/project_root.R")
suppressPackageStartupMessages({ library(dplyr); library(jsonlite) })
source("reports/partner_data_recovery/scripts/issue_tracker.R")

generate_review_queue <- function(output_path = NULL) {
  tracker <- read_tracker()

  confirmed <- tracker %>% filter(status %in% TERMINAL_STATUSES)
  needs_review <- tracker %>% filter(!status %in% TERMINAL_STATUSES)

  partners <- sort(unique(c(confirmed$org_id, needs_review$org_id)))

  queue <- lapply(partners, function(org) {
    org_confirmed <- confirmed %>% filter(org_id == org)
    org_needs_review <- needs_review %>% filter(org_id == org)

    confirmed_summary <- org_confirmed %>%
      count(issue_type, deletion_reason, name = "n") %>%
      arrange(desc(n))

    # Grouped as much as possible: by (issue_type, deletion_reason) within
    # this partner - one reviewable line per group, not one per row. A
    # group carries a count, one representative example (first row's own
    # notes/uuid), and the full uuid list (for apply_review_decisions() to
    # act on once Jack decides - kept out of what gets PRINTED to Jack, only
    # used internally when a decision is applied).
    review_groups <- org_needs_review %>%
      group_by(issue_type, deletion_reason) %>%
      group_map(function(rows, keys) {
        list(
          issue_type = keys$issue_type,
          deletion_reason = keys$deletion_reason,
          n = nrow(rows),
          example_notes = if (!is.na(rows$notes[1]) && nzchar(rows$notes[1])) substr(rows$notes[1], 1, 300) else NA_character_,
          rounds_outstanding_max = suppressWarnings(max(as.integer(rows$rounds_outstanding), na.rm = TRUE)),
          uuids = rows$uuid,
          issue_ids = rows$issue_id
        )
      })

    list(
      org_id = org,
      confirmed = list(
        total = nrow(org_confirmed),
        by_group = purrr::transpose(as.list(confirmed_summary))
      ),
      needs_review = list(
        total = nrow(org_needs_review),
        groups = review_groups
      )
    )
  })
  names(queue) <- partners

  if (is.null(output_path)) {
    dir.create("reports/partner_data_recovery/outputs/_review_queue", showWarnings = FALSE, recursive = TRUE)
    output_path <- sprintf("reports/partner_data_recovery/outputs/_review_queue/%s.json", format(Sys.Date(), "%Y-%m-%d"))
  }
  write_json(list(
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    tracker_md5 = unname(tools::md5sum(TRACKER_PATH)),
    partners_with_pending_review = names(Filter(function(p) p$needs_review$total > 0, queue)),
    queue = queue
  ), output_path, auto_unbox = TRUE, pretty = TRUE, na = "null")

  cat(sprintf("generate_review_queue(): wrote %s\n", output_path))
  cat(sprintf("%d partner(s) have items needing review, %d total items across %d group(s).\n",
              sum(vapply(queue, function(p) p$needs_review$total > 0, logical(1))),
              sum(vapply(queue, function(p) p$needs_review$total, numeric(1))),
              sum(vapply(queue, function(p) length(p$needs_review$groups), numeric(1)))))
  invisible(output_path)
}

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  generate_review_queue(if (length(args) >= 1) args[1] else NULL)
}
