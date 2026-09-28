# ==============================================================================
# date_reconstruction.R - keep submission dates alive when the data officer's
# anonymised export arrives with start / end / today / _submission_time blank.
#
# WHY (2026-09-25): NGA2605_MSNA_anonymised_2026-09-24.xlsx was rewritten with
# those four columns empty for every row (all other columns intact). Nothing
# errored; prep would have written real_submissions.csv with every date NA, and
# every partner would have read "Not started". prep_real_submissions.R's guard
# now refuses such an export; this file is the permanent second line of defence
# - it fills the blanks instead of falling back to an older, staler export.
#
# WHAT IT DOES, per row whose start / end / today / _submission_time is blank
# (a valid export has NONE, so on a valid export this is a no-op):
#   1. CARRY FORWARD the exact values from the previous real_submissions.csv,
#      by uuid, when that row had them. The row keeps its ORIGINAL dates_source:
#      a row that was audit_reconstructed stays audit_reconstructed on every
#      later run - it can never be laundered into "carried_forward" or "export".
#   2. Otherwise DERIVE from the KoBo audit log (audit.zip, one audit.csv per
#      submission): start = 'form start' event epoch, end = last event, both
#      +1h because the export's times are WAT nominal; today = date(start).
#      Validated against 24,849 rows with known dates: start within 1s for
#      98.3%, 5s for 99.8%, 60s for 99.9%; derived date equal to the export's in
#      24,848 of 24,849. end is approximate (~90% within 60s: the audit finishes
#      before the final save).
#   3. uploaded_at (_submission_time) is server-side and not derivable: it stays
#      NA unless carried forward.
# Once a valid export returns, those rows are no longer blank, so they take the
# export's exact values and dates_source "export" automatically.
#
# dates_source per row: "export" | "carried_forward" | "audit_reconstructed" |
# "missing" (blank and nothing to fill it from). dates_reconstructed = TRUE only
# for audit_reconstructed rows. Callers must surface these on every run.
#
# Works on the raw export columns as prep reads them (character start/end/today/
# _submission_time). Reads audit logs ONLY for uuids that need them.
# ==============================================================================

DATE_RECON_WAT_OFFSET_MS <- 3600000
DATE_RECON_AUDIT_ZIP <- "cleaning/MSNA_Data_Cleaning/audit/audit.zip"

.dr_blank <- function(x) is.na(x) | trimws(as.character(x)) %in% c("", "NA")

.dr_format_ms <- function(ms) {
  out <- rep(NA_character_, length(ms))
  ok <- !is.na(ms)
  ms <- round(ms[ok])
  secs <- floor(ms / 1000)
  frac <- ms - secs * 1000
  out[ok] <- paste0(format(as.POSIXct(secs, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d %H:%M:%S"), ".", sprintf("%03d", as.integer(frac)))
  out
}

# form-start and last-event epoch ms for the given uuids (rows with no audit log
# or no usable events are simply absent from the result)
audit_form_times <- function(uuids, audit_zip_path = DATE_RECON_AUDIT_ZIP) {
  empty <- data.frame(uuid = character(), form_start_ms = numeric(), last_event_ms = numeric(), stringsAsFactors = FALSE)
  uuids <- unique(as.character(uuids[!is.na(uuids)]))
  if (length(uuids) == 0 || !file.exists(audit_zip_path)) return(empty)
  idx <- utils::unzip(audit_zip_path, list = TRUE)
  names_all <- gsub("\\\\", "/", as.character(idx$Name))
  is_audit <- grepl("(^|/)audit\\.csv$", names_all, ignore.case = TRUE)
  member_uuid <- sub("^.*/", "", sub("/audit\\.csv$", "", names_all, ignore.case = TRUE))
  keep <- is_audit & member_uuid %in% uuids
  members <- names_all[keep]; member_uuid <- member_uuid[keep]
  if (length(members) == 0) return(empty)
  # Extract in small chunks: utils::unzip(files = ...) looks every requested name
  # up against the whole central directory, so one call for thousands of members
  # is roughly quadratic (3,000 members took ~190s; chunks of 250 take ~1s each).
  use_fread <- requireNamespace("data.table", quietly = TRUE)
  read_audit <- function(path) {
    tryCatch({
      if (use_fread) as.data.frame(data.table::fread(path, colClasses = "character", select = 1:4, showProgress = FALSE, na.strings = c("", "NA")))
      else utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE, na.strings = c("", "NA"), colClasses = "character")
    }, error = function(e) NULL)
  }
  fs <- rep(NA_real_, length(members)); le <- rep(NA_real_, length(members))
  chunk_size <- 250L
  for (from in seq(1L, length(members), by = chunk_size)) {
    rows <- from:min(from + chunk_size - 1L, length(members))
    extract_dir <- tempfile("date_recon_audit_")
    dir.create(extract_dir, recursive = TRUE, showWarnings = FALSE)
    utils::unzip(audit_zip_path, files = members[rows], exdir = extract_dir, overwrite = TRUE)
    for (i in rows) {
      a <- read_audit(file.path(extract_dir, members[i]))
      if (is.null(a) || !all(c("event", "start") %in% names(a))) next
      st <- suppressWarnings(as.numeric(a$start))
      en <- if ("end" %in% names(a)) suppressWarnings(as.numeric(a$end)) else rep(NA_real_, length(st))
      fs_row <- st[a$event %in% "form start" & !is.na(st)]
      fs[i] <- if (length(fs_row) > 0) fs_row[1] else if (any(!is.na(st))) min(st, na.rm = TRUE) else NA_real_
      all_t <- c(st, en); all_t <- all_t[!is.na(all_t)]
      le[i] <- if (length(all_t) > 0) max(all_t) else NA_real_
    }
    unlink(extract_dir, recursive = TRUE, force = TRUE)
  }
  res <- data.frame(uuid = member_uuid, form_start_ms = fs, last_event_ms = le, stringsAsFactors = FALSE)
  res[!is.na(res$form_start_ms), , drop = FALSE]
}

# main : raw export "main" sheet as a data frame (needs uuid, start, end, today, _submission_time)
# prev : previous data/real_submissions.csv read as all-character, or NULL
# Returns list(main, summary); main gains dates_source and dates_reconstructed.
reconstruct_missing_dates <- function(main, prev = NULL, audit_zip_path = DATE_RECON_AUDIT_ZIP, allow = TRUE) {
  need <- c("uuid", "start", "end", "today", "_submission_time")
  if (!all(need %in% names(main))) stop("reconstruct_missing_dates(): export is missing column(s): ", paste(setdiff(need, names(main)), collapse = ", "))
  n <- nrow(main)
  b_start <- .dr_blank(main$start); b_end <- .dr_blank(main$end)
  b_today <- .dr_blank(main$today); b_up <- .dr_blank(main$`_submission_time`)
  needs <- b_start | b_end | b_today | b_up

  source_col <- rep("export", n)
  summary <- list(n_rows = n, n_blank_rows = sum(needs), n_carried_forward = 0L, n_audit_reconstructed = 0L, n_missing = 0L,
                  n_kept_reconstructed = 0L)
  if (!any(needs) || !allow) {
    if (any(needs)) source_col[needs] <- "missing"; summary$n_missing <- sum(needs)
    main$dates_source <- source_col
    main$dates_reconstructed <- FALSE
    return(list(main = main, summary = summary))
  }

  # ---- 1. carry forward exact values, keeping the original dates_source ----
  prev_src <- rep(NA_character_, n)
  p_start <- p_end <- p_today <- p_up <- rep(NA_character_, n)
  if (!is.null(prev) && all(c("submission_uuid", "start_datetime", "end_datetime", "uploaded_at", "submission_date") %in% names(prev))) {
    m <- match(as.character(main$uuid), prev$submission_uuid)
    has <- !is.na(m)
    take <- function(col) { v <- rep(NA_character_, n); v[has] <- as.character(prev[[col]][m[has]]); v[.dr_blank(v)] <- NA_character_; v }
    p_start <- take("start_datetime"); p_end <- take("end_datetime"); p_today <- take("submission_date"); p_up <- take("uploaded_at")
    prev_src[has] <- if ("dates_source" %in% names(prev)) as.character(prev$dates_source[m[has]]) else "export"
    prev_src[has & (is.na(prev_src) | prev_src == "" | prev_src == "NA")] <- "export"
  }
  new_start <- as.character(main$start); new_end <- as.character(main$end)
  new_today <- as.character(main$today); new_up <- as.character(main$`_submission_time`)
  fill_prev <- function(cur, blank, pv) { i <- blank & !is.na(pv); cur[i] <- pv[i]; list(v = cur, filled = i) }
  s1 <- fill_prev(new_start, b_start, p_start); e1 <- fill_prev(new_end, b_end, p_end)
  t1 <- fill_prev(new_today, b_today, p_today); u1 <- fill_prev(new_up, b_up, p_up)
  new_start <- s1$v; new_end <- e1$v; new_today <- t1$v; new_up <- u1$v
  any_carried <- needs & (s1$filled | e1$filled | t1$filled | u1$filled)

  # ---- 2. derive what is still blank from the audit log ----
  still_start <- .dr_blank(new_start); still_end <- .dr_blank(new_end); still_today <- .dr_blank(new_today)
  want_audit <- needs & (still_start | still_end | still_today)
  audit_derived <- rep(FALSE, n)
  if (any(want_audit)) {
    at <- audit_form_times(main$uuid[want_audit], audit_zip_path)
    ia <- match(as.character(main$uuid), at$uuid)
    ok <- !is.na(ia)
    st_str <- .dr_format_ms(at$form_start_ms[ia] + DATE_RECON_WAT_OFFSET_MS)
    en_str <- .dr_format_ms(at$last_event_ms[ia] + DATE_RECON_WAT_OFFSET_MS)
    i_s <- want_audit & still_start & ok; new_start[i_s] <- st_str[i_s]; audit_derived <- audit_derived | i_s
    i_e <- want_audit & still_end & ok; new_end[i_e] <- en_str[i_e]; audit_derived <- audit_derived | i_e
    still_today2 <- .dr_blank(new_today)
    i_t <- want_audit & still_today2 & !.dr_blank(new_start); new_today[i_t] <- substr(new_start[i_t], 1, 10); audit_derived <- audit_derived | i_t
  }

  # ---- 3. dates_source per row; a previously reconstructed row STAYS reconstructed ----
  src <- rep("export", n)
  src[needs] <- "missing"
  src[needs & any_carried] <- "carried_forward"
  src[needs & audit_derived] <- "audit_reconstructed"
  kept <- needs & any_carried & !audit_derived & !is.na(prev_src) & prev_src == "audit_reconstructed"
  src[kept] <- "audit_reconstructed"
  # a row that still has no start after all of the above is "missing", however
  # much else was filled (e.g. only its upload time carried forward)
  src[needs & .dr_blank(new_start) & src != "audit_reconstructed"] <- "missing"

  main$start <- new_start; main$end <- new_end; main$today <- new_today; main$`_submission_time` <- new_up
  main$dates_source <- src
  main$dates_reconstructed <- src == "audit_reconstructed"
  summary$n_carried_forward <- sum(src == "carried_forward")
  summary$n_audit_reconstructed <- sum(src == "audit_reconstructed")
  summary$n_kept_reconstructed <- sum(kept)
  summary$n_missing <- sum(src == "missing")
  list(main = main, summary = summary)
}
