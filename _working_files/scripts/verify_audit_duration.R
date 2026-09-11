suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(readr); library(purrr); library(stringr)
})
source("cleaning/real/audit_duration.R")

DELETION_LOG_DIR <- "cleaning/MSNA_Data_Cleaning/output/checking/db/deletion"
deletion_files <- list.files(DELETION_LOG_DIR, pattern = "_deletion_log_full_dataset\\.xlsx$", full.names = TRUE)
all_del <- map_dfr(deletion_files, function(f) {
  df <- read_excel(f); if (nrow(df) == 0) return(tibble()); df$source_file <- basename(f); df
})
latest_del <- all_del %>% arrange(uuid, desc(source_file)) %>% distinct(uuid, .keep_all = TRUE)
do_duration <- latest_del %>% filter(str_detect(coalesce(all_reasons, ""), "duration_under_20")) %>% pull(uuid) %>% unique()

subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE)
ours_naive_duration <- subs %>% filter(flag_duration_outlier == TRUE) %>% pull(submission_uuid)

only_do <- setdiff(do_duration, ours_naive_duration)
only_ours_naive <- setdiff(ours_naive_duration, do_duration)
disputed <- unique(c(only_do, only_ours_naive))
cat("Disputed uuids (either side, naive calc):", length(disputed), "\n")
cat("  DO flagged, naive calc didn't:", length(only_do), "\n")
cat("  Naive calc flagged, DO didn't:", length(only_ours_naive), "\n")

cat("\nComputing REAL audit-based duration for just the disputed set (targeted, fast)...\n")
real_audit <- compute_our_audit_durations(only_uuids = disputed, verbose = TRUE)

cat("\nHow many of the disputed uuids got a real audit duration back?", sum(!is.na(real_audit$duration_audit_sum_all_minutes)), "of", nrow(real_audit), "\n")

# Build comparison table
naive <- subs %>% select(submission_uuid, org_id, duration_min, flag_duration_outlier, interview_outcome) %>%
  rename(uuid = submission_uuid)
comparison <- real_audit %>%
  left_join(naive, by = "uuid") %>%
  mutate(
    do_flagged = uuid %in% do_duration,
    real_audit_flagged = !is.na(duration_audit_sum_all_minutes) & duration_audit_sum_all_minutes < 20,
    naive_flagged = flag_duration_outlier
  )

cat("\n=== Using the REAL audit duration instead of naive: does DO agree now? ===\n")
cat("DO flagged, real audit ALSO flags (agreement):", sum(comparison$do_flagged & comparison$real_audit_flagged, na.rm=TRUE), "\n")
cat("DO flagged, real audit does NOT flag (still disagree):", sum(comparison$do_flagged & !comparison$real_audit_flagged, na.rm=TRUE), "\n")
cat("DO didn't flag, real audit DOES flag (still disagree):", sum(!comparison$do_flagged & comparison$real_audit_flagged, na.rm=TRUE), "\n")
cat("DO didn't flag, real audit doesn't either (agreement, naive was just wrong):", sum(!comparison$do_flagged & !comparison$real_audit_flagged, na.rm=TRUE), "\n")

cat("\n=== Full disputed-set detail (first 30 rows) ===\n")
print(as.data.frame(comparison %>%
  select(uuid, org_id, interview_outcome, duration_min, duration_audit_sum_all_minutes, do_flagged, naive_flagged, real_audit_flagged) %>%
  head(30)))

write_csv(comparison, "duration_audit_verification.csv")
cat("\nWritten full comparison to duration_audit_verification.csv\n")
