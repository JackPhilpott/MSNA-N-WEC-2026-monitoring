# Manager/donor-facing deliverable (2026-09-16, Jack's direct request via
# cross-session flag): which LGAs are most concerning and might need a
# partner reassignment or extra support - a finished document handed
# straight to management/donors, not a dashboard screenshot. Same spirit as
# generate_partner_digest.R (standalone script, its own presentation-quality
# workbook), reusing dashboard_app/global.R's existing computation
# (progress_by_stratum etc.) for the underlying numbers rather than
# recomputing anything.
#
# Run from this file's location (2_monitoring/ project root):
#   source("generate_lga_prioritization_workbook.R")
#   build_lga_prioritization_workbook("reports/lga_prioritization/MSNA_2026_LGA_prioritization_<date>.xlsx")
# Output lives in reports/lga_prioritization/ (2026-09-16, moved out of a
# one-off outputs/ folder per Jack's ask) - same established convention as
# reports/partner_digests/ (MSNA_2026_partner_digest_<date>.xlsx).
#
# ---- Prioritization matrix, confirmed with Jack as two-axis, NOT a blended
# score: Gap size (Still Needed as % of Original Target) x Momentum (days
# since this LGA*pop_type's own last collected sample; stalled threshold =
# 14 days, Jack's own number). Four tiers:
#   Critical    = big gap AND stalled (>=14 days, or never collected)
#   Watch       = big gap AND active (<14 days)
#   Wrapping up = small gap AND stalled
#   On track    = small gap, or already Complete/Dropped
# "Big gap" threshold: Jack left this to judgement ("based on the data's
# natural distribution, or ask directly if not obvious"). Picked 25% still
# needed (BIG_GAP_THRESHOLD below) - a quarter of target still outstanding
# is a defensible, commonly-used "meaningfully behind" bar for a donor
# document, and it's a fixed absolute cutoff rather than a distribution-
# relative one (e.g. median split) deliberately: a relative split would
# always classify roughly half of active LGAs as "big gap" regardless of
# how fielding is actually going, which isn't a stable or meaningful signal
# over time. Flag to Jack if he wants a different number - it's the one
# constant in this file most likely to need adjusting.

suppressPackageStartupMessages({
  library(openxlsx)
  library(dplyr)
  library(readr)
  library(tidyr)
})

.lga_prior_root_wd <- getwd()
setwd("dashboard_app")
suppressPackageStartupMessages(source("global.R"))
setwd(.lga_prior_root_wd)

BIG_GAP_THRESHOLD <- 0.25
STALLED_DAYS <- 14

TIER_COLORS <- c(
  "Critical" = "#C1443C", "Watch" = "#D99A2B",
  "Wrapping up" = "#8FC79A", "On track" = "#1E7B4D"
)

build_lga_prioritization_workbook <- function(file) {
  # ---- MoE columns, joined by Strata ID from the same accessibility
  # workbook extract prep_accessibility_layer.R already mirrors in. Neither
  # is literally named target_moe_pct/projected_moe_pct (checked directly
  # against the actual file - those exact column names don't exist), these
  # are the two real columns that answer the same question.
  # RENAMED 2026-09-16 (Jack, traced to source): both are PROGRESS-DEPENDENT
  # current calculations, not fixed original-design figures - "Original" was
  # the wrong word (implies a fixed spec) and caused real confusion (Riyom
  # IDP legitimately sits above the 10% target mid-fieldwork because only a
  # few of its assigned clusters are done yet, not because anything's wrong).
  # Now moe_current/moe_at_completion, column labels to match.
  # FIX 2026-09-16 (Jack): source values are percentage POINTS (e.g. 9.28
  # meaning 9.28%), not fractions - dividing by 100 here so they're true
  # fractions like every other %-formatted column in this workbook
  # (gap_pct), and can share the same numFmt="0%" treatment below. Storing
  # the raw 9.28 with a "0%" numFmt (the original bug) multiplied it by 100
  # AGAIN for display, showing "928%" instead of "9%".
  # file.path(.lga_prior_root_wd, ...), not INPUT_DIR directly: INPUT_DIR is
  # "../input_data", correct only while cwd is dashboard_app (true during
  # global.R's own sourcing above, no longer true once this function is
  # actually called from 2_monitoring root, this script's own convention).
  moe <- read_csv(file.path(.lga_prior_root_wd, "input_data/accessibility/accessibility_strata_level.csv"), show_col_types = FALSE) %>%
    transmute(
      strata_id = `Strata ID`,
      moe_current = suppressWarnings(as.numeric(`Realized MoE % (full frame, existing)`)) / 100,
      moe_at_completion = suppressWarnings(as.numeric(`Realized MoE % (updated area, at full completion of currently-assigned PRIMARY slots)`)) / 100
    )

  # ---- date of last COLLECTED (not just achieved) sample, per stratum -
  # same grain as progress_by_stratum, so this joins cleanly onto it below.
  last_collected <- submissions_raw %>%
    filter(is_collected(.), !is.na(matched_strata_id)) %>%
    group_by(matched_strata_id) %>%
    summarise(last_collected_date = max(submission_date, na.rm = TRUE), .groups = "drop")

  df <- progress_by_stratum %>%
    left_join(moe, by = "strata_id") %>%
    left_join(last_collected, by = c("strata_id" = "matched_strata_id")) %>%
    left_join(accessibility_lga_summary, by = "adm2_pcode") %>%
    mutate(
      partner_label = vapply(adm2_pcode, partner_coverage_label, character(1)),
      still_needed = pmax(target_sample - achieved_n, 0),
      gap_pct = ifelse(target_sample > 0, still_needed / target_sample, NA_real_),
      # ADDED 2026-09-16 (Jack, direct): same "show both target bases" ask as
      # the Status split just below - now that Original and Revised targets
      # can each carry their own Status, they should each carry their own %
      # still needed too, not just the Original one Priority already uses.
      still_needed_revised = pmax(target_sample_current - achieved_n, 0),
      gap_pct_revised = ifelse(target_sample_current > 0, still_needed_revised / target_sample_current, NA_real_),
      days_since_last = as.numeric(today_for_pace - last_collected_date),
      # "stalled" also catches genuinely never-collected strata (NA days) -
      # those are exactly as concerning as a 14+ day gap, not less.
      stalled = is.na(days_since_last) | days_since_last >= STALLED_DAYS,
      # FIX 2026-09-16 (Jack): split into a clean 3-value category and a
      # positively-framed detail ("N of M accessible", not "of M
      # inaccessible") - checked the actual distinct values first, only 3
      # patterns exist (Fully accessible/Fully inaccessible/partial), no
      # other case to handle.
      n_ward_portions_accessible = n_ward_portions - n_ward_portions_inaccessible,
      accessibility_category = case_when(
        is.na(n_ward_portions) ~ "n/a",
        n_ward_portions_inaccessible == 0 ~ "Fully accessible",
        n_ward_portions_inaccessible >= n_ward_portions ~ "Fully inaccessible",
        TRUE ~ "Partially accessible"
      ),
      accessibility_detail = ifelse(
        is.na(n_ward_portions), "n/a",
        paste0(n_ward_portions_accessible, " of ", n_ward_portions, " ward portions accessible")
      ),
      tier = case_when(
        status %in% c("Complete", "Dropped") ~ "On track",
        is.na(gap_pct) ~ "On track",
        gap_pct >= BIG_GAP_THRESHOLD & stalled ~ "Critical",
        gap_pct >= BIG_GAP_THRESHOLD & !stalled ~ "Watch",
        gap_pct < BIG_GAP_THRESHOLD & stalled ~ "Wrapping up",
        TRUE ~ "On track"
      ),
      # ADDED 2026-09-16 (Jack, via cross-session flag): a second Status
      # column, same Complete/In progress/Not started/Dropped logic as
      # `status` (compute_progress_by_stratum(), global.R) but against
      # target_sample_current (Revised/representativity) instead of
      # target_sample (Original) - Jack's reasoning: Revised is usually <=
      # Original, so an LGA can be genuinely done against Revised while still
      # reading "In progress" against Original, and that's the more
      # operationally meaningful "are we actually done here" signal, worth
      # showing side by side rather than picking one. Priority/tier above is
      # UNCHANGED, still keyed off Original only, per Jack's explicit
      # instruction - this is purely an added visibility column. Mirrors
      # compute_progress_by_stratum()'s own pre-Decision-A status formula
      # exactly (same Dropped carve-out, same thresholds, just the other
      # target basis) rather than inventing new logic.
      status_revised = case_when(
        coverage_status == "excluded" | target_not_computable ~ "Dropped",
        target_sample_current <= 0 | achieved_n >= target_sample_current ~ "Complete",
        achieved_n > 0 ~ "In progress",
        TRUE ~ "Not started"
      )
    ) %>%
    arrange(factor(tier, levels = c("Critical", "Watch", "Wrapping up", "On track")), desc(gap_pct))

  # FIX 2026-09-16 (Jack): a never-collected row must show "No samples
  # collected yet" as literal text, not a blank cell or a blank-turned-0 -
  # these become text columns rather than Date/numeric so that string can
  # sit alongside real formatted values in the same column.
  no_samples_text <- "No samples collected yet"
  date_col <- ifelse(is.na(df$last_collected_date), no_samples_text, format(df$last_collected_date, "%d %b %Y"))
  days_col <- ifelse(is.na(df$days_since_last), no_samples_text, as.character(df$days_since_last))

  export_df <- df %>%
    transmute(
      Region = region, State = adm1_name, LGA = adm2_name,
      `Pop. group` = unname(POP_TYPE_LABELS[pop_type]),
      `Partner(s) covering` = partner_label,
      `Original Target` = target_sample,
      `Revised Target (representativity)` = round(target_sample_current),
      Collected = collected_n, Achieved = achieved_n,
      `Still Needed` = still_needed,
      `Confirmed Deleted` = confirmed_deletion_n,
      `Oversampling Surplus` = oversampling_surplus_n,
      `Realized MoE % (current)` = moe_current,
      `Realized MoE % (at completion of assigned clusters)` = moe_at_completion,
      `Date of last collected sample` = date_col,
      `Days since last collection` = days_col,
      `Accessibility status` = accessibility_category,
      `Accessibility detail` = accessibility_detail,
      `Status (Original Target)` = status,
      `Status (Revised Target)` = status_revised,
      `% of target still needed (Original Target)` = gap_pct,
      `% of target still needed (Revised Target)` = gap_pct_revised,
      Priority = factor(tier, levels = c("Critical", "Watch", "Wrapping up", "On track"))
    )

  wb <- createWorkbook()

  # ---- README ---------------------------------------------------------
  sheetR <- "Read me"
  addWorksheet(wb, sheetR)
  r <- 1
  wt <- function(text, size = 16, bold = TRUE, colour = "#1B2A4A") {
    writeData(wb, sheetR, text, startRow = r, colNames = FALSE)
    addStyle(wb, sheetR, createStyle(fontSize = size, textDecoration = if (bold) "bold" else NULL, fontColour = colour), rows = r, cols = 1)
    r <<- r + 1
  }
  wp <- function(text, height = 60) {
    writeData(wb, sheetR, text, startRow = r, colNames = FALSE)
    addStyle(wb, sheetR, createStyle(wrapText = TRUE), rows = r, cols = 1:6, gridExpand = TRUE, stack = TRUE)
    mergeCells(wb, sheetR, cols = 1:6, rows = r)
    setRowHeights(wb, sheetR, rows = r, heights = height)
    r <<- r + 1
  }
  wt("MSNA N-WEC 2026 — LGA Prioritization")
  wt(paste0("Generated ", format(Sys.time(), "%d %b %Y %H:%M"), " — for management/donor review: which LGAs are most concerning and whether a partner reassignment is warranted."), size = 11, bold = FALSE, colour = "black")
  r <- r + 1
  wt("How to read the Priority column", size = 13)
  wp(paste(
    "Every row is one LGA x population group. Priority is a TWO-AXIS matrix, not a single blended score:",
    "GAP SIZE = Still Needed as a share of Original Target (>= 25% counts as a \"big gap\" here —",
    "a fixed, adjustable threshold, not a per-run relative split).",
    "MOMENTUM = days since this row's own last collected sample (14+ days, or never collected, counts as \"stalled\")."
  ), height = 70)
  wp(paste(
    "CRITICAL = big gap AND stalled — the reassignment/extra-support candidates.",
    "WATCH = big gap but still active — needs resourcing or time, not necessarily a new partner.",
    "WRAPPING UP = small gap but stalled — just needs a nudge to close out.",
    "ON TRACK = small gap and/or already Complete."
  ), height = 70)
  wt("A note on the numbers", size = 13)
  wp(paste(
    "Original Target = the frozen design-time figure; Still Needed and the Priority matrix are both",
    "measured against THIS, matching partner workbooks (Decision A, 2026-09-16). Revised Target",
    "(representativity) is shown alongside as reference — 1_sampling's live required-minimum calculation,",
    "shown, not used for prioritization. Achieved excludes only SETTLED (confirmed/contested) tracker",
    "deletions and includes oversampled interviews in full (policy changed 2026-09-20) — same definition",
    "as the live dashboard."
  ), height = 70)
  wp(paste(
    "Realized MoE % (current) / (at completion of assigned clusters) come from 1_sampling's own",
    "representativity workbook — both are PROGRESS-DEPENDENT figures, not a fixed original design spec,",
    "so a value above the 10% design target mid-fieldwork isn't necessarily a problem — it can simply mean",
    "not every already-assigned cluster is done yet. Check the dashboard/workbook's own Feasibility figure",
    "before reading a high MoE % here as cause for concern on its own.",
    "Accessibility status/detail summarise ward-portion reporting for that LGA (not pop-type specific —",
    "both pop-type rows for one LGA show the same figure); detail is framed as the accessible share,",
    "not the inaccessible one."
  ), height = 80)
  setColWidths(wb, sheetR, cols = 1:6, widths = c(24, 24, 24, 24, 24, 24))

  # ---- main sheet -------------------------------------------------------
  sheetP <- "LGA Prioritization"
  addWorksheet(wb, sheetP)
  writeDataTable(wb, sheetP, export_df, tableStyle = "TableStyleLight1")
  addStyle(wb, sheetP, createStyle(fgFill = "#1F3864", fontColour = "white", textDecoration = "bold", wrapText = TRUE, valign = "center"), rows = 1, cols = 1:ncol(export_df), gridExpand = TRUE, stack = TRUE)
  n_r <- nrow(export_df)
  # FIX 2026-09-16 (Jack, checked the actual number_format directly): "0%"
  # (zero decimals) rounds Riyom IDP's 0.1303 to "13%", losing the exact
  # decimal precision his own message's examples ("9.28%"/"13.03%") were
  # pointing at. MoE columns get "0.00%" specifically - "% of target still
  # needed" stays whole-percent, that one was never in question.
  moe_pct_cols <- which(names(export_df) %in% c("Realized MoE % (current)", "Realized MoE % (at completion of assigned clusters)"))
  addStyle(wb, sheetP, createStyle(numFmt = "0.00%"), rows = 2:(n_r + 1), cols = moe_pct_cols, gridExpand = TRUE, stack = TRUE)
  gap_pct_cols <- which(names(export_df) %in% c("% of target still needed (Original Target)", "% of target still needed (Revised Target)"))
  addStyle(wb, sheetP, createStyle(numFmt = "0%"), rows = 2:(n_r + 1), cols = gap_pct_cols, gridExpand = TRUE, stack = TRUE)
  priority_col <- which(names(export_df) == "Priority")
  addStyle(wb, sheetP, createStyle(fgFill = "#FFFFFF"), rows = 2:(n_r + 1), cols = priority_col, gridExpand = TRUE, stack = TRUE)
  for (tier in names(TIER_COLORS)) {
    rows <- which(as.character(export_df$Priority) == tier) + 1
    if (length(rows) > 0) {
      addStyle(wb, sheetP, createStyle(fgFill = TIER_COLORS[[tier]], fontColour = if (tier %in% c("Critical", "On track")) "white" else "black", textDecoration = "bold"), rows = rows, cols = priority_col, gridExpand = TRUE, stack = TRUE)
    }
  }
  setColWidths(wb, sheetP, cols = 1:ncol(export_df), widths = "auto")
  freezePane(wb, sheetP, firstRow = TRUE, firstActiveCol = 5)

  # ---- summary counts sheet ----------------------------------------------
  sheetS <- "Summary"
  addWorksheet(wb, sheetS)
  tier_counts <- export_df %>% count(Priority, name = "LGA x pop-group rows") %>% arrange(factor(Priority, levels = c("Critical", "Watch", "Wrapping up", "On track")))
  writeDataTable(wb, sheetS, tier_counts, tableStyle = "TableStyleLight1")
  addStyle(wb, sheetS, createStyle(fgFill = "#1F3864", fontColour = "white", textDecoration = "bold"), rows = 1, cols = 1:2, gridExpand = TRUE, stack = TRUE)
  setColWidths(wb, sheetS, cols = 1:2, widths = c(20, 20))

  dir.create(dirname(file), showWarnings = FALSE, recursive = TRUE)
  saveWorkbook(wb, file, overwrite = TRUE)
  cat("Wrote", file, "-", nrow(export_df), "rows,", sum(export_df$Priority == "Critical"), "Critical,", sum(export_df$Priority == "Watch"), "Watch,",
      sum(export_df$Priority == "Wrapping up"), "Wrapping up,", sum(export_df$Priority == "On track"), "On track.\n")
  invisible(export_df)
}

if (sys.nframe() == 0) {
  build_lga_prioritization_workbook(paste0("reports/lga_prioritization/MSNA_2026_LGA_prioritization_", Sys.Date(), ".xlsx"))
}
