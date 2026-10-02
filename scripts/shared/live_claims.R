# ==============================================================================
# live_claims.R - who really "holds" an assigned point / IDP listing slot.
#
# WHY (2026-09-25, Jack/Coordinator 4a): prep_real_submissions.R flags a
# submission is_duplicate when it is not the FIRST row to claim a dup_key (a
# non-IDP point id, or an IDP cluster+listing/walk slot). That counted rows
# that no longer stand: a first submission later confirmed-deleted (almost
# always duration_under_20) or one that was never a completed interview still
# "occupied" the slot, so the valid re-collection was flagged duplicate_point
# and sent to the partner for review. Measured on the 09-23 build: 274 rows.
#
# RULE: a claimant is LIVE when it is a completed interview that is not a
# settled (confirmed/contested) deletion. Within a claim key the first LIVE
# claimant is not a duplicate, whatever came before it. Everything else keeps
# exactly the flag it had - in particular a settled-deleted duplicate stays
# is_duplicate = TRUE, so counts that exclude duplicates (daily trend,
# enumerator submissions) are not inflated by rows that were deleted anyway.
#
# Achieved/credited are NOT affected: since the 2026-09-11 policy is_achieved()
# is "completed and not settled-deleted" and never looks at is_duplicate.
#
# ORDER: "first" = earliest upload time (_submission_time, exposed as
# uploaded_at) - the same key prep's own duplicate detection has always used, so
# the canonical claimant of an existing group never changes. Rows with no upload
# time (dates reconstructed from audit logs) sort AFTER every exact one - they
# are by construction newer than the last good build - and among themselves by
# start_datetime. Do NOT swap the key for the audit form-start in general: on
# the 09-23 data that would change the canonical claimant in 251 of 1,604
# claim groups (502 rows), because offline uploads arrive long after the
# interview.
#
# Works on either typed columns (prep, in memory) or all-character columns
# (refresh_deletion_columns.R, straight off the CSV); is_duplicate and
# any_quality_flag come back in the type they went in with.
# ==============================================================================

claim_key <- function(df) {
  is_missing <- function(x) is.na(x) | as.character(x) %in% c("", "NA")
  idp <- !is_missing(df$pop_type) & df$pop_type == "idp"
  key <- rep(NA_character_, nrow(df))
  has_listing <- idp & !is_missing(df$idp_hh_number_from_listing)
  has_walk <- idp & !has_listing & !is_missing(df$idp_walk_position)
  key[has_listing] <- paste0(df$matched_cluster_id[has_listing], "|listing_", df$idp_hh_number_from_listing[has_listing])
  key[has_walk] <- paste0(df$matched_cluster_id[has_walk], "|walk_", df$idp_walk_position[has_walk])
  # Non-IDP claims key on the CLAIMED point (non_idp_point_id), so a second distinct household kept at a drawn
  # point under a "_b" suffix (Round 1 closeout, Jack Q3 - see prep's section 3b) is its own claim rather than
  # a duplicate of the first. Everywhere else the two columns hold the same value (prep sets both from the same
  # repaired point id, the suffix aside); a frame without the column falls back to matched_survey_id as before.
  non_idp <- !idp & !is_missing(df$matched_survey_id)
  claimed <- if ("non_idp_point_id" %in% names(df)) as.character(df$non_idp_point_id) else rep(NA_character_, nrow(df))
  key[non_idp] <- ifelse(is_missing(claimed[non_idp]), as.character(df$matched_survey_id[non_idp]), claimed[non_idp])
  key
}

# The PREVIOUS rule, recomputed from the same key and ordering: a row is a
# duplicate when it is not the first row of its claim key, whatever the others'
# status. Used by resolve_live_claimant_duplicates.R to find exactly the rows the
# live-claimant rule clears (old TRUE -> new FALSE), independent of whether the
# CSV's is_duplicate column has already been re-derived.
old_rule_duplicates <- function(df) {
  fmt_time <- function(x) {
    if (is.null(x)) return(rep(NA_character_, nrow(df)))
    x <- if (inherits(x, "POSIXt")) format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC") else as.character(x)
    x[x %in% c("", "NA")] <- NA_character_
    x
  }
  key <- claim_key(df)
  up <- fmt_time(df$uploaded_at); st <- fmt_time(df$start_datetime)
  ord_key <- ifelse(is.na(up), paste0("~", ifelse(is.na(st), "", st)), up)
  rows <- data.frame(i = seq_len(nrow(df)), key = key, ord = ord_key, stringsAsFactors = FALSE)
  rows <- rows[!is.na(rows$key), , drop = FALSE]
  rows <- rows[order(rows$ord, rows$i), , drop = FALSE]
  rows$rank <- stats::ave(rows$i, rows$key, FUN = seq_along)
  rows$n <- stats::ave(rows$i, rows$key, FUN = length)
  out <- rep(FALSE, nrow(df))
  out[rows$i[rows$n > 1 & rows$rank > 1]] <- TRUE
  out
}

apply_live_claim_rule <- function(df, settled_uuid) {
  as_lgl <- function(x) if (is.logical(x)) x else toupper(as.character(x)) == "TRUE"
  was_char <- !is.logical(df$is_duplicate)
  fmt_time <- function(x) {
    if (is.null(x)) return(rep(NA_character_, nrow(df)))
    x <- if (inherits(x, "POSIXt")) format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC") else as.character(x)
    x[x %in% c("", "NA")] <- NA_character_
    x
  }
  key <- claim_key(df)
  live <- df$interview_outcome == "completed" & !(df$submission_uuid %in% settled_uuid)
  up <- fmt_time(df$uploaded_at)
  st <- fmt_time(df$start_datetime)
  ord_key <- ifelse(is.na(up), paste0("~", ifelse(is.na(st), "", st)), up)

  rows <- data.frame(i = seq_len(nrow(df)), key = key, live = live, ord = ord_key, stringsAsFactors = FALSE)
  rows <- rows[!is.na(rows$key) & rows$live, , drop = FALSE]
  rows <- rows[order(rows$ord, rows$i), , drop = FALSE]
  rows$rank_live <- stats::ave(rows$i, rows$key, FUN = seq_along)
  first_live_idx <- rows$i[rows$rank_live == 1]

  n_live_by_key <- table(rows$key)
  n_live_claims <- rep(NA_integer_, nrow(df))
  has_key <- !is.na(key)
  n_live_claims[has_key] <- as.integer(n_live_by_key[key[has_key]])
  n_live_claims[has_key & is.na(n_live_claims)] <- 0L

  old_dup <- as_lgl(df$is_duplicate)
  new_dup <- old_dup
  new_dup[first_live_idx] <- FALSE

  flags <- Reduce(`|`, lapply(c("flag_gps_outlier", "flag_duration_outlier", "flag_hh_size_mismatch", "flag_lga_mismatch"),
                             function(nm) as_lgl(df[[nm]])))
  new_any_flag <- flags | new_dup

  df$is_duplicate <- if (was_char) ifelse(new_dup, "TRUE", "FALSE") else new_dup
  df$any_quality_flag <- if (was_char) ifelse(new_any_flag, "TRUE", "FALSE") else new_any_flag
  df$n_live_claims <- if (was_char) ifelse(is.na(n_live_claims), "NA", as.character(n_live_claims)) else n_live_claims
  df
}
