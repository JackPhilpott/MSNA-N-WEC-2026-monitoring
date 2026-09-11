# ==============================================================================
# Merges a partner's RETURNED recovery workbook into their MASTER copy in
# ../outputs/<Partner>/ - in place, same file, same name. Built 2026-09-03
# per Jack, once IMC's response needed to become a real consolidated
# record: "commit those changes to their IMC workbook in the outputs...
# for the next round we send a new clean version but then once received
# back again it stacks onto this."
#
# Division of labour with the rest of the pipeline:
# - The RETURNED file in ../inputs/<Partner>/workbook/ is never modified -
#   it stays the untouched, literal record of what the partner sent back.
# - recovery_issue_tracker.csv (issue_tracker.R/.py) is the audit trail for
#   any row that needed an actual reviewer DECISION (a contest, a value we
#   had to pick on the partner's behalf) - see review_recovery_response.py.
# - THIS script is the third piece: it takes the partner's answers (plus
#   any tracker decision that overrides/completes them) and bakes them
#   into ../outputs/<Partner>/<Partner>_data_recovery_workbook_2026-08-30.
#   xlsx - the file that (a) can be sent back to the partner showing what's
#   resolved vs still outstanding, and (b) becomes the base a NEXT round's
#   fresh-data rebuild + returned-response merge stacks onto, so the master
#   copy accumulates across rounds instead of each round starting blank.
#
# Per-sheet merge logic (all matched by Interview ID / uuid, not row
# position - the master's own row order/count can differ from what a
# partner returned, e.g. a newly-surfaced row the partner never saw):
#
# - IDP Listing Duplicates: for each row present in the master,
#     1. if recovery_issue_tracker.csv has an idp_listing_duplicate
#        resolution for this uuid, that value wins (it's the reviewed,
#        final answer - may differ from what the partner literally typed,
#        e.g. a value we had to assign ourselves).
#     2. else if the partner's own CONFIRMED Listing Number is filled in,
#        use it as-is.
#     3. else if the partner left CONFIRMED blank but the row exists in
#        what they returned, retain the original Listing Number Recorded
#        (this workbook family's convention for "no change needed").
#     4. else (row wasn't in the returned file at all - e.g. a duplicate
#        that only surfaced in a later data refresh and was never actually
#        sent) - leave CONFIRMED blank with an explanatory note instead of
#        silently treating it as answered.
#   Partner notes are preserved as returned; a bracketed reviewer note is
#   appended only where the tracker supplied a value the partner didn't
#   themselves type into CONFIRMED (so it's clear on read-back who decided
#   what).
# - Missing HH Listings: partner's Yes/No + date + notes are copied over,
#   UNLESS an explicit override is supplied (KAFIN_SOLI_OVERRIDE below) -
#   built for the specific case of a partner marking "No" in this sheet
#   despite having actually submitted the real listing separately (checked
#   directly against hh_listing.xlsx, not taken on the partner's word) -
#   see that override's own comment for the full finding.
# - Confirmed Deletions / GPS Duplicates & Distant Pts: partner's answers
#   copied over as-is, no decision logic - these sheets just need the
#   partner's response preserved in the consolidated copy.
#
# Usage:
#   Rscript apply_returned_response.R <ORG_ID> <RETURNED_XLSX_PATH>
# ==============================================================================
suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(openxlsx)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("Usage: Rscript apply_returned_response.R <ORG_ID> <RETURNED_XLSX_PATH>")
ORG_ID <- toupper(args[1])
RETURNED_PATH <- args[2]

MONITORING_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring"
setwd(MONITORING_DIR)
SCRIPTS_DIR <- "reports/partner_data_recovery/scripts"

# FIX 2026-09-11: MASTER_PATH used to hardcode the literal date
# "2026-08-30" - same bug class verify_data_recovery_response.py already
# fixed 2026-09-06 with find_latest_workbook() (that fix was never ported
# to the R side). Mirrors that Python function's logic exactly: most
# recent <org>_data_recovery_workbook_<date>.xlsx by the date IN the
# filename, ISO dates sort correctly as strings.
find_latest_workbook <- function(partner_dir, org_id) {
  if (!dir.exists(partner_dir)) return(NA_character_)
  files <- list.files(partner_dir, pattern = paste0(
    "^", org_id, "_data_recovery_workbook_[0-9]{4}-[0-9]{2}-[0-9]{2}\\.xlsx$"
  ))
  if (length(files) == 0) return(NA_character_)
  file.path(partner_dir, sort(files)[length(files)])
}
MASTER_PATH <- find_latest_workbook(file.path("reports/partner_data_recovery/outputs", ORG_ID), ORG_ID)
TRACKER_PATH <- file.path(SCRIPTS_DIR, "recovery_issue_tracker.csv")

if (is.na(MASTER_PATH)) {
  stop(sprintf("No dated master workbook found for %s in reports/partner_data_recovery/outputs/%s/", ORG_ID, ORG_ID))
}
stopifnot(file.exists(MASTER_PATH), file.exists(RETURNED_PATH))

tracker <- if (file.exists(TRACKER_PATH)) read.csv(TRACKER_PATH, stringsAsFactors = FALSE) else NULL
tracker_lookup <- function(uuid, issue_type) {
  if (is.null(tracker)) return(NULL)
  hit <- tracker[tracker$uuid == uuid & tracker$issue_type == issue_type, ]
  if (nrow(hit) == 0) return(NULL)
  hit[nrow(hit), ]  # last write wins if ever re-run
}

wb <- loadWorkbook(MASTER_PATH)

# ---- one-off, explicit overrides (checked against source data, not taken on the partner's word) ----
# Kafin Soli (idp_NG021020_2): IMC's returned workbook says "No" (listing
# not yet submitted), but the actual HH Listing RandomSelect tool export
# shows exactly one submission for this cluster - org_id "imc",
# 2026-09-01 17:25:35 - i.e. submitted the same minute their covering
# email went out (17:26:09). Confirmed 2026-09-03 by querying hh_listing.
# xlsx directly: this is real, it's theirs, it exists. So this was partner
# confusion about which sheet to update, not an ongoing gap - overriding
# their "No" to "Yes" here. IMPORTANT caveat kept in the note: the 11
# interviews this cluster's Missing HH Listings row covers were fielded
# 2026-08-20, twelve days BEFORE this listing was drawn - so this
# submission validates any FUTURE draw at this site, it does not
# retroactively make the original interviews' ad hoc household numbers a
# real random sample (that's why those numbers are being accepted
# separately, as a documented security exception, not as if they'd been
# drawn from this listing).
MISSING_HH_OVERRIDES <- list(
  idp_NG021020_2 = list(
    submitted = "Yes",
    date = "2026-09-01",
    note_suffix = paste(
      "[Monitoring team, 2026-09-03: partner's own answer here was \"No\",",
      "but the HH Listing RandomSelect tool shows a real submission for",
      "this cluster from org_id=imc at 2026-09-01 17:25:35 - the same",
      "minute their covering email was sent. Treating as submitted;",
      "overriding the partner's \"No\" since it was very likely",
      "unrelated-sheet confusion, not an actual ongoing gap. Caveat: this",
      "listing postdates the 11 interviews here (fielded 2026-08-20) by",
      "12 days, so it validates future draws at this site but doesn't",
      "retroactively make the original ad hoc household numbers a real",
      "random sample - see IDP Listing Duplicates for how those are",
      "being handled instead.]"
    )
  )
)

# ==== 1. IDP Listing Duplicates ====
sheet <- "IDP Listing Duplicates"
master_df <- read_excel(MASTER_PATH, sheet = sheet, guess_max = 500)
returned_df <- tryCatch(read_excel(RETURNED_PATH, sheet = sheet, guess_max = 500), error = function(e) NULL)

confirmed_col <- which(names(master_df) == "CONFIRMED Listing Number")
notes_col <- which(names(master_df) == "Notes / Explanation")
id_col <- which(names(master_df) == "Interview ID")

n_from_tracker <- 0; n_from_partner <- 0; n_retained <- 0; n_unsent <- 0

for (i in seq_len(nrow(master_df))) {
  uuid <- master_df[[id_col]][i]
  xlsx_row <- i + 1  # +1 for header row

  tr <- tracker_lookup(uuid, "idp_listing_duplicate")
  ret_row <- if (!is.null(returned_df)) returned_df[returned_df$`Interview ID` == uuid, ] else NULL
  ret_confirmed <- if (!is.null(ret_row) && nrow(ret_row) == 1) ret_row$`CONFIRMED Listing Number`[1] else NA
  ret_note <- if (!is.null(ret_row) && nrow(ret_row) == 1) ret_row$`Notes / Explanation`[1] else NA

  if (!is.null(tr)) {
    confirmed_val <- as.numeric(tr$resolution[1])
    note_val <- if (!is.na(ret_note)) ret_note else NA
    if (is.na(ret_confirmed) || as.character(ret_confirmed) != as.character(confirmed_val)) {
      reviewer_note <- sprintf("[Monitoring team, %s: recorded %s per reviewed decision - see recovery_issue_tracker.csv.]",
                                tr$resolution_date[1], confirmed_val)
      note_val <- if (is.na(note_val)) reviewer_note else paste(note_val, reviewer_note)
    }
    writeData(wb, sheet, confirmed_val, startRow = xlsx_row, startCol = confirmed_col)
    if (!is.na(note_val)) writeData(wb, sheet, note_val, startRow = xlsx_row, startCol = notes_col)
    n_from_tracker <- n_from_tracker + 1
  } else if (!is.null(ret_row) && nrow(ret_row) == 1) {
    if (!is.na(ret_confirmed)) {
      writeData(wb, sheet, as.numeric(ret_confirmed), startRow = xlsx_row, startCol = confirmed_col)
      n_from_partner <- n_from_partner + 1
    } else {
      writeData(wb, sheet, master_df$`Listing Number Recorded`[i], startRow = xlsx_row, startCol = confirmed_col)
      n_retained <- n_retained + 1
    }
    if (!is.na(ret_note)) writeData(wb, sheet, ret_note, startRow = xlsx_row, startCol = notes_col)
  } else {
    writeData(wb, sheet,
      "[Monitoring team: not present in the workbook actually sent to the partner - surfaced by a later data refresh. Not a live duplicate needing partner reassignment (check Confirmed Deletions for this Interview ID).",
      startRow = xlsx_row, startCol = notes_col)
    n_unsent <- n_unsent + 1
  }
}
cat(sprintf("%s: %d rows from tracker decisions, %d from partner's own CONFIRMED, %d retained (partner left blank), %d not actually sent to partner\n",
            sheet, n_from_tracker, n_from_partner, n_retained, n_unsent))

# ==== 2. Missing HH Listings ====
sheet <- "Missing HH Listings"
master_df <- read_excel(MASTER_PATH, sheet = sheet, guess_max = 100)
returned_df <- tryCatch(read_excel(RETURNED_PATH, sheet = sheet, guess_max = 100), error = function(e) NULL)

cluster_col <- which(names(master_df) == "Cluster/Site ID")
submitted_col <- which(names(master_df) == "Household Listing Now Submitted? (Yes/No)")
date_col <- which(names(master_df) == "Date Submitted (if Yes)")
notes_col <- which(names(master_df) == "Notes / Explanation")

for (i in seq_len(nrow(master_df))) {
  cluster_id <- master_df[[cluster_col]][i]
  xlsx_row <- i + 1
  ret_row <- if (!is.null(returned_df)) returned_df[returned_df$`Cluster/Site ID` == cluster_id, ] else NULL
  ret_submitted <- if (!is.null(ret_row) && nrow(ret_row) == 1) ret_row$`Household Listing Now Submitted? (Yes/No)`[1] else NA
  ret_date <- if (!is.null(ret_row) && nrow(ret_row) == 1) ret_row$`Date Submitted (if Yes)`[1] else NA
  ret_note <- if (!is.null(ret_row) && nrow(ret_row) == 1) ret_row$`Notes / Explanation`[1] else NA

  override <- MISSING_HH_OVERRIDES[[cluster_id]]
  if (!is.null(override)) {
    writeData(wb, sheet, override$submitted, startRow = xlsx_row, startCol = submitted_col)
    writeData(wb, sheet, override$date, startRow = xlsx_row, startCol = date_col)
    note_val <- if (!is.na(ret_note)) paste(ret_note, override$note_suffix) else override$note_suffix
    writeData(wb, sheet, note_val, startRow = xlsx_row, startCol = notes_col)
    cat(sprintf("%s: %s overridden to Yes (%s) - see script header for why\n", sheet, cluster_id, override$date))
  } else if (!is.null(ret_row) && nrow(ret_row) == 1) {
    if (!is.na(ret_submitted)) writeData(wb, sheet, ret_submitted, startRow = xlsx_row, startCol = submitted_col)
    if (!is.na(ret_date)) writeData(wb, sheet, as.character(ret_date), startRow = xlsx_row, startCol = date_col)
    if (!is.na(ret_note)) writeData(wb, sheet, ret_note, startRow = xlsx_row, startCol = notes_col)
  }
}

# ==== 3. Confirmed Deletions ====
sheet <- "Confirmed Deletions"
master_df <- read_excel(MASTER_PATH, sheet = sheet, guess_max = 500)
returned_df <- tryCatch(read_excel(RETURNED_PATH, sheet = sheet, guess_max = 500), error = function(e) NULL)
id_col <- which(names(master_df) == "Interview ID")
contest_col <- which(names(master_df) == "Contest This? (Yes/No)")
explain_col <- which(names(master_df) == "If Yes, Explain")
n_copied <- 0
for (i in seq_len(nrow(master_df))) {
  uuid <- master_df[[id_col]][i]
  xlsx_row <- i + 1
  ret_row <- if (!is.null(returned_df)) returned_df[returned_df$`Interview ID` == uuid, ] else NULL
  if (!is.null(ret_row) && nrow(ret_row) == 1) {
    if (!is.na(ret_row$`Contest This? (Yes/No)`[1])) {
      writeData(wb, sheet, ret_row$`Contest This? (Yes/No)`[1], startRow = xlsx_row, startCol = contest_col)
      n_copied <- n_copied + 1
    }
    if (!is.na(ret_row$`If Yes, Explain`[1])) writeData(wb, sheet, ret_row$`If Yes, Explain`[1], startRow = xlsx_row, startCol = explain_col)
  }
}
cat(sprintf("%s: %d contest answers copied from returned workbook\n", sheet, n_copied))

# ==== 4. GPS Duplicates & Distant Pts ====
sheet <- "GPS Duplicates & Distant Pts"
if (sheet %in% names(wb)) {
  master_df <- read_excel(MASTER_PATH, sheet = sheet, guess_max = 500)
  returned_df <- tryCatch(read_excel(RETURNED_PATH, sheet = sheet, guess_max = 500), error = function(e) NULL)
  id_col <- which(names(master_df) == "Interview ID")
  confirmed_col <- which(names(master_df) == "CONFIRMED Household ID")
  genuine_col <- which(names(master_df) == "Genuine, Distinct Visit? (Yes/No/Unsure)")
  notes_col <- which(names(master_df) == "Notes / Explanation")
  n_copied <- 0
  for (i in seq_len(nrow(master_df))) {
    uuid <- master_df[[id_col]][i]
    xlsx_row <- i + 1
    ret_row <- if (!is.null(returned_df)) returned_df[returned_df$`Interview ID` == uuid, ] else NULL
    if (!is.null(ret_row) && nrow(ret_row) == 1) {
      if (!is.na(ret_row$`CONFIRMED Household ID`[1])) {
        writeData(wb, sheet, ret_row$`CONFIRMED Household ID`[1], startRow = xlsx_row, startCol = confirmed_col)
        n_copied <- n_copied + 1
      }
      if (!is.na(ret_row$`Genuine, Distinct Visit? (Yes/No/Unsure)`[1])) writeData(wb, sheet, ret_row$`Genuine, Distinct Visit? (Yes/No/Unsure)`[1], startRow = xlsx_row, startCol = genuine_col)
      if (!is.na(ret_row$`Notes / Explanation`[1])) writeData(wb, sheet, ret_row$`Notes / Explanation`[1], startRow = xlsx_row, startCol = notes_col)
    }
  }
  cat(sprintf("%s: %d rows copied from returned workbook\n", sheet, n_copied))
}

# ==== 5. Other Issues (added 2026-09-11) ====
# Modeled on IDP Listing Duplicates above (the tracker-priority block) -
# Other Issues also needs "the reviewed decision wins over the partner's
# raw answer". Two disjoint response-column pairs (date_outlier vs
# crs_unmatched) - which pair to write is driven by the MASTER's own
# "Issue Type" column (stable reference data, never partner-editable),
# never by which columns happen to be filled in the returned file.
sheet <- "Other Issues"
if (sheet %in% names(wb)) {
  master_df <- read_excel(MASTER_PATH, sheet = sheet, guess_max = 500)
  returned_df <- tryCatch(read_excel(RETURNED_PATH, sheet = sheet, guess_max = 500), error = function(e) NULL)
  id_col <- which(names(master_df) == "Interview ID")
  issue_type_col <- which(names(master_df) == "Issue Type")
  date_col <- which(names(master_df) == "Corrected Interview Date (if known)")
  genuine_col <- which(names(master_df) == "Genuine Interview on That Date? (Yes/No/Unsure)")
  cluster_col <- which(names(master_df) == "Correct Cluster/Site ID (if known)")
  identify_col <- which(names(master_df) == "Can Your Team Identify This Household? (Yes/No)")
  notes_col <- which(names(master_df) == "Notes / Explanation")

  n_from_tracker <- 0; n_from_partner <- 0; n_unsent <- 0

  for (i in seq_len(nrow(master_df))) {
    uuid <- master_df[[id_col]][i]
    issue_type_label <- master_df[[issue_type_col]][i]
    xlsx_row <- i + 1

    tr <- tracker_lookup(uuid, "confirmed_deletion")
    ret_row <- if (!is.null(returned_df)) returned_df[returned_df$`Interview ID` == uuid, ] else NULL
    ret_note <- if (!is.null(ret_row) && nrow(ret_row) == 1) ret_row$`Notes / Explanation`[1] else NA

    if (!is.null(tr)) {
      # The actual reviewed correction lives in the tracker's own
      # resolution text (set by review_other_issues()) - surfaced via
      # Notes rather than re-split back into the two structured columns,
      # since that resolution already covers both sub-fields for whichever
      # pair applies. Structured columns are left showing whatever the
      # partner originally proposed, if anything - the notes column is the
      # authoritative record of what was actually decided.
      reviewer_note <- sprintf("[Monitoring team, %s: %s - see recovery_issue_tracker.csv.]",
                                tr$resolution_date[1], tr$resolution[1])
      note_val <- if (!is.na(ret_note)) paste(ret_note, reviewer_note) else reviewer_note
      writeData(wb, sheet, note_val, startRow = xlsx_row, startCol = notes_col)
      n_from_tracker <- n_from_tracker + 1
    } else if (!is.null(ret_row) && nrow(ret_row) == 1) {
      if (identical(issue_type_label, "Date Outlier")) {
        if (!is.na(ret_row$`Corrected Interview Date (if known)`[1])) writeData(wb, sheet, as.character(ret_row$`Corrected Interview Date (if known)`[1]), startRow = xlsx_row, startCol = date_col)
        if (!is.na(ret_row$`Genuine Interview on That Date? (Yes/No/Unsure)`[1])) writeData(wb, sheet, ret_row$`Genuine Interview on That Date? (Yes/No/Unsure)`[1], startRow = xlsx_row, startCol = genuine_col)
      } else if (identical(issue_type_label, "CRS Unmatched")) {
        if (!is.na(ret_row$`Correct Cluster/Site ID (if known)`[1])) writeData(wb, sheet, ret_row$`Correct Cluster/Site ID (if known)`[1], startRow = xlsx_row, startCol = cluster_col)
        if (!is.na(ret_row$`Can Your Team Identify This Household? (Yes/No)`[1])) writeData(wb, sheet, ret_row$`Can Your Team Identify This Household? (Yes/No)`[1], startRow = xlsx_row, startCol = identify_col)
      }
      if (!is.na(ret_note)) writeData(wb, sheet, ret_note, startRow = xlsx_row, startCol = notes_col)
      n_from_partner <- n_from_partner + 1
    } else {
      writeData(wb, sheet,
        "[Monitoring team: not present in the workbook actually sent to the partner - surfaced by a later data refresh.]",
        startRow = xlsx_row, startCol = notes_col)
      n_unsent <- n_unsent + 1
    }
  }
  cat(sprintf("%s: %d rows from tracker decisions, %d from partner's own response, %d not actually sent to partner\n",
              sheet, n_from_tracker, n_from_partner, n_unsent))

  # Reverse-direction gap check (2026-09-11): a row present in the
  # partner's return but absent from the current master would otherwise be
  # silently invisible to the loop above, which only ever iterates the
  # master's own rows. Logged explicitly rather than allowed to vanish -
  # matches "verify, don't defend". NOTE: sheets 1-4 above don't have this
  # check yet - a pre-existing gap this feature doesn't inherit, but hasn't
  # been retrofitted onto the others either; a separate decision.
  if (!is.null(returned_df) && "Interview ID" %in% names(returned_df)) {
    extra_uuids <- setdiff(returned_df$`Interview ID`, master_df[[id_col]])
    if (length(extra_uuids) > 0) {
      cat(sprintf("%s: WARNING - %d row(s) in the partner's returned file are NOT in the current master (superseded/removed since sending?): %s\n",
                  sheet, length(extra_uuids), paste(extra_uuids, collapse = ", ")))
    }
  }
}

saveWorkbook(wb, MASTER_PATH, overwrite = TRUE)
system2("python", c(shQuote(file.path(SCRIPTS_DIR, "fix_openxlsx_roundtrip.py")), shQuote(MASTER_PATH)))
cat(sprintf("\nSaved consolidated master workbook: %s\n", MASTER_PATH))
