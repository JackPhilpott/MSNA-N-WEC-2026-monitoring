# retry_file_write() - OneDrive-lock-tolerant file write.
#
# EXTRACTED 2026-09-22 from cleaning/real/prep_real_submissions.R, which
# defined it inline and was its only caller until cleaning/real/
# refresh_deletion_columns.R needed the same guarantee for the same file.
# Extracted rather than copied: a second hand-maintained copy of a
# retry/staging routine is exactly the duplicated-logic-silently-drifts
# pattern this project keeps re-finding. Behaviour is unchanged from the
# original - same staging/rename mechanism, same retry counts, same
# error-message matching.
#
# This whole workspace lives under a OneDrive-synced folder (data/'s own
# files show a ReparsePoint attribute — a Files-On-Demand cloud
# placeholder, confirmed 2026-08-25) — OneDrive's sync engine can hold a
# genuine, real (not imaginary) exclusive lock on the existing file for
# well over a minute at times, which a normal write_csv()/saveRDS() call
# has no way to wait out cheaply (each retry redoes the whole, slow
# write). Writes to a fresh sibling filename first — nothing has a lock on
# a name that doesn't exist yet, so this succeeds immediately — then
# retries only the cheap final rename into place, same spirit as the
# httr2 network-retry patch already used for shinyapps.io deploys, applied
# here to local file writes instead.
retry_file_write <- function(write_fn, final_path, max_attempts = 12, wait_seconds = 10) {
  staging_path <- paste0(final_path, ".staging")
  write_fn(staging_path) # not locked - nothing has this exact name open yet
  for (i in seq_len(max_attempts)) {
    # file.rename() on a failed rename often just returns FALSE with a
    # WARNING, not an R error — tryCatch only intercepts errors, so a
    # naive "did this throw?" check silently passes even when nothing
    # actually moved. Checking file.exists(final_path) alone is no better:
    # it's trivially TRUE whenever a PREVIOUS run already wrote something
    # there, regardless of whether THIS rename succeeded — confirmed as a
    # real bug 2026-08-25, not hypothetical (a rename silently failed,
    # this loop declared success after attempt 1 because the old file
    # from an earlier run was still sitting at final_path, and the
    # dashboard nearly deployed with real_meta.rds's fresh timestamp
    # paired against real_submissions.csv's stale one — caught only
    # because this run's content happened to be byte-identical to the
    # stale file, so nothing was visibly wrong that time). The only
    # unambiguous signal a rename actually happened is that the STAGING
    # file is gone afterward — rename always consumes its source on
    # success, and never does on failure.
    result <- tryCatch({ file.rename(staging_path, final_path) }, error = function(e) e)
    ok <- !inherits(result, "error") && !file.exists(staging_path)
    if (ok) return(invisible())
    if (inherits(result, "error") && !grepl("Cannot open file for writing|being used by another process|Permission denied|cannot rename", conditionMessage(result))) stop(result)
    cat("NOTE: couldn't move new", basename(final_path), "into place (attempt", i, "of", max_attempts, ") - likely a brief OneDrive sync lock on this workspace. Retrying in", wait_seconds, "s...\n")
    Sys.sleep(wait_seconds)
  }
  stop("retry_file_write: still could not rename ", staging_path, " to ", final_path, " after ", max_attempts, " attempts.")
}
