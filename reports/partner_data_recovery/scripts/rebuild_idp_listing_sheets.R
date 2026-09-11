# ==============================================================================
# In-place rebuild of the "IDP Listing Duplicates" sheet (+ its hidden
# "Lookup_IDP" dropdown-source sheet) inside every partner's ORIGINAL
# 2026-08-30 data recovery workbook, using the real per-cluster listing
# pool from real_hh_listing.R (see that file's own header for the
# methodology) instead of the original buggy target_households-capped
# ceiling. Built 2026-09-03 per Jack: "here are the HH listing numbers...
# use this to fill and update all workbooks accordingly."
#
# Scope: every partner whose original workbook has an "IDP Listing
# Duplicates" sheet at all (17 of 19 - FHI360/LHI have zero submissions,
# no such sheet exists for them). Flagged-duplicates-only mode throughout
# (dup_n > 1) - i.e. this preserves each partner's ORIGINAL sheet's scope
# (same rows they already have), just with the corrected ceiling/dropdown
# and the "Nearest Unclaimed Numbers" column dropped, per Jack's earlier
# rule.
#
# ZOA is the one exception (FULL_MODE_ORGS below, 2026-09-03): per Jack,
# ZOA is trusted to hold a genuinely complete, clean listing of every
# household their enumerators recorded, so rather than a separate
# standalone supplement file (the first version of this, since superseded
# - Jack: "I just wanted to have this extended sheet replace the existing
# IDP HH duplicates sheet within their main workbook... same as
# everyone's but they just get an extended sheet for this one sheet"),
# ZOA's OWN "IDP Listing Duplicates" sheet - same name, same position, one
# workbook, no separate file - simply contains every real IDP interview
# for their clusters (not just flagged ones) with an added "Is Duplicate
# (Yes/No)" column showing our own detection, letting them reconcile from
# scratch against their own records.
#
# In-place via openxlsx::loadWorkbook() (not openpyxl/Python) deliberately
# - these files were originally BUILT by R's openxlsx (build_workbook_fn.R),
# so openxlsx can read its own output with no corruption workaround needed
# (the xl/drawings/drawingN.xml issue xlsx_repair.py exists for is
# specifically an openpyxl/R-openxlsx incompatibility on the READING side,
# not a problem for openxlsx itself). Every other sheet in each workbook is
# left completely untouched - only "IDP Listing Duplicates" and
# "Lookup_IDP" are removed and rebuilt.
#
# Run from the 2_monitoring project root:
#   Rscript reports/partner_data_recovery/scripts/rebuild_idp_listing_sheets.R
#
# BUG FOUND AND FIXED 2026-09-03 (a rerun on the same day, while assessing
# IMC's returned workbook): `claimed[[1]] %||% integer(0)` below was wrong
# - inside rowwise(), a list-column referenced by name is ALREADY the
# unwrapped per-row vector, so `claimed[[1]]` took only the FIRST already-
# claimed number in the cluster, not the whole claimed set (confirmed via
# an isolated dplyr test, and against IMC's own saved file: idp_NG008007_4
# showed 95 numbers "available" when the correct figure, excluding all 41
# nationally-claimed numbers rather than just one, is 55). This silently
# inflated "Total Numbers Available"/the CONFIRMED dropdown for every
# multi-claim cluster in all 17 workbooks from the run below - including
# ZOA and DRC, both already sent to partners before this was caught. Fixed
# by using the already-unwrapped `claimed` directly; this file was then
# restored from ../_backup_before_real_listing_fix_2026-09-03/ and rerun
# in full before this note was added.
# ==============================================================================
suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(readr); library(stringr); library(openxlsx)
})

MONITORING_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring"
setwd(MONITORING_DIR)
CLEANING_OUTPUT_DIR <- "cleaning/MSNA_Data_Cleaning/output"
OUTPUTS_DIR <- "reports/partner_data_recovery/outputs"

# ---- 1. real submissions (same repair/dup_key logic as build_idp_listing_duplicates_data.R) ----
anon_files <- list.files(file.path(CLEANING_OUTPUT_DIR, "anonymised_data"), pattern = "\\.xlsx$", full.names = TRUE)
stopifnot(length(anon_files) > 0)
anon_dates <- as.Date(str_extract(basename(anon_files), "\\d{4}-\\d{2}-\\d{2}"))
same_day_candidates <- anon_files[anon_dates == max(anon_dates)]
latest_file <- same_day_candidates[which.max(file.info(same_day_candidates)$mtime)]
cat("Using anonymised export:", basename(latest_file), "\n")
main <- read_excel(latest_file, sheet = "main", guess_max = 5000)

idp_cols <- grep("^idp_cluster_NG\\d+$", names(main), value = TRUE)
first_non_na <- function(df) apply(df, 1, function(r) { r <- r[!is.na(r)]; if (length(r)) r[1] else NA_character_ })
main <- main %>%
  mutate(
    rebuilt_idp = first_non_na(across(all_of(idp_cols))),
    idp_cluster_id_repaired = coalesce(as.character(idp_cluster_id), rebuilt_idp)
  ) %>%
  mutate(dup_key = if_else(
    sample_pop_type_filter == "idp" & !is.na(idp_hh_number_from_listing),
    paste0(idp_cluster_id_repaired, "|listing_", idp_hh_number_from_listing),
    NA_character_
  )) %>%
  group_by(dup_key) %>%
  mutate(dup_n = if_else(is.na(dup_key), 1L, dplyr::n())) %>%
  ungroup()

# ---- 2. admin lookups + real listing pools (same sources as build_idp_listing_duplicates_data.R) ----
household_frame <- read_csv(
  "input_data/sampling_frame/NGA_MSNA_2026_stage2_sampling_frame_v5_FULL.csv",
  show_col_types = FALSE, col_types = cols(.default = "c")
)
adm1_lookup <- household_frame %>% distinct(adm1_pcode, adm1_name)
adm2_lookup <- household_frame %>% distinct(adm2_pcode, adm2_name)
admin3_lookup <- read_csv("input_data/MSNA_2026_admin3.csv", show_col_types = FALSE) %>% distinct(name, .keep_all = TRUE)
frame_full <- household_frame %>%
  distinct(cluster_id, .keep_all = TRUE) %>%
  transmute(cluster_id, target_households = as.integer(target_households))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
source("reports/partner_data_recovery/scripts/real_hh_listing.R")
avail_pools <- compute_real_avail_pools()

claimed_by_cluster <- main %>%
  filter(!is.na(idp_hh_number_from_listing)) %>%
  group_by(idp_cluster_id_repaired) %>%
  summarise(claimed = list(unique(idp_hh_number_from_listing)), .groups = "drop")

ceilings <- frame_full %>%
  left_join(claimed_by_cluster, by = c("cluster_id" = "idp_cluster_id_repaired")) %>%
  rowwise() %>%
  mutate(avail_list = list(resolve_avail_list(cluster_id, target_households, claimed %||% integer(0), avail_pools))) %>%
  ungroup() %>%
  select(cluster_id, avail_list)

# ---- 3. per-org sheet data: flagged-duplicates-only for everyone except
# FULL_MODE_ORGS, who get every real IDP row for their own clusters ----
FULL_MODE_ORGS <- c("zoa")

base_idp_rows <- function(dup_filter) {
  main %>%
    filter(sample_pop_type_filter == "idp", !is.na(idp_hh_number_from_listing)) %>%
    { if (dup_filter) filter(., dup_n > 1) else . } %>%
    left_join(adm1_lookup, by = c("admin1" = "adm1_pcode")) %>%
    left_join(adm2_lookup, by = c("admin2" = "adm2_pcode")) %>%
    left_join(admin3_lookup %>% select(name, ward_label = label), by = c("admin3" = "name")) %>%
    left_join(ceilings, by = c("idp_cluster_id_repaired" = "cluster_id")) %>%
    transmute(
      org_id = tolower(org_id),
      `Interview ID` = uuid, `Enumerator ID` = enum_id, State = adm1_name, LGA = adm2_name, Ward = ward_label,
      `Date of Submission` = as.character(as.Date(start)), `Cluster/Site ID` = idp_cluster_id_repaired,
      `Listing Number Recorded` = idp_hh_number_from_listing,
      avail_list,
      `Total Numbers Available in Cluster` = lengths(avail_list),
      `Is Duplicate (Yes/No)` = if_else(dup_n > 1, "Yes", "No")
    ) %>%
    arrange(`Cluster/Site ID`, `Listing Number Recorded`, `Date of Submission`)
}

all_flagged <- base_idp_rows(dup_filter = TRUE) %>% filter(!org_id %in% FULL_MODE_ORGS)
all_full <- base_idp_rows(dup_filter = FALSE) %>% filter(org_id %in% FULL_MODE_ORGS)

orgs_needing_rebuild <- sort(unique(c(all_flagged$org_id, all_full$org_id)))
cat("Orgs with an IDP Listing Duplicates sheet to rebuild:", paste(orgs_needing_rebuild, collapse = ", "),
    "\n(full-reconciliation mode: ", paste(intersect(orgs_needing_rebuild, FULL_MODE_ORGS), collapse = ", "), ")\n\n")

# ---- 4. in-place sheet rebuild per partner workbook ----
hdr_ref <- createStyle(fgFill = "#DDE6E1", textDecoration = "bold", wrapText = TRUE, border = "TopBottomLeftRight")
hdr_fill <- createStyle(fgFill = "#FCEFD0", textDecoration = "bold", wrapText = TRUE, border = "TopBottomLeftRight")
write_headers <- function(wb, sheet, row, cols, style) for (i in seq_along(cols)) addStyle(wb, sheet, style, rows = row, cols = cols[i])
int2col <- function(i) LETTERS[i]  # matches build_workbook_fn.R's own helper for single-letter columns (<=26 here)

results <- list()
for (org in orgs_needing_rebuild) {
  org_upper <- toupper(org)
  wb_path <- file.path(OUTPUTS_DIR, org_upper, paste0(org_upper, "_data_recovery_workbook_2026-08-30.xlsx"))
  if (!file.exists(wb_path)) {
    cat("SKIP", org_upper, "- workbook not found at", wb_path, "\n")
    next
  }

  full_mode <- org %in% FULL_MODE_ORGS
  org_rows <- if (full_mode) all_full %>% filter(org_id == org) else all_flagged %>% filter(org_id == org)

  out <- if (full_mode) {
    org_rows %>% transmute(
      `Interview ID`, `Enumerator ID`, State, LGA, Ward, `Date of Submission`, `Cluster/Site ID`,
      `Listing Number Recorded`, `Total Numbers Available in Cluster`, `Is Duplicate (Yes/No)`,
      `CONFIRMED Listing Number` = NA_character_, `Notes / Explanation` = NA_character_
    )
  } else {
    org_rows %>% transmute(
      `Interview ID`, `Enumerator ID`, State, LGA, Ward, `Date of Submission`, `Cluster/Site ID`,
      `Listing Number Recorded`, `Total Numbers Available in Cluster`,
      `CONFIRMED Listing Number` = NA_character_, `Notes / Explanation` = NA_character_
    )
  }
  confirmed_col <- ncol(out) - 1  # 10 standard, 11 full-mode (Is Duplicate inserted before it)
  notes_col <- ncol(out)

  wb <- loadWorkbook(wb_path)
  if ("IDP Listing Duplicates" %in% names(wb)) removeWorksheet(wb, "IDP Listing Duplicates")
  if ("Lookup_IDP" %in% names(wb)) removeWorksheet(wb, "Lookup_IDP")

  s3 <- "IDP Listing Duplicates"
  addWorksheet(wb, s3)
  writeData(wb, s3, out, headerStyle = hdr_ref, withFilter = TRUE)
  write_headers(wb, s3, 1, confirmed_col:notes_col, hdr_fill)
  dataValidation(wb, s3, cols = confirmed_col, rows = 2:(nrow(out) + 1), type = "list",
                  value = paste0('INDIRECT(CONCATENATE("idp_",$', int2col(7), '2))'))
  freezePane(wb, s3, firstActiveRow = 2, firstActiveCol = 2)
  base_widths <- c(20, 16, 10, 14, 14, 12, 20, 14, 20)
  widths <- if (full_mode) c(base_widths, 14, 20, 26) else c(base_widths, 20, 26)
  setColWidths(wb, s3, cols = 1:notes_col, widths = widths)

  if (full_mode) {
    # A different scope than every other partner's sheet - flag it clearly
    # on their own READ ME so it isn't mistaken for the standard flagged-
    # only format everyone else gets (per Jack, 2026-09-03).
    readme_note <- paste0(
      "A NOTE ON YOUR IDP LISTING DUPLICATES SHEET: unlike other partners' version of this sheet, ",
      "yours includes EVERY interview across your IDP clusters (not just the ones we flagged as ",
      "colliding on the same listing number), with an added \"Is Duplicate (Yes/No)\" column showing ",
      "our own detection - since your team holds a complete, clean listing, it's more useful for you ",
      "to reconcile against the full picture than our partial flagged subset. Treat the Yes/No column ",
      "as a flag to check, not a verdict; your own listing is the source of truth."
    )
    readme_ws <- "READ ME"
    readme_data <- readWorkbook(wb_path, sheet = readme_ws, colNames = FALSE)
    already_present <- any(vapply(readme_data[[1]], function(x) !is.na(x) && identical(x, readme_note), logical(1)))
    if (!already_present) {
      next_row <- nrow(readme_data) + 2
      writeData(wb, readme_ws, readme_note, startCol = 1, startRow = next_row)
      addStyle(wb, readme_ws, createStyle(wrapText = TRUE, valign = "top"), rows = next_row, cols = 1, stack = TRUE)
    }
  }

  addWorksheet(wb, "Lookup_IDP", visible = FALSE)
  clusters_this_org <- unique(org_rows$`Cluster/Site ID`)
  for (i in seq_along(clusters_this_org)) {
    cid <- clusters_this_org[i]
    vals <- org_rows$avail_list[org_rows$`Cluster/Site ID` == cid][[1]]
    vals_chr <- as.character(vals); if (length(vals_chr) == 0) vals_chr <- "(none available)"
    writeData(wb, "Lookup_IDP", vals_chr, startCol = i, startRow = 1, colNames = FALSE)
    # overwrite = TRUE: removeWorksheet() above doesn't reliably clear a
    # workbook-level defined name that pointed at the old Lookup_IDP sheet
    # (confirmed hitting this on FACT specifically - its workbook was
    # touched by an unexplained process on 2026-09-02, see README - left a
    # stale 'idp_idp_NG002001_11' defined name behind even after its
    # sheet was removed). Safe either way: a fresh file has nothing to
    # overwrite, this only matters when a stale one is lurking.
    createNamedRegion(wb, sheet = "Lookup_IDP", name = paste0("idp_", cid), cols = i, rows = 1:length(vals_chr), overwrite = TRUE)
  }

  # Restore the original tab order (per Jack, 2026-09-03): removeWorksheet()
  # + addWorksheet() appends both sheets at the end of the PHYSICAL sheet
  # list, but openxlsx keeps a separate worksheetOrder() controlling
  # DISPLAY/tab order - setting it explicitly is what actually fixes what
  # a partner sees, since names(wb) alone reflects storage order, not tab
  # order. match() against this target list gives, for each desired-order
  # sheet name, its current physical position - exactly what
  # worksheetOrder<- expects. Filtered to sheets that actually exist in
  # THIS workbook, since not every partner has every sheet (e.g. a
  # partner with zero GPS-duplicate rows has no "GPS Duplicates & Distant
  # Pts"/"Lookup_NonIDP" at all).
  target_order_names <- c(
    "READ ME", "Lookup_NonIDP", "Lookup_IDP", "GPS Duplicates & Distant Pts",
    "IDP Listing Duplicates", "Missing HH Listings", "Confirmed Deletions",
    "Cluster Availability", "Oversampled Clusters", "Enumerator Performance"
  )
  target_order_names <- target_order_names[target_order_names %in% names(wb)]
  worksheetOrder(wb) <- match(target_order_names, names(wb))

  saveWorkbook(wb, wb_path, overwrite = TRUE)

  # openxlsx round-trip bug (found 2026-09-03): loadWorkbook() ->
  # saveWorkbook() fails to re-escape the literal "&" already in the
  # EXISTING "GPS Duplicates & Distant Pts" sheet name, producing invalid
  # XML that fails to open at all (in Excel AND openpyxl) - NOT the same
  # as xlsx_repair.py's dangling-drawing-reference issue, which is read-
  # time-only and doesn't touch the file. This has to be fixed on disk,
  # since a partner opens this file directly. See fix_openxlsx_
  # roundtrip.py's own header for detail.
  fix_result <- system2("python", c(shQuote("reports/partner_data_recovery/scripts/fix_openxlsx_roundtrip.py"), shQuote(wb_path)), stdout = TRUE, stderr = TRUE)
  cat(paste(fix_result, collapse = "\n"), "\n")

  cat("REBUILT", org_upper, "-", nrow(out), "row(s) across", length(clusters_this_org), "cluster(s)\n")
  results[[org]] <- nrow(out)
}

cat("\n=== DONE. Rebuilt", length(results), "workbook(s). ===\n")
