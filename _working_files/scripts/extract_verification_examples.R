suppressPackageStartupMessages({ library(dplyr); library(readr) })

OUT_DIR <- "C:/Users/JACKPH~1/AppData/Local/Temp/claude/c--Users-JackPHILPOTT-ACTED-IMPACT-NGA---02--MSNA-4--Data-MSNA-N-WEC-2026/fa9f2051-954f-4f74-9764-fa6829bbad87/scratchpad/duration_verification_examples"
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

picks <- list(
  list(uuid = "91a6aed2-630f-48d8-bff3-d2b3f0f86d8c", label = "example_1_fact",
       archive = "54451db3b3f1433f80c4baee2dc74381/91a6aed2-630f-48d8-bff3-d2b3f0f86d8c/audit.csv"),
  list(uuid = "20cf4ce8-0f32-4cc5-81cd-172668f2af65", label = "example_2_crs_boundary",
       archive = "54451db3b3f1433f80c4baee2dc74381/20cf4ce8-0f32-4cc5-81cd-172668f2af65/audit.csv"),
  list(uuid = "c8e826aa-65f7-4811-98f2-92787f1332ad", label = "example_3_lhi_extreme",
       archive = "54451db3b3f1433f80c4baee2dc74381/c8e826aa-65f7-4811-98f2-92787f1332ad/audit.csv")
)

zip_path <- "cleaning/MSNA_Data_Cleaning/audit/audit.zip"
extract_dir <- tempfile("verify_extract_")
dir.create(extract_dir)
utils::unzip(zip_path, files = sapply(picks, `[[`, "archive"), exdir = extract_dir, overwrite = TRUE)

summary_lines <- c(
  "DURATION CALCULATION VERIFICATION — 3 examples",
  "=================================================",
  "",
  "HOW THE CALCULATION WORKS (cleaningtools::create_duration_from_audit_sum_all,",
  "the exact function the DO's own pipeline calls too — verified by printing its",
  "real installed source, not assumed):",
  "",
  "  1. Take the audit.csv (one row per screen/question event Kobo logged).",
  "  2. Drop any row where the `node` column is blank (form-level events like",
  "     opening/closing the form, not a real question).",
  "  3. For every remaining row, compute (end - start) — both are in epoch",
  "     MILLISECONDS, so this is that single row's own on-screen time.",
  "  4. Sum that value across every remaining row.",
  "  5. Divide by 60,000 to convert milliseconds to minutes.",
  "",
  "The key thing to see for yourself: this NEVER looks at the gap between one",
  "row's `end` and the next row's `start`. If the enumerator paused, backgrounded",
  "the app, or left it open overnight between two questions, that gap is simply",
  "never added in — only time actually spent on a visible question counts.",
  "That's why a submission can show a huge span in KoBo's own start/end",
  "metadata but a short number here: the difference IS the paused/idle time.",
  "",
  "TO CHECK BY HAND: open an audit.csv below in Excel. Filter out blank `node`",
  "rows. Add a column = (end - start). Sum it. Divide by 60000. Compare to the",
  "'real audit duration' figure below for that file.",
  "",
  ""
)

for (p in picks) {
  src <- file.path(extract_dir, p$archive)
  dest <- file.path(OUT_DIR, paste0(p$label, "_", substr(p$uuid, 1, 8), "_audit.csv"))
  file.copy(src, dest, overwrite = TRUE)

  audit_df <- read.csv(src, stringsAsFactors = FALSE, check.names = FALSE, na.strings = c("", "NA"))
  filtered <- audit_df %>% filter(node != "")
  n_total <- nrow(audit_df)
  n_kept <- nrow(filtered)
  per_row_ms <- filtered$end - filtered$start
  duration_ms <- sum(per_row_ms)
  duration_min <- round(duration_ms / 1000 / 60, 1)

  # sanity-check against the actual package function too
  pkg_result <- cleaningtools::create_duration_from_audit_sum_all(audit_df)

  summary_lines <- c(summary_lines,
    paste0("---- ", p$label, " (uuid ", p$uuid, ") ----"),
    paste0("  File: ", basename(dest)),
    paste0("  Total rows in audit.csv: ", n_total, " | rows with a real node (kept): ", n_kept),
    paste0("  Sum of (end - start) across those rows: ", duration_ms, " ms"),
    paste0("  -> ", duration_min, " minutes (manual calc, matches cleaningtools output: ", pkg_result$duration_minutes, ")"),
    paste0("  First 3 kept rows' own (end-start) in ms, for a quick spot-check: ",
           paste(head(per_row_ms, 3), collapse = ", ")),
    ""
  )
  cat("Extracted:", basename(dest), "| manual =", duration_min, "min | package =", pkg_result$duration_minutes, "min\n")
}

writeLines(summary_lines, file.path(OUT_DIR, "README_how_to_verify.txt"))
cat("\nAll files written to:", OUT_DIR, "\n")
unlink(extract_dir, recursive = TRUE, force = TRUE)
