library(scales)

build_partner_email <- function(pkg, precautionary = FALSE, deadline = "4 September 2026") {
  n_gps <- nrow(pkg$gps_sheet); n_idp <- nrow(pkg$idp_sheet); n_del <- nrow(pkg$del_sheet)
  n_listing_rows <- nrow(pkg$listing_sheet)
  n_listing_interviews <- if (n_listing_rows > 0) sum(pkg$listing_sheet$affected_interviews) else 0
  # ADDED 2026-09-11: Other Issues treated as actionable (needs real
  # partner input), same as GPS/IDP duplicates, per Jack's explicit
  # confirmation - not FYI-only like Confirmed Deletions/Oversampled.
  n_other <- nrow(pkg$other_sheet)
  total_needing_input <- n_gps + n_idp + n_other
  # Headline Achieved uses the CAPPED figure (per cluster target, matching
  # the dashboard) -- per Jack, 2026-08-31: this is an aggregate adjustment
  # only, not a decision about which specific enumerator/interview would be
  # excluded within an oversampled cluster (not yet decided), so the
  # workbook's own Enumerator Performance totals stay uncapped/unchanged and
  # will not sum to this headline figure for partners with any oversampling.
  n_achieved_headline <- pkg$n_achieved_total_capped
  pct_achieved <- if (pkg$target_sample > 0) n_achieved_headline / pkg$target_sample else NA_real_

  # ---- pick one genuine positive, priority order ----
  positive <- if (n_gps == 0 && n_idp == 0) {
    "No GPS-based or IDP listing duplicate issues at all so far - genuinely clean on both fronts."
  } else if (n_gps == 0) {
    "No GPS-based location issues at all so far - one of the more common problems we're seeing elsewhere."
  } else if (n_listing_rows == 0) {
    "Zero missing Household Listing gaps, which several other partners are still working through."
  } else if (!is.na(pct_achieved) && pct_achieved >= 0.7) {
    paste0(percent(pct_achieved, accuracy = 1), " of target already achieved - a strong rate overall.")
  } else {
    NULL
  }

  flag_cats <- pkg$flag_categories
  n_flagged_distinct <- if (length(flag_cats) > 0) length(unique(unlist(lapply(flag_cats, function(x) x$enum_ids)))) else 0
  enum_para <- if (n_flagged_distinct > 0) {
    lines <- sapply(flag_cats, function(cat) {
      ids <- paste(sort(cat$enum_ids), collapse = ", ")
      paste0("- ", cat$label, ": enumerator", if (length(cat$enum_ids) != 1) "s " else " ", ids)
    })
    paste0(
      if (n_flagged_distinct == 1) "One enumerator needs a direct conversation, not just a records check, "
      else paste0(n_flagged_distinct, " enumerators need a direct conversation, not just a records check, "),
      "grouped below by what's driving it (an enumerator appearing in more than one group needs attention on each):\n",
      paste(lines, collapse = "\n"),
      "\n\nExact figures for every enumerator are in the attached workbook's Enumerator Performance sheet."
    )
  } else {
    "Nothing concerning to report on individual enumerators at this stage."
  }

  subject <- if (precautionary) {
    paste0("MSNA N-WEC 2026 — ", toupper(pkg$org), " early data check-in")
  } else {
    paste0("MSNA N-WEC 2026 — ", toupper(pkg$org), " data collection review & action needed by ", deadline)
  }

  overall_para <- if (precautionary) {
    paste0(
      "Your team is only a few days into MSNA N-WEC 2026 data collection, so this is a lighter early check-in rather than a full review - we'd rather flag something now, while it's easy to fix, than let it become a bigger issue later.\n\n",
      "Since starting on ", format(pkg$start_date, "%d %B"), ", your team has collected ", comma(pkg$n_collected_total),
      " interviews, of which ", comma(n_achieved_headline), " currently count toward your Achieved total - ",
      percent(pct_achieved, accuracy=0.1), " of your overall target.",
      if (!is.null(positive)) paste0(" ", positive) else ""
    )
  } else {
    paste0(
      "As part of ongoing monitoring of the MSNA N-WEC 2026 data collection, we've completed a detailed review of your team's submissions to date. This email summarises where things stand, and the attached workbook contains everything we need your team's help with.\n\n",
      "Your team has collected ", comma(pkg$n_collected_total), " interviews so far, of which ", comma(n_achieved_headline),
      " currently count toward your Achieved total - ", percent(pct_achieved, accuracy=0.1), " of your target. Of the remainder, ",
      comma(n_del), " interview", if(n_del!=1) "s" else "", " ", if(n_del!=1) "are" else "is", " confirmed for removal, and a further ",
      comma(total_needing_input), " need your team's input to confirm whether they can be recovered rather than deleted.",
      if (!is.null(positive)) paste0(" ", positive) else ""
    )
  }

  input_para <- if (total_needing_input > 0) {
    parts <- character(0)
    if (n_gps > 0) parts <- c(parts, paste0("- ", comma(n_gps), " interview", if(n_gps!=1) "s" else "", " where the recorded GPS location doesn't match the household point it's credited to. For each, we've suggested up to 3 nearby households nobody else has visited, based on our own sampling frame - we need your team to confirm which one (if any) is correct against your own field records."))
    if (n_idp > 0) parts <- c(parts, paste0("- ", comma(n_idp), " interview", if(n_idp!=1) "s" else "", " where two of your team's submissions claim the same household listing slot in an IDP site, and there's often a plausible unclaimed number sitting right next to it (very likely a data-entry slip, not a real duplicate visit) - same ask, confirm the correct number."))
    paste0(
      paste(parts, collapse = "\n"),
      "\n\nFor both, if your team can't determine the answer, that's a valid response - just say so. What we can't do anything with is silence: rows we don't hear back on stay flagged and unresolved rather than being cleared, so please do respond even if the answer is \"we don't know\" - a genuine resolution either way (confirmed as a real interview, or confirmed as incorrect and removed) is what actually closes these out."
    )
  } else {
    NULL
  }

  # ADDED 2026-09-11: matches input_para's corrected framing above (Jack,
  # 2026-09-11: we only drop from Achieved for an automatic no-appeal
  # deletion, or a resolved-and-confirmed-incorrect item in this workflow -
  # never for silence/non-response, which now just stays pending).
  other_para <- if (n_other > 0) {
    n_date <- sum(pkg$other_sheet$reason == "date_outlier")
    n_crs <- sum(pkg$other_sheet$reason == "crs_unmatched")
    parts <- character(0)
    if (n_date > 0) parts <- c(parts, paste0("- ", comma(n_date), " interview", if(n_date!=1) "s" else "", " with a submission date that looks wrong (almost always a device clock issue) - the interview itself is matched to a real point, we just need your team to confirm the actual date it happened, if known."))
    if (n_crs > 0) parts <- c(parts, paste0("- ", comma(n_crs), " interview", if(n_crs!=1) "s" else "", " that couldn't be matched to any of your team's assigned sample points at all - we need your team's help identifying which household/site this belongs to, if possible."))
    paste0(
      paste(parts, collapse = "\n"),
      "\n\nIf your team can't determine the answer, that's a valid response - just say so. These stay flagged and pending either way; a confirmed correction resolves it properly, and if it turns out not to be a genuine interview, it will be removed at that point."
    )
  } else NULL

  listing_para <- if (n_listing_rows > 0) {
    paste0(
      comma(n_listing_interviews), " interview", if(n_listing_interviews!=1) "s" else "", " across ", comma(n_listing_rows),
      " cluster", if(n_listing_rows!=1) "s" else "", " still have no Household Listing submission on file, so they can't yet be verified against a real sampling frame. ",
      "See the Missing HH Listings sheet for the specific clusters, target/population figures, and affected interview IDs - we need your team to submit (or locate) the listing for these and confirm back to us once done."
    )
  } else NULL

  del_para <- if (n_del > 0) {
    paste0(
      comma(n_del), " interview", if(n_del!=1) "s" else "", " ", if(n_del!=1) "are" else "is",
      " being removed regardless of the above - either the interview was too fast to have been genuinely completed, food-consumption answers were implausible, or consent wasn't given. No action needed unless your team believes a specific case is misclassified, in which case there's a column to flag that."
    )
  } else {
    "No confirmed deletions recorded for your team at this time."
  }

  n_oversampled <- nrow(pkg$oversampled_clusters)
  oversampled_para <- if (n_oversampled > 0) {
    total_surplus <- sum(pkg$oversampled_clusters$surplus)
    paste0(
      comma(n_oversampled), " cluster", if(n_oversampled!=1) "s have" else " has",
      " already received more Achieved interviews than target - ", comma(total_surplus),
      " interview", if(total_surplus!=1) "s" else "", " over, in total, which is why the Achieved total above is lower than your team's own count of good interviews. ",
      "We haven't yet decided which specific interviews within a cluster this would affect if it comes to resampling, so no action is needed from your side for now - this is just visibility ahead of that decision, and so your team can prioritise other clusters for any further effort. See the Oversampled Clusters sheet for the specific clusters."
    )
  } else NULL

  n_dur20 <- pkg$n_duration_under_20_total
  n_dur2030 <- pkg$n_duration_20_30_total
  duration_note <- paste0(
    "A note on the duration cutoff specifically: we're currently treating anything under 20 minutes as confirmed for deletion -- ",
    comma(n_dur20), " of your team's interviews fall under this (already reflected in the Confirmed Deletions above). ",
    "From our testing, we think it is highly implausible to collect accurate data under 30 minutes. We will continue to verify this but until then we are confident in dropping all surveys under 20 minutes, and we remain concerned about interviews in the 20-30 minute range too -- a further ", comma(n_dur2030), " of your team's interviews fall in that band. ",
    "These aren't being deleted at this stage, but we're flagging them now, ahead of time, so it isn't a surprise if some end up affected in a future round, and so your team can look at them now rather than after the fact."
  )

  body <- paste0(
    "Subject: ", subject, "\n\n",
    "Dear ", toupper(pkg$org), " team,\n\n",
    "I hope this finds you well.\n\n",
    overall_para, "\n\n",
    if (!is.null(input_para)) paste0(if(precautionary) "ONE PATTERN WORTH CATCHING NOW\n" else "WHAT NEEDS YOUR INPUT (see attached workbook)\n", input_para, "\n\n") else "",
    if (!is.null(other_para)) paste0("OTHER ISSUES (see attached workbook)\n", other_para, "\n\n") else "",
    if (!is.null(listing_para)) paste0("MISSING HOUSEHOLD LISTINGS\n", listing_para, "\n\n") else "",
    "CONFIRMED DELETIONS (informational)\n", del_para, "\n\n",
    duration_note, "\n\n",
    if (!is.null(oversampled_para)) paste0("OVERSAMPLED CLUSTERS (informational)\n", oversampled_para, "\n\n") else "",
    if (!precautionary) paste0("ENUMERATOR PERFORMANCE\n", enum_para, "\n\n") else paste0("ENUMERATOR PERFORMANCE\n", "A full breakdown by enumerator is included so your team has a baseline to track against as collection continues. ", enum_para, "\n\n"),
    "HOW TO USE THE WORKBOOK\n",
    "Full instructions are in the \"READ ME\" tab of the attached file. Yellow columns are for your team to complete - the \"Confirmed\" columns are dropdowns limited to the households/listing numbers still genuinely available in that cluster, so you shouldn't need to type anything freehand.\n\n",
    "DEADLINE\n",
    "Please return the completed workbook by ", deadline, ". We'd genuinely appreciate this sooner if possible, as the resampling plan is being finalised around this data.\n\n",
    "Please let us know if anything here is unclear, and/or further support is required. Happy to jump on a call if useful - just let us know.\n\n",
    "Best,\nJack\nMSNA N-WEC 2026 Monitoring Team\n"
  )
  body
}

# ---- HTML rendering (2026-08-30, per Jack: wants section headers actually
# bold, not just ALL CAPS) --------------------------------------------------
# A plain .txt draft can't carry real bold formatting through a copy-paste
# into an email client. Renders the same content build_partner_email()
# produces as a small standalone HTML page instead — open it in a browser,
# Select All + Copy, then paste into the email client; the <strong> tags
# survive that clipboard round-trip as real bold in Outlook/Gmail/etc.
# Replaces the .txt draft outright (see run_full_batch.R), not an addition.
html_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x
}

EMAIL_SECTION_HEADERS <- c(
  "WHAT NEEDS YOUR INPUT (see attached workbook)",
  "ONE PATTERN WORTH CATCHING NOW",
  "OTHER ISSUES (see attached workbook)",
  "MISSING HOUSEHOLD LISTINGS",
  "CONFIRMED DELETIONS (informational)",
  "OVERSAMPLED CLUSTERS (informational)",
  "ENUMERATOR PERFORMANCE",
  "HOW TO USE THE WORKBOOK",
  "DEADLINE"
)

build_partner_email_html <- function(pkg, precautionary = FALSE, deadline = "4 September 2026") {
  body_text <- build_partner_email(pkg, precautionary, deadline)
  lines <- strsplit(body_text, "\n", fixed = TRUE)[[1]]
  subject_line <- sub("^Subject: ", "", lines[1])
  rest <- lines[-(1:2)] # drop "Subject: ..." and the blank line after it

  html_lines <- vapply(rest, function(l) {
    esc <- html_escape(l)
    if (l %in% EMAIL_SECTION_HEADERS) paste0("<strong>", esc, "</strong>") else esc
  }, character(1), USE.NAMES = FALSE)

  # blank lines mark paragraph breaks; a lone newline within a paragraph
  # (e.g. between bullet points) becomes <br> instead
  paragraphs <- character(0)
  buf <- character(0)
  for (l in c(html_lines, "")) {
    if (l == "") {
      if (length(buf) > 0) paragraphs <- c(paragraphs, paste(buf, collapse = "<br>\n"))
      buf <- character(0)
    } else {
      buf <- c(buf, l)
    }
  }
  body_html <- paste0("<p>", paragraphs, "</p>", collapse = "\n")

  paste0(
    "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<style>\n",
    "body { font-family: Calibri, Arial, sans-serif; font-size: 11pt; color: #1a1a1a; max-width: 700px; margin: 24px auto; line-height: 1.5; }\n",
    ".subject-box { background: #f2f2f2; border: 1px solid #ccc; padding: 8px 12px; margin-bottom: 12px; }\n",
    ".copy-note { color: #888; font-style: italic; font-size: 9pt; margin-bottom: 20px; }\n",
    "</style></head><body>\n",
    "<div class=\"subject-box\"><strong>Subject:</strong> ", html_escape(subject_line), "</div>\n",
    "<div class=\"copy-note\">(Paste the subject above into your email's subject field. Everything below the line is the body — select from \"Dear\" onward, copy, and paste into your email; the bold headers carry over.)</div>\n",
    "<hr>\n",
    body_html,
    "\n</body></html>\n"
  )
}
cat("build_partner_email() / build_partner_email_html() defined\n")
