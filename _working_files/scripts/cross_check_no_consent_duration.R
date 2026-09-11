suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(readr); library(purrr); library(stringr)
})

DELETION_LOG_DIR <- "cleaning/MSNA_Data_Cleaning/output/checking/db/deletion"
deletion_files <- list.files(DELETION_LOG_DIR, pattern = "_deletion_log_full_dataset\\.xlsx$", full.names = TRUE)
all_del <- map_dfr(deletion_files, function(f) {
  df <- read_excel(f); if (nrow(df) == 0) return(tibble()); df$source_file <- basename(f); df
})
latest_del <- all_del %>% arrange(uuid, desc(source_file)) %>% distinct(uuid, .keep_all = TRUE)

do_no_consent <- latest_del %>% filter(str_detect(coalesce(all_reasons, ""), "no_consent")) %>% pull(uuid) %>% unique()
do_duration   <- latest_del %>% filter(str_detect(coalesce(all_reasons, ""), "duration_under_20")) %>% pull(uuid) %>% unique()

subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE)

cat("=== NO_CONSENT cross-check ===\n")
cat("DO flagged (any file, latest per uuid):", length(do_no_consent), "\n")
ours_no_consent <- subs %>% filter(interview_outcome == "consent_refused") %>% pull(submission_uuid)
cat("Ours (interview_outcome == consent_refused):", length(ours_no_consent), "\n")
cat("In DO's but not ours:", length(setdiff(do_no_consent, ours_no_consent)), "\n")
cat("In ours but not DO's:", length(setdiff(ours_no_consent, do_no_consent)), "\n")

cat("\n=== DURATION_UNDER_20 cross-check ===\n")
cat("DO flagged (any file, latest per uuid):", length(do_duration), "\n")
ours_duration <- subs %>% filter(flag_duration_outlier == TRUE) %>% pull(submission_uuid)
cat("Ours (flag_duration_outlier, our own start/end-based duration_min < 20):", length(ours_duration), "\n")
cat("In DO's but not ours:", length(setdiff(do_duration, ours_duration)), "\n")
cat("In ours but not DO's:", length(setdiff(ours_duration, do_duration)), "\n")

only_do <- setdiff(do_duration, ours_duration)
only_ours <- setdiff(ours_duration, do_duration)
if (length(only_do) > 0) {
  cat("\nExample(s) DO flagged, we didn't (first 5), with our own duration_min:\n")
  print(subs %>% filter(submission_uuid %in% head(only_do, 5)) %>% select(submission_uuid, org_id, duration_min, interview_outcome))
}
if (length(only_ours) > 0) {
  cat("\nExample(s) we flagged, DO didn't (first 5), with our own duration_min:\n")
  print(subs %>% filter(submission_uuid %in% head(only_ours, 5)) %>% select(submission_uuid, org_id, duration_min, interview_outcome))
}
