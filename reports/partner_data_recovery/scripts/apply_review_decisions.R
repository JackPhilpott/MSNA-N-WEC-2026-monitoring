# ==============================================================================
# apply_review_decisions() - the "apply" half of the shared review-queue
# engine (2026-09-08 rebuild), deletion-recovery side. Counterpart to
# generate_review_queue.R.
#
# Deliberately a thin bulk wrapper around issue_tracker.R's own
# apply_resolution() - uses the EXACT same status vocabulary
# (confirmed/rejected/contested) and required fields (confirmed_by,
# recovery_type) that function already enforces, rather than inventing a
# simplified "approve/reject" vocabulary that might not map correctly onto
# the tracker's real semantics (a rejected deletion can mean "confirmed
# deletion stands" OR "genuinely recovered" depending on recovery_type - not
# a binary a wrapper should guess at). The session calling this after a real
# conversation with Jack is what supplies the real outcome; this function
# just applies it correctly and efficiently.
#
# Bulk by design - single read + single write for the whole batch, same
# performance lesson already learned in register_deletion_log_issues.R's
# no-appeal block (~1,700 rows took minutes at one round-trip per row).
#
# Every decision this writes is logged to a dated decisions-audit-trail file
# (append-only), not just the tracker's own resolution/resolution_date/
# confirmed_by fields - a durability guarantee for a chat-based decision
# specifically, since Jack asked for exactly this: a chat-based decision
# should be just as auditable as a workbook-based one, not less.
#
# decisions: a list of lists, each with:
#   issue_ids (character vector, from a generate_review_queue.R group's own
#     issue_ids field - always apply a whole group at once, matching how it
#     was presented, not a hand-picked subset unless Jack explicitly split it)
#   new_status ("confirmed" | "rejected" | "contested")
#   resolution (free text - what Jack actually said/decided, not a generic note)
#   confirmed_by ("partner" | "internal_team", required if new_status=="confirmed")
#   recovery_type ("false_positive" | "justified_exception", optional, only
#     when this resolves as a recovery rather than a standing deletion)
#   allow_reopen (added 2026-09-11, optional, default FALSE) - set TRUE only
#     when deliberately re-deciding a row already at a terminal status
#     (confirmed/contested) - e.g. settling a contested row after further
#     discussion. Without this, a decision targeting an already-terminal
#     row is silently skipped (with a warning), not applied - see the
#     terminal-status guard in the loop below for why this exists.
# ==============================================================================
# FIX 2026-09-11: PROJECT_DIR/setwd() used to be hardcoded here directly -
# now shared with generate_review_queue.R via one file instead of two
# independent copies of the same literal path.
source("c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring/scripts/shared/project_root.R")
suppressPackageStartupMessages(library(dplyr))
source("reports/partner_data_recovery/scripts/issue_tracker.R")

apply_review_decisions <- function(decisions, decided_by = "Jack (via chat review)") {
  for (d in decisions) {
    stopifnot(d$new_status %in% c("confirmed", "rejected", "contested"))
    if (d$new_status == "confirmed" && (is.null(d$confirmed_by) || is.na(d$confirmed_by))) {
      stop("apply_review_decisions(): new_status='confirmed' requires confirmed_by - never left to infer.")
    }
  }

  tracker <- read_tracker()
  audit_lines <- character(0)
  n_applied <- 0L
  n_not_found <- 0L
  n_blocked_terminal <- 0L

  for (d in decisions) {
    hit <- tracker$issue_id %in% d$issue_ids
    n_found <- sum(hit)
    n_not_found <- n_not_found + (length(d$issue_ids) - n_found)
    if (n_found == 0) next

    # FIX 2026-09-11: this used to be a raw, unguarded dataframe mutation -
    # a chat-based decision could silently overwrite whatever
    # review_recovery_response.py (or any apply_resolution() caller) had
    # JUST decided for the same row, for ANY reason type, with no warning.
    # Proven live via a real test (2026-09-11 recovery-workbook design
    # review): approve a row via the Python reviewer, then apply a
    # conflicting chat decision for the same issue_id - the conflicting
    # decision silently won. Same terminal-status guard apply_resolution()
    # itself now has (issue_tracker.R), reimplemented inline here (not a
    # per-row apply_resolution() call) to preserve this function's whole
    # reason for existing - one read + one write for the entire batch, not
    # ~1,700 round-trips. A decision can still deliberately re-decide an
    # already-terminal row (e.g. settling a contested row after further
    # discussion) by setting allow_reopen=TRUE on that specific decision.
    already_terminal <- tracker$status %in% TERMINAL_STATUSES
    allow_reopen <- isTRUE(d$allow_reopen)
    blocked <- hit & already_terminal & !allow_reopen
    n_blocked_this <- sum(blocked)
    if (n_blocked_this > 0) {
      n_blocked_terminal <- n_blocked_terminal + n_blocked_this
      warning(sprintf(
        "apply_review_decisions(): %d issue_id(s) already at a terminal status - refusing to overwrite (pass allow_reopen=TRUE on this decision if deliberate): %s",
        n_blocked_this, paste(tracker$issue_id[blocked], collapse = ";")
      ))
    }
    hit <- hit & !blocked
    n_found <- sum(hit)
    if (n_found == 0) next

    tracker$status[hit] <- d$new_status
    tracker$resolution[hit] <- if (!is.null(d$resolution)) d$resolution else NA_character_
    tracker$resolution_date[hit] <- as.character(Sys.Date())
    if (!is.null(d$confirmed_by) && !is.na(d$confirmed_by)) tracker$confirmed_by[hit] <- d$confirmed_by
    if (!is.null(d$recovery_type) && !is.na(d$recovery_type)) tracker$recovery_type[hit] <- d$recovery_type
    n_applied <- n_applied + n_found

    # audit_lines now logs the ACTUALLY-applied issue_ids (post-terminal-
    # guard), not the originally-requested list - a real improvement over
    # before, where a blocked row (silently overwritten pre-fix) would have
    # been logged as if it were genuinely applied.
    audit_lines <- c(audit_lines, sprintf(
      "%s | decided_by=%s | n=%d | new_status=%s | confirmed_by=%s | recovery_type=%s | resolution=%s | issue_ids=%s",
      format(Sys.time(), "%Y-%m-%d %H:%M:%S"), decided_by, n_found, d$new_status,
      if (!is.null(d$confirmed_by)) d$confirmed_by else "NA",
      if (!is.null(d$recovery_type)) d$recovery_type else "NA",
      if (!is.null(d$resolution)) gsub("\n", " ", d$resolution) else "NA",
      paste(tracker$issue_id[hit], collapse = ";")
    ))
  }

  if (n_applied > 0) {
    write_tracker(tracker)
    dir.create("reports/partner_data_recovery/outputs/_review_decisions_log", showWarnings = FALSE, recursive = TRUE)
    audit_path <- sprintf("reports/partner_data_recovery/outputs/_review_decisions_log/%s.log", format(Sys.Date(), "%Y-%m-%d"))
    cat(paste(audit_lines, collapse = "\n"), "\n", file = audit_path, append = TRUE)
    cat(sprintf("apply_review_decisions(): applied %d decision(s), %d row(s) updated, logged to %s\n",
                length(decisions), n_applied, audit_path))
  } else {
    cat("apply_review_decisions(): nothing applied (no matching issue_ids found).\n")
  }
  if (n_not_found > 0) {
    warning(sprintf("apply_review_decisions(): %d issue_id(s) in the decision list were not found in the tracker - possibly already resolved by something else since the queue was generated. Re-run generate_review_queue.R if this is unexpected.", n_not_found))
  }
  if (n_blocked_terminal > 0) {
    cat(sprintf("apply_review_decisions(): %d issue_id(s) were blocked by the terminal-status guard - see warning(s) above for which ones.\n", n_blocked_terminal))
  }
  invisible(list(n_applied = n_applied, n_not_found = n_not_found, n_blocked_terminal = n_blocked_terminal))
}
