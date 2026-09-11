################################################################################
# audit_duration.R — 2_monitoring's OWN independent audit-based duration
# computation, built 2026-09-10 as part of the Achieved-definition redesign.
################################################################################
# WHY THIS EXISTS
# ------------------------------------------------------------------------------
# duration_under_20 is a NO-APPEAL auto-delete rule (issue_tracker.R's
# NO_APPEAL_DELETION_REASONS) — it removes a submission permanently, with zero
# partner review, the moment it fires. Until tonight this workspace had
# exactly ONE computation of interview duration feeding that decision: the
# data officer's own audit-trail-based pipeline
# (cleaning/MSNA_Data_Cleaning/R/audit_cache.R, which delegates the actual
# math to cleaningtools::create_duration_from_audit_sum_all()).
# prep_real_submissions.R's own duration_min was never wired into the
# deletion decision at all — it's a simple end-minus-start field diff, kept
# purely as an informational flag_duration_outlier ("flagged, NOT excluded
# from achieved counts").
#
# Cross-checking the DO's duration_under_20 output against that naive
# end-minus-start figure (2026-09-10) found a genuine two-way disagreement —
# 72 submissions the DO's pipeline flags as under 20 minutes that the naive
# diff puts at 42–365 minutes, and 334 the other way. Too large and too
# one-sided to be rounding noise, and far too consequential (no-appeal
# deletion) to leave unresolved. Jack, 2026-09-10: stop relying on the naive
# end-minus-start figure for this decision entirely — build our own
# independent computation from the SAME raw audit trail data, so this
# workspace isn't depending on a single, unverifiable source for an
# unappealable removal.
#
# Deliberately NOT reimplementing the duration algorithm itself — a second,
# differently-buggy guess at the same problem would help no one. This calls
# the exact same cleaningtools::create_duration_from_audit_sum_all() the DO's
# own pipeline uses, directly, on our own independent read of the same raw
# audit.zip. Any disagreement that remains after this is a genuine signal
# (their cache stale, their zip snapshot older than ours, or a real pipeline
# bug on their side) rather than two different philosophies of "duration."
#
# ---- Source (read-only) ------------------------------------------------------
# cleaning/MSNA_Data_Cleaning/audit/audit.zip — the data officer's own raw
# Kobo audit-trail export (one audit.csv per submission uuid, inside a single
# top-level hash folder). Same file their own audit_cache.R reads. Read-only,
# per this workspace's standing rule (see register_deletion_log_issues.R's
# header) — 2_monitoring's scripts read the data officer's already-written
# files, never modify them.
#
# ---- Caching -------------------------------------------------------------
# Mirrors audit_cache.R's own design (memory-safe: cleaningtools's own
# create_audit_list() would hold every audit.csv in memory at once — several
# GB on a mature dataset — so this parses one uuid at a time and caches by
# uuid + uncompressed audit.csv byte length, so an unchanged submission is
# never re-parsed). Cache lives at cleaning/real/audit_duration_cache.csv —
# entirely separate from the data officer's own cache
# (cleaning/MSNA_Data_Cleaning/audit/audit_duration_cache.csv), so the two
# pipelines can never contend for the same file, and a stale or corrupt cache
# on their side can never silently affect our own number.
#
# NA handling (Jack, 2026-09-10): a submission with no audit.csv at all
# already self-heals for free — the ZIP manifest is re-read fresh on every
# call, so a uuid absent today simply isn't in the cache yet and gets parsed
# the moment a later ZIP snapshot actually contains it, no extra logic
# needed. What did NOT self-heal until this fix: a uuid whose audit.csv IS
# present but fails to parse (found live during the first full-dataset run —
# at least one file hit an embedded-NUL read error) would get NA cached
# against that file's byte length, and since a broken file's size doesn't
# change on its own, it would stay NA forever even after the underlying
# problem is fixed. Parse failures are therefore never written to the cache
# at all now — treated exactly like "not downloaded yet", retried on every
# subsequent call until they actually succeed, never permanently stuck.
#
# Requires the `cleaningtools` package (impact-initiatives/cleaningtools on
# GitHub — not on CRAN). Installed into this project's renv library
# 2026-09-10 via remotes::install_github("impact-initiatives/cleaningtools").
#
# Usage: source("cleaning/real/audit_duration.R")
#        durations <- compute_our_audit_durations()  # uuid, duration_audit_sum_all_ms, duration_audit_sum_all_minutes
################################################################################
suppressPackageStartupMessages({
  library(cleaningtools)
})

OUR_AUDIT_ZIP_PATH <- "cleaning/MSNA_Data_Cleaning/audit/audit.zip"
OUR_AUDIT_CACHE_DIR <- "cleaning/real"
OUR_AUDIT_CACHE_FILE <- file.path(OUR_AUDIT_CACHE_DIR, "audit_duration_cache.csv")

.our_audit_zip_manifest <- function(audit_zip_path) {
  zip_index <- utils::unzip(audit_zip_path, list = TRUE)
  keep <- grepl("(^|/)audit\\.csv$", zip_index$Name, ignore.case = TRUE)
  zip_index <- zip_index[keep, , drop = FALSE]
  if (nrow(zip_index) == 0) {
    stop("compute_our_audit_durations(): no audit.csv files found inside ", audit_zip_path)
  }
  archive_name <- gsub("\\\\", "/", as.character(zip_index$Name))
  without_file <- sub("/audit\\.csv$", "", archive_name, ignore.case = TRUE)
  uuid <- sub("^.*/", "", without_file)
  manifest <- data.frame(
    uuid = uuid, archive_name = archive_name,
    archive_length = as.numeric(zip_index$Length), stringsAsFactors = FALSE
  )
  if (anyDuplicated(manifest$uuid)) {
    dup <- unique(manifest$uuid[duplicated(manifest$uuid)])
    warning(
      "Audit ZIP contains duplicate UUID folder(s): ",
      paste(utils::head(dup, 10), collapse = ", "),
      if (length(dup) > 10) " ..." else "",
      ". Keeping the last occurrence of each UUID."
    )
    manifest <- manifest[!duplicated(manifest$uuid, fromLast = TRUE), , drop = FALSE]
  }
  rownames(manifest) <- NULL
  manifest
}

.read_our_audit_cache <- function(cache_file) {
  if (!file.exists(cache_file)) return(NULL)
  tryCatch({
    x <- utils::read.csv(cache_file, stringsAsFactors = FALSE, check.names = FALSE)
    required <- c("uuid", "archive_name", "archive_length", "duration_audit_sum_all_ms")
    if (!all(required %in% names(x))) stop("cache missing required column(s)")
    x$uuid <- as.character(x$uuid)
    x$archive_name <- as.character(x$archive_name)
    x$archive_length <- suppressWarnings(as.numeric(x$archive_length))
    x$duration_audit_sum_all_ms <- suppressWarnings(as.numeric(x$duration_audit_sum_all_ms))
    # Drop any NA rows on read (parse failures from before this fix, or from
    # an interrupted run) — treating them as never-cached forces an
    # immediate retry rather than reusing a stale "couldn't parse it" result
    # forever, per Jack's 2026-09-10 request.
    x[!is.na(x$duration_audit_sum_all_ms), , drop = FALSE]
  }, error = function(e) {
    warning("Our audit duration cache unreadable (", conditionMessage(e), ") — rebuilding from ZIP.")
    NULL
  })
}

.write_our_audit_cache <- function(x, cache_file) {
  dir.create(dirname(cache_file), recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile("our_audit_duration_cache_", tmpdir = dirname(cache_file), fileext = ".csv")
  on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
  utils::write.csv(
    x[, c("uuid", "archive_name", "archive_length", "duration_audit_sum_all_ms")],
    tmp, row.names = FALSE, na = ""
  )
  if (file.exists(cache_file)) unlink(cache_file)
  if (!file.rename(tmp, cache_file)) {
    if (!file.copy(tmp, cache_file, overwrite = TRUE)) stop("Could not write ", cache_file)
    unlink(tmp)
  }
  invisible(cache_file)
}

.parse_our_audit_durations <- function(audit_zip_path, manifest_subset, verbose = TRUE) {
  n <- nrow(manifest_subset)
  if (n == 0) {
    return(data.frame(uuid = character(), archive_name = character(),
                       archive_length = numeric(), duration_audit_sum_all_ms = numeric(),
                       stringsAsFactors = FALSE))
  }
  extract_dir <- tempfile("our_audit_extract_")
  dir.create(extract_dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(extract_dir, recursive = TRUE, force = TRUE), add = TRUE)
  if (verbose) message("  our audit duration cache: extracting ", n, " new/changed audit file(s)...")
  utils::unzip(zipfile = audit_zip_path, files = manifest_subset$archive_name, exdir = extract_dir, overwrite = TRUE)

  out_ms <- rep(NA_real_, n)
  failed <- character(0)
  for (i in seq_len(n)) {
    audit_file <- file.path(extract_dir, manifest_subset$archive_name[i])
    result <- tryCatch({
      audit_df <- utils::read.csv(audit_file, stringsAsFactors = FALSE, check.names = FALSE, na.strings = c("", "NA"))
      required <- c("node", "start", "end")
      if (!all(required %in% names(audit_df))) stop("missing required audit column(s)")
      dur <- cleaningtools::create_duration_from_audit_sum_all(audit_df)
      as.numeric(dur$duration_ms[[1]])
    }, error = function(e) {
      failed <<- c(failed, paste0(manifest_subset$uuid[i], ": ", conditionMessage(e)))
      NA_real_
    })
    out_ms[i] <- result
    if (verbose && (i %% 500L == 0L || i == n)) {
      message("  our audit duration cache: parsed ", i, "/", n)
    }
  }
  if (length(failed) > 0) {
    warning(length(failed), " audit file(s) failed to parse. First few: ",
            paste(utils::head(failed, 5), collapse = " | "))
  }
  data.frame(uuid = manifest_subset$uuid, archive_name = manifest_subset$archive_name,
             archive_length = manifest_subset$archive_length,
             duration_audit_sum_all_ms = out_ms, stringsAsFactors = FALSE)
}

# Public entry point. Returns uuid, duration_audit_sum_all_ms,
# duration_audit_sum_all_minutes for every submission with an audit.csv in
# the ZIP — independently computed, own cache, read-only against the data
# officer's raw audit export. only_uuids optionally restricts parsing to a
# subset (useful for fast targeted verification before a full-dataset run).
compute_our_audit_durations <- function(audit_zip_path = OUR_AUDIT_ZIP_PATH,
                                          cache_file = OUR_AUDIT_CACHE_FILE,
                                          force_rebuild = FALSE,
                                          only_uuids = NULL,
                                          verbose = TRUE) {
  if (!file.exists(audit_zip_path)) {
    stop("compute_our_audit_durations(): audit zip not found at ", audit_zip_path)
  }
  manifest <- .our_audit_zip_manifest(audit_zip_path)
  if (!is.null(only_uuids)) {
    manifest <- manifest[manifest$uuid %in% only_uuids, , drop = FALSE]
  }
  cached <- if (force_rebuild) NULL else .read_our_audit_cache(cache_file)

  current_key <- paste(manifest$uuid, manifest$archive_length, sep = "\r")
  if (!is.null(cached)) {
    cached_key <- paste(cached$uuid, cached$archive_length, sep = "\r")
    reuse_index <- match(current_key, cached_key)
  } else {
    reuse_index <- rep(NA_integer_, nrow(manifest))
  }
  needs_parse <- is.na(reuse_index)
  n_reuse <- sum(!needs_parse); n_parse <- sum(needs_parse)
  if (verbose) {
    message("  our audit duration cache: ", nrow(manifest), " audit UUID(s) in scope; ",
            n_reuse, " reused; ", n_parse, " new/changed.")
  }

  result <- manifest
  result$duration_audit_sum_all_ms <- NA_real_
  if (n_reuse > 0) {
    idx <- reuse_index[!needs_parse]
    result$duration_audit_sum_all_ms[!needs_parse] <- cached$duration_audit_sum_all_ms[idx]
  }
  if (n_parse > 0) {
    parsed <- .parse_our_audit_durations(audit_zip_path, manifest[needs_parse, , drop = FALSE], verbose = verbose)
    m <- match(result$uuid[needs_parse], parsed$uuid)
    result$duration_audit_sum_all_ms[needs_parse] <- parsed$duration_audit_sum_all_ms[m]
  }

  # Merge into (not overwrite) any existing broader cache, so a targeted,
  # only_uuids-scoped run doesn't truncate a previously-built full cache.
  if (!is.null(cached)) {
    merged <- rbind(
      cached[!(cached$uuid %in% result$uuid), c("uuid", "archive_name", "archive_length", "duration_audit_sum_all_ms")],
      result[, c("uuid", "archive_name", "archive_length", "duration_audit_sum_all_ms")]
    )
  } else {
    merged <- result[, c("uuid", "archive_name", "archive_length", "duration_audit_sum_all_ms")]
  }
  # Never persist a parse failure — a NA here means this call's attempt
  # didn't succeed (this run's own failures, or ones inherited from a
  # pre-fix cache that .read_our_audit_cache() already stripped on read).
  # Dropping it from what's written means the next call sees no cache entry
  # at all for that uuid and retries it fresh, rather than reusing a stale
  # "couldn't parse it" result indefinitely.
  n_dropped <- sum(is.na(merged$duration_audit_sum_all_ms))
  if (verbose && n_dropped > 0) {
    message("  our audit duration cache: ", n_dropped, " parse failure(s) not cached — will retry next call.")
  }
  merged <- merged[!is.na(merged$duration_audit_sum_all_ms), , drop = FALSE]
  .write_our_audit_cache(merged, cache_file)

  result$duration_audit_sum_all_minutes <- round(result$duration_audit_sum_all_ms / 60000, digits = 1)
  if (verbose) message("  our audit duration cache: ready — ", nrow(result), " UUID(s) returned this call.")
  result[, c("uuid", "duration_audit_sum_all_ms", "duration_audit_sum_all_minutes")]
}
