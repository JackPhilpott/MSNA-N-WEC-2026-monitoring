suppressPackageStartupMessages(library(openxlsx))

reason_text_map <- c(
  duration_under_20 = "Interview duration was under 20 minutes (audit-based). Physically too fast to have been genuinely completed for this survey.",
  duration_under_30 = "Interview duration was under 20 minutes, also flagged by the officer's own duration check.",
  fcs_zero = "All 8 food-consumption categories recorded as zero days - not a plausible response.",
  no_consent = "Consent was not given for this interview.",
  # FIX 2026-09-21: this reason used to reach this sheet for BOTH population
  # types with a text pointing at "the Non-IDP Duplicates sheet" regardless -
  # wrong for an IDP row, since that sheet never actually covered them (see
  # full_batch_pipeline.R's del_pop_type fix, same date). Non-IDP duplicate_
  # point rows are now exclusively routed to their own sheet before reaching
  # here, so anything under this reason in Confirmed Deletions is always IDP.
  duplicate_point = "This interview's listing/point details matched another submission already on file for the same IDP site -- flagged as a duplicate interview.",
  pct_missing_flagged = "Flagged as a statistical outlier for missingness -- an unusually high proportion of applicable questions were left unanswered relative to the rest of the sample.",
  # ADDED 2026-09-11, for the new Other Issues sheet below.
  date_outlier = "This interview's recorded submission date looks wrong (before fielding started, or in the future) -- almost always a device clock that was set incorrectly, not a real problem with the interview itself.",
  # TIGHTENED 2026-09-14 (Jack's request): the old text only said "sample
  # points", leaving it ambiguous that we don't even know the population
  # type (IDP/non-IDP) - now says so explicitly, matching the new "Was
  # This an IDP or Non-IDP Household?" column added to this sheet below.
  crs_unmatched = "This interview couldn't be matched to any of your team's assigned sample points at all -- the export shows no sample point ID, cluster ID, or IDP/non-IDP population-type selection recorded for it whatsoever, so we don't even know which of your sample types this belongs to, let alone which specific household/building."
)

# Reasons that register as immediately confirmed, no appeal (2026-09-06, per
# Jack: validated methodology thresholds, not partner judgment calls) - kept
# in sync with issue_tracker.R's NO_APPEAL_DELETION_REASONS, not sourced
# from it directly, since this file doesn't otherwise depend on the tracker
# (full_batch_pipeline.R does that filtering and hands this file a plain
# is_appealable column instead).
NO_APPEAL_CONTEST_NOTE <- "No action needed -- confirmed per validated assessment methodology, not open to contest."

build_partner_workbook <- function(pkg, out_path, deadline = "4 September 2026") {
  wb <- createWorkbook()
  hdr_ref    <- createStyle(fgFill = "#DDE6E1", textDecoration = "bold", wrapText = TRUE, border = "TopBottomLeftRight")
  hdr_fill   <- createStyle(fgFill = "#FCEFD0", textDecoration = "bold", wrapText = TRUE, border = "TopBottomLeftRight")
  title_style<- createStyle(fontSize = 14, textDecoration = "bold")
  note_style <- createStyle(wrapText = TRUE, valign = "top")
  flag_style <- createStyle(fgFill = "#F3DAD4", textDecoration = "bold")

  write_headers <- function(sheet, row, cols, style) for (i in seq_along(cols)) addStyle(wb, sheet, style, rows = row, cols = cols[i])

  n_gps <- nrow(pkg$gps_sheet); n_idp <- nrow(pkg$idp_sheet); n_del <- nrow(pkg$del_sheet); n_listing <- nrow(pkg$listing_sheet)
  n_other <- nrow(pkg$other_sheet); n_nonidp_dup <- nrow(pkg$nonidp_dup_sheet)

  # ---------------- READ ME ----------------
  addWorksheet(wb, "READ ME")
  readme <- c(
    paste0(toupper(pkg$org), " — MSNA N-WEC 2026 — Data Recovery Request"),
    "",
    paste0("Please return this workbook by ", deadline, " — sooner is genuinely appreciated, as the resampling plan is being finalised around this data."),
    "",
    "WHAT THIS IS",
    "Two categories of your team's interviews have been flagged during monitoring: some we believe may be genuine but mislabeled (recoverable with your confirmation), and some that are confirmed for deletion regardless. A cluster availability sheet shows how many sample points remain open in your affected clusters, and an enumerator performance sheet gives a full breakdown of your team's performance by enumerator. Sheets are ordered below roughly by how much we need from you to resolve them, and where a submission date is known it's now shown directly on the sheet (2026-09-14) so your team doesn't have to track it down separately.",
    "",
    "HOW TO USE THE OTHER ISSUES SHEET",
    "A small, growing home for data-quality issues that don't fit one of the sheets below -- each row is ONE of two different problems, so check the 'Issue Type' column first: a 'Date Outlier' row has a wrong-looking submission date (almost always a device clock issue) but IS matched to a real point -- only the two 'Corrected Interview Date' / 'Genuine Interview on That Date?' columns apply to those rows. A 'CRS Unmatched' row couldn't be matched to any assigned point at all, and we also don't know whether it was an IDP or non-IDP household -- the 'Was This an IDP or Non-IDP Household?' column plus 'Correct Cluster/Site ID' / 'Can Your Team Identify This Household?' apply to those rows. The other pair of columns will be blank on any given row -- that's expected, not a mistake.",
    "",
    "HOW TO USE THE MISSING HH LISTINGS SHEET",
    "One row per cluster/site with no Household Listing submission on file yet -- State/LGA/Ward, the frame's target sample and population estimate for that site, and the specific Interview ID(s) and date(s) already collected there but still unverifiable are all included so your team can find and prioritise the right site. The actual listing itself still needs to be submitted through the normal Household Listing form/channel, same as any other site -- this sheet is just to confirm back to us that it's been done (or tell us why not yet), so we know to re-check for it rather than assuming it's still missing.",
    "",
    "HOW TO USE THE GPS / IDP / NON-IDP DUPLICATE SHEETS",
    "Each row is one interview where the recorded GPS/listing/point ID doesn't match what it's credited to, or is shared with another submission. Where we can, we've suggested up to 3 nearby alternatives based on our own sampling frame, and the 'Confirmed' column is a dropdown limited to the households/listing numbers still available in that same cluster -- we can only accept a correction within the same cluster the interview was originally assigned to. Where a 'Match Confidence' column reads 'No nearby match', our suggestions probably aren't correct -- for those rows, please just tell us what you think happened rather than picking from the list. On the Non-IDP Duplicates sheet, the 'Other Submission(s) Claiming Same Point' column lists exactly who else (including from another partner, if relevant) currently claims the same point, so your team can compare directly. If your team can't determine the answer, that's a valid response.",
    "",
    "HOW TO USE THE OVERSAMPLED CLUSTERS SHEET",
    "One row per cluster where your team has already collected more Achieved interviews than that cluster's target. Nothing to fix or confirm here - it's purely so your team knows to prioritise other clusters (rather than this one) for any further data collection. Note the Achieved total quoted in our covering email is adjusted down for this surplus, to match how the dashboard reports progress - the totals shown within this workbook are not, since no specific interview has been chosen for exclusion yet.",
    "",
    "WHAT HAPPENS WITHOUT A RESPONSE",
    "Rows we don't hear back on by the deadline stay flagged and unresolved rather than being cleared either way -- please respond even if the answer is \"we don't know\", since only a genuine resolution (confirmed as a real interview, or confirmed as incorrect and removed) actually closes these out. We only remove an interview from your Achieved count for an automatic, no-appeal deletion (an interview under 20 minutes, or no consent given), or once something on this list has actually been resolved and confirmed incorrect -- never just for going unanswered.",
    "",
    "A NOTE ON THE DURATION-BASED DELETIONS",
    paste0("Interviews under 20 minutes are currently being treated as confirmed deletions -- ", pkg$n_duration_under_20_total, " of your team's interviews fall under this (already reflected in the Confirmed Deletions sheet). From our testing, we think it is highly implausible to collect accurate data under 30 minutes. We will continue to verify this but until then we are confident in dropping all surveys under 20 minutes, and we remain concerned about interviews in the 20-30 minute range too -- a further ", pkg$n_duration_20_30_total, " of your team's interviews fall in that band. These aren't being deleted at this stage, but we're flagging them now, ahead of time, so it isn't a surprise if some end up affected in a future round."),
    "",
    "QUESTIONS",
    "Contact your regional FACT Coordinator or any of the IMPACT focal points if you have any questions before the deadline."
  )
  writeData(wb, "READ ME", readme, startCol = 1, startRow = 1, colNames = FALSE)
  addStyle(wb, "READ ME", title_style, rows = 1, cols = 1)
  setColWidths(wb, "READ ME", cols = 1, widths = 110)
  for (r in seq_along(readme)) addStyle(wb, "READ ME", note_style, rows = r, cols = 1, stack = TRUE)

  # ---------------- Lookup sheets (only if needed) ----------------
  # 2026-09-21: also gated on n_nonidp_dup now - full_batch_pipeline.R
  # extends pkg$cluster_lookup_nonidp with any Non-IDP Duplicates cluster
  # not already covered by a GPS Duplicate, for that sheet's own "CONFIRMED
  # Point ID" dropdown below. A partner with Non-IDP Duplicates but zero
  # GPS Duplicates would otherwise get no Lookup_NonIDP sheet at all.
  if (n_gps > 0 || n_nonidp_dup > 0) {
    addWorksheet(wb, "Lookup_NonIDP", visible = FALSE)
    cl <- pkg$cluster_lookup_nonidp
    for (i in seq_len(nrow(cl))) {
      cid <- cl$cluster_id[i]; vals <- cl$avail[[i]]; if (length(vals)==0) vals <- "(none available)"
      writeData(wb, "Lookup_NonIDP", vals, startCol = i, startRow = 1, colNames = FALSE)
      createNamedRegion(wb, sheet = "Lookup_NonIDP", name = cid, cols = i, rows = 1:length(vals))
    }
  }
  if (n_idp > 0) {
    addWorksheet(wb, "Lookup_IDP", visible = FALSE)
    cl <- pkg$cluster_lookup_idp
    for (i in seq_len(nrow(cl))) {
      cid <- cl$idp_cluster_id[i]; vals <- as.character(cl$avail_list[[i]]); if (length(vals)==0) vals <- "(none available)"
      writeData(wb, "Lookup_IDP", vals, startCol = i, startRow = 1, colNames = FALSE)
      createNamedRegion(wb, sheet = "Lookup_IDP", name = paste0("idp_", cid), cols = i, rows = 1:length(vals))
    }
  }

  # ---------------- Other Issues (added 2026-09-11) ----------------
  # Home for date_outlier/crs_unmatched, and future ad hoc checks per
  # Jack's own framing - always-present (Missing HH Listings convention),
  # not omitted-when-empty (GPS/IDP convention), since this is meant to be
  # an ongoing, recurring sheet. Two genuinely different problems share one
  # sheet with disjoint response-column pairs (row-scoped, never a whole
  # column) rather than two headers, since verify_data_recovery_response.py
  # compares one flat header list per sheet - see
  # _working_files/other_issues_sheet_design_2026-09-11.md.
  # REORDERED 2026-09-14 to FIRST actionable sheet (Jack's request: sheets
  # ordered by how much we need from the partner to resolve them - a "we
  # can't identify this household/pop-type at all" row is the hardest to
  # resolve and needs the most partner input, so it goes first). Also
  # gained a Date of Submission column and the "Was This an IDP or Non-IDP
  # Household?" ask (see reason_text_map's crs_unmatched text above for
  # why that specific gap existed - found via Jack's Bassa/CRS question).
  s4b <- "Other Issues"
  addWorksheet(wb, s4b)
  if (n_other > 0) {
    is_date_outlier <- pkg$other_sheet$reason == "date_outlier"
    out4b <- pkg$other_sheet %>% transmute(
      `Interview ID` = uuid, `Enumerator ID` = enum_id,
      `State` = state, `LGA` = lga, `Ward` = ward, `Date of Submission` = as.character(submission_date),
      `Cluster ID` = cluster_id,
      `Issue Type` = if_else(reason == "date_outlier", "Date Outlier", "CRS Unmatched"),
      `What We Found` = reason_text_map[reason],
      `Was This an IDP or Non-IDP Household? (IDP/Non-IDP/Unsure)` = NA_character_,
      `Corrected Interview Date (if known)` = NA_character_,
      `Genuine Interview on That Date? (Yes/No/Unsure)` = NA_character_,
      `Correct Cluster/Site ID (if known)` = NA_character_,
      `Can Your Team Identify This Household? (Yes/No)` = NA_character_,
      `Notes / Explanation` = NA_character_
    )
    writeData(wb, s4b, out4b, headerStyle = hdr_ref, withFilter = TRUE)
    write_headers(s4b, 1, 10:15, hdr_fill)
    date_outlier_rows <- which(is_date_outlier) + 1
    crs_unmatched_rows <- which(!is_date_outlier) + 1
    if (length(crs_unmatched_rows) > 0) {
      dataValidation(wb, s4b, cols = 10, rows = crs_unmatched_rows, type = "list", value = '"IDP,Non-IDP,Unsure"')
    }
    if (length(date_outlier_rows) > 0) {
      dataValidation(wb, s4b, cols = 12, rows = date_outlier_rows, type = "list", value = '"Yes,No,Unsure"')
    }
    if (length(crs_unmatched_rows) > 0) {
      dataValidation(wb, s4b, cols = 14, rows = crs_unmatched_rows, type = "list", value = '"Yes,No"')
    }
    for (r in 1:(nrow(out4b)+1)) { addStyle(wb, s4b, note_style, rows = r, cols = 9, stack = TRUE); addStyle(wb, s4b, note_style, rows = r, cols = 15, stack = TRUE) }
    freezePane(wb, s4b, firstActiveRow = 2, firstActiveCol = 2)
    setColWidths(wb, s4b, cols = 1:15, widths = c(20,16,10,14,14,12,20,14,50,26,20,20,20,20,40))
  } else {
    writeData(wb, s4b, tibble::tibble(`Note` = "No other outstanding issues recorded for your team at this time."), headerStyle = hdr_ref)
    setColWidths(wb, s4b, cols = 1, widths = 90)
  }

  # ---------------- Missing HH Listings ----------------
  # Redesigned 2026-08-31, per Jack: the old version (State/LGA/count only)
  # didn't give a field team enough to actually find and list the right
  # site, and had no action column at all -- rebuilt per-CLUSTER with the
  # same "enough to locate it + a specific thing to confirm back" standard
  # the GPS/IDP sheets already met. Gained an Interview Dates Affected
  # column 2026-09-14 (Jack's request), parallel to Interview IDs Affected.
  s4 <- "Missing HH Listings"
  addWorksheet(wb, s4)
  if (n_listing > 0) {
    out4 <- pkg$listing_sheet %>% transmute(
      `Cluster/Site ID` = cluster_id, `IOM Site Name` = iom_site_name, `Population Type` = pop_type,
      `State` = state, `LGA` = lga, `Ward` = ward,
      `Target Households (required sample)` = target_households,
      `Households in Cluster (population estimate)` = households_in_cluster,
      `Affected Interviews` = affected_interviews, `Interview IDs Affected` = interview_ids,
      `Interview Dates Affected` = interview_dates,
      `Household Listing Now Submitted? (Yes/No)` = NA_character_,
      `Date Submitted (if Yes)` = NA_character_,
      `Notes / Explanation` = NA_character_
    )
    writeData(wb, s4, out4, headerStyle = hdr_ref, withFilter = TRUE)
    write_headers(s4, 1, 12:14, hdr_fill)
    dataValidation(wb, s4, cols = 12, rows = 2:(nrow(out4)+1), type = "list", value = '"Yes,No"')
    for (r in 1:(nrow(out4)+1)) { addStyle(wb, s4, note_style, rows = r, cols = 10, stack = TRUE); addStyle(wb, s4, note_style, rows = r, cols = 11, stack = TRUE); addStyle(wb, s4, note_style, rows = r, cols = 14, stack = TRUE) }
    freezePane(wb, s4, firstActiveRow = 2, firstActiveCol = 2)
    setColWidths(wb, s4, cols = 1:14, widths = c(20,20,12,12,16,14,16,20,12,50,30,16,16,40))
  } else {
    writeData(wb, s4, tibble::tibble(`Note` = "No missing Household Listing gaps are currently recorded for your team."), headerStyle = hdr_ref)
    setColWidths(wb, s4, cols = 1, widths = 90)
  }

  # ---------------- GPS Duplicates & Distant Points ----------------
  if (n_gps > 0) {
    s2 <- "GPS Duplicates & Distant Pts"
    addWorksheet(wb, s2)
    out2 <- pkg$gps_sheet %>% transmute(
      `Interview ID` = uuid, `Enumerator ID` = enum_id, `State` = state_name, `LGA` = lga_name, `Ward` = ward_name,
      `Date of Submission` = as.character(submission_date), `Point ID Recorded` = non_idp_point_id, `Cluster ID` = cluster_id,
      `Distance From Recorded Point (m)` = round(dist_to_claimed_device),
      `Match Confidence` = match_confidence,
      `Households Still Available in Cluster` = n_available_in_cluster,
      `Option 1 - Nearby Household` = cand1, `Distance to Option 1 (m)` = cand1_dist,
      `Option 2 - Nearby Household` = cand2, `Distance to Option 2 (m)` = cand2_dist,
      `Option 3 - Nearby Household` = cand3, `Distance to Option 3 (m)` = cand3_dist,
      `CONFIRMED Household ID` = NA_character_,
      `Genuine, Distinct Visit? (Yes/No/Unsure)` = NA_character_,
      `Notes / Explanation` = NA_character_
    )
    writeData(wb, s2, out2, headerStyle = hdr_ref, withFilter = TRUE)
    write_headers(s2, 1, 18:20, hdr_fill)
    dataValidation(wb, s2, cols = 18, rows = 2:(nrow(out2)+1), type = "list", value = paste0("INDIRECT($", int2col(8), "2)"))
    dataValidation(wb, s2, cols = 19, rows = 2:(nrow(out2)+1), type = "list", value = '"Yes,No,Unsure"')
    conf_col <- 10
    likely_rows <- which(out2$`Match Confidence` == "Likely match") + 1
    possible_rows <- which(out2$`Match Confidence` == "Possible match") + 1
    nomatch_rows <- which(grepl("No nearby|No available", out2$`Match Confidence`)) + 1
    if (length(likely_rows)>0) addStyle(wb, s2, createStyle(fgFill="#DCE8DC"), rows=likely_rows, cols=conf_col, stack=TRUE)
    if (length(possible_rows)>0) addStyle(wb, s2, createStyle(fgFill="#F2E4C8"), rows=possible_rows, cols=conf_col, stack=TRUE)
    if (length(nomatch_rows)>0) addStyle(wb, s2, createStyle(fgFill="#F3DAD4"), rows=nomatch_rows, cols=conf_col, stack=TRUE)
    freezePane(wb, s2, firstActiveRow = 2, firstActiveCol = 2)
    setColWidths(wb, s2, cols = 1:20, widths = c(20,16,10,14,14,12,20,18,12,20,10,20,10,20,10,20,10,20,16,26))
  }

  # ---------------- IDP Listing Duplicates ----------------
  # EXTENDED 2026-09-21: pkg$idp_sheet now also includes duplicate_point
  # tracker rows for IDP interviews (previously mislabelled into Non-IDP
  # Duplicates, briefly routed to Confirmed Deletions, now merged into this
  # sheet's own recovery mechanism instead - see full_batch_pipeline.R's
  # idp_dup_raw for the full history). No column changes needed here - both
  # sources already produce the same shape.
  if (n_idp > 0) {
    s3 <- "IDP Listing Duplicates"
    addWorksheet(wb, s3)
    out3 <- pkg$idp_sheet %>% transmute(
      `Interview ID` = uuid, `Enumerator ID` = enum_id, `State` = state_name, `LGA` = lga_name, `Ward` = ward_name,
      `Date of Submission` = as.character(submission_date), `Cluster/Site ID` = idp_cluster_id,
      `Listing Number Recorded` = idp_hh_number_from_listing,
      `Nearest Unclaimed Numbers` = nearby_unclaimed, `Total Numbers Available in Cluster` = n_available,
      `CONFIRMED Listing Number` = NA_character_, `Notes / Explanation` = NA_character_
    )
    writeData(wb, s3, out3, headerStyle = hdr_ref, withFilter = TRUE)
    write_headers(s3, 1, 11:12, hdr_fill)
    dataValidation(wb, s3, cols = 11, rows = 2:(nrow(out3)+1), type = "list",
                    value = paste0('INDIRECT(CONCATENATE("idp_",$', int2col(7), '2))'))
    freezePane(wb, s3, firstActiveRow = 2, firstActiveCol = 2)
    setColWidths(wb, s3, cols = 1:12, widths = c(20,16,10,14,14,12,20,14,20,14,20,26))
  }

  # ---------------- Non-IDP Duplicates (added 2026-09-14) ----------------
  # RE-SCOPED 2026-09-21 (Jack, explicit correction): the point of this
  # sheet is recovery, not adjudication - the partner fills in a corrected
  # (still-available) point ID for every row via the dropdown below, so we
  # keep as much real data as possible rather than deleting it. Two columns
  # from the original 2026-09-14 design REMOVED same date, per Jack: "Other
  # Submission(s) Claiming Same Point" showed a raw uuid partners have no
  # way to cross-reference on their own side (useless to them), and
  # "CONFIRMED Genuine Interview ID" is redundant now that the "CONFIRMED
  # Point ID" dropdown below does the actual resolving - picking a real
  # available point for THIS interview already says everything needed
  # about which submission is genuine and where it now belongs. "Nearest
  # Unclaimed Numbers"/"Total Numbers Available in Cluster"/"CONFIRMED
  # Point ID" (added same day) mirror IDP Listing Duplicates' own recovery
  # mechanism exactly - survey_id carries a sequential HH/R number the same
  # way a listing number does (see full_batch_pipeline.R). Always-present
  # (Missing HH Listings/Other Issues/Confirmed Deletions convention),
  # since this is expected to recur every round, not a rare one-off like
  # GPS/IDP Duplicates.
  s3b <- "Non-IDP Duplicates"
  addWorksheet(wb, s3b)
  if (n_nonidp_dup > 0) {
    # "Claimed By" added 2026-09-21 (Jack, explicit): short, human-readable
    # reason the point isn't available - who genuinely holds it and when,
    # not a uuid the partner can't do anything with (full_batch_pipeline.R's
    # claimed_by_note - names the canonical, not-itself-flagged claimant).
    out3b <- pkg$nonidp_dup_sheet %>% transmute(
      `Interview ID` = uuid, `Enumerator ID` = enum_id, `State` = del_state, `LGA` = del_lga, `Ward` = del_ward,
      `Date of Submission` = as.character(del_submission_date), `Point ID Claimed` = del_non_idp_point_id,
      `Claimed By` = claimed_by_note,
      `Cluster ID` = del_cluster_id,
      `Nearest Unclaimed Numbers` = nearby_unclaimed, `Total Numbers Available in Cluster` = n_available,
      `CONFIRMED Point ID` = NA_character_,
      `Notes / Explanation` = NA_character_
    )
    writeData(wb, s3b, out3b, headerStyle = hdr_ref, withFilter = TRUE)
    write_headers(s3b, 1, c(12, 13), hdr_fill)
    dataValidation(wb, s3b, cols = 12, rows = 2:(nrow(out3b)+1), type = "list", value = paste0("INDIRECT($", int2col(9), "2)"))
    for (r in 1:(nrow(out3b)+1)) { addStyle(wb, s3b, note_style, rows = r, cols = 8, stack = TRUE); addStyle(wb, s3b, note_style, rows = r, cols = 13, stack = TRUE) }
    freezePane(wb, s3b, firstActiveRow = 2, firstActiveCol = 2)
    setColWidths(wb, s3b, cols = 1:13, widths = c(20,16,10,14,14,12,20,32,18,20,20,16,40))
  } else {
    writeData(wb, s3b, tibble::tibble(`Note` = "No non-IDP point duplicates recorded for your team at this time."), headerStyle = hdr_ref)
    setColWidths(wb, s3b, cols = 1, widths = 90)
  }

  # ---------------- Confirmed Deletions ----------------
  s5 <- "Confirmed Deletions"
  addWorksheet(wb, s5)
  if (n_del > 0) {
    # State/LGA/Ward/Cluster ID added 2026-08-31, per Jack -- a bare
    # Interview ID gives no location to check against without cross-
    # referencing another sheet. Date of Submission added 2026-09-14, same
    # request as the other sheets - helps a partner cross-check against
    # their own field team schedules if they want to contest a row.
    # is_appealable split (2026-09-06): pkg$del_sheet is already ordered
    # appealable-first (full_batch_pipeline.R's arrange(desc(is_appealable)))
    # -- duration_under_20/duration_under_30/fcs_zero are validated
    # methodology thresholds, registered as already-confirmed with no appeal
    # step (see issue_tracker.R), so those rows get an FYI note instead of a
    # real Contest This? invitation. The other reasons keep the real
    # dropdown, scoped to just their own row range (not the whole column) so
    # the two presentations can coexist in one sheet.
    out5 <- pkg$del_sheet %>% transmute(
      `Interview ID` = uuid, `Enumerator ID` = enum_id,
      `State` = del_state, `LGA` = del_lga, `Ward` = del_ward, `Date of Submission` = as.character(del_submission_date),
      `Cluster ID` = del_cluster_id,
      `Reason` = reason_text_map[reason],
      `Contest This? (Yes/No)` = if_else(is_appealable, NA_character_, NO_APPEAL_CONTEST_NOTE),
      `If Yes, Explain` = NA_character_
    )
    writeData(wb, s5, out5, headerStyle = hdr_ref, withFilter = TRUE)
    write_headers(s5, 1, 9:10, hdr_fill)
    appealable_rows <- which(pkg$del_sheet$is_appealable) + 1
    if (length(appealable_rows) > 0) {
      dataValidation(wb, s5, cols = 9, rows = appealable_rows, type = "list", value = '"Yes,No"')
    }
    setColWidths(wb, s5, cols = 1:10, widths = c(20,16,10,14,14,12,20,60,14,40))
  } else {
    writeData(wb, s5, tibble::tibble(`Note` = "No confirmed deletions recorded for your team at this time."), headerStyle = hdr_ref)
    setColWidths(wb, s5, cols = 1, widths = 90)
  }

  # ---------------- Cluster Availability ----------------
  s6 <- "Cluster Availability"
  addWorksheet(wb, s6)
  if (nrow(pkg$cluster_avail) > 0) {
    # State/LGA/Ward added 2026-08-31, per Jack.
    out6 <- pkg$cluster_avail %>% transmute(
      `Cluster ID` = cluster_id, `Type` = type, `State` = state, `LGA` = lga, `Ward` = ward,
      `Total Points/Slots` = total_points, `Covered / Claimed` = covered, `Still Available` = available
    )
    writeData(wb, s6, out6, headerStyle = hdr_ref, withFilter = TRUE)
    for (r in 1:(nrow(out6)+1)) { addStyle(wb, s6, note_style, rows = r, cols = 7, stack = TRUE); addStyle(wb, s6, note_style, rows = r, cols = 8, stack = TRUE) }
    setColWidths(wb, s6, cols = 1:8, widths = c(22,10,10,14,14,14,60,60))
  } else {
    writeData(wb, s6, tibble::tibble(`Note` = "No affected clusters requiring an availability breakdown for your team."), headerStyle = hdr_ref)
    setColWidths(wb, s6, cols = 1, widths = 90)
  }

  # ---------------- Oversampled Clusters ----------------
  # Informational only -- Achieved is not capped anywhere in this workbook,
  # so these interviews still count toward the Achieved total above exactly
  # as before. This sheet just shows partners which clusters have already
  # met target so effort can be redirected elsewhere.
  s6b <- "Oversampled Clusters"
  addWorksheet(wb, s6b)
  if (nrow(pkg$oversampled_clusters) > 0) {
    out6b <- pkg$oversampled_clusters %>% transmute(
      `Cluster ID` = cluster_id, `State` = adm1_name, `LGA` = adm2_name, `Ward` = adm3_name,
      `Target Households` = target_households, `Achieved in Cluster` = n_achieved_cluster,
      `Surplus (over target)` = surplus,
      `Note` = "Counted in full, including this surplus, in this workbook's own totals below and in the headline Achieved figure quoted in our covering email - both match the dashboard, which has included oversampled interviews in full since 2026-09-20. No action needed on your side; please prioritise other clusters for any further effort."
    )
    writeData(wb, s6b, out6b, headerStyle = hdr_ref, withFilter = TRUE)
    for (r in 1:(nrow(out6b)+1)) addStyle(wb, s6b, note_style, rows = r, cols = 8, stack = TRUE)
    setColWidths(wb, s6b, cols = 1:8, widths = c(22,14,14,14,14,16,14,60))
  } else {
    writeData(wb, s6b, tibble::tibble(`Note` = "No oversampled clusters recorded for your team at this time."), headerStyle = hdr_ref)
    setColWidths(wb, s6b, cols = 1, widths = 90)
  }

  # ---------------- Enumerator Performance ----------------
  s7 <- "Enumerator Performance"
  addWorksheet(wb, s7)
  out7 <- pkg$scorecard %>% transmute(
    `Enumerator ID` = enum_id, `Interviews Collected` = n_collected, `Achieved` = n_achieved,
    `Confirmed Deletions` = n_confirmed_deletion,
    `...of which under 20min` = n_duration_under_20,
    `Duration 20-30min (under review)` = n_duration_20_30,
    `GPS Flags` = n_gps_flagged, `IDP Duplicate Flags` = n_idp_duplicate,
    `% of Interviews Flagged` = pct_flagged, `Notes` = notes
  )
  writeData(wb, s7, out7, headerStyle = hdr_ref, withFilter = TRUE)
  if (any(out7$Notes != "")) for (r in which(out7$Notes != "")) addStyle(wb, s7, flag_style, rows = r+1, cols = 1, stack = TRUE)
  setColWidths(wb, s7, cols = 1:10, widths = c(18,14,10,12,14,20,10,14,14,80))
  for (r in 1:(nrow(out7)+1)) addStyle(wb, s7, note_style, rows = r, cols = 10, stack = TRUE)

  saveWorkbook(wb, out_path, overwrite = TRUE)
  invisible(out_path)
}
cat("build_partner_workbook() defined\n")
