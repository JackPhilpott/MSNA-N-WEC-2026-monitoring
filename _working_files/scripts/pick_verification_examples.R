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
# NOTE: subs$duration_min is ALREADY the new audit-based figure (wired in earlier).
# Need the ORIGINAL naive value for this comparison, recompute it fresh here.
main_uuid_start_end <- NULL  # not reading raw export again; use audit cache directly instead

audit_cache <- read_csv("cleaning/real/audit_duration_cache.csv", show_col_types = FALSE) %>%
  mutate(duration_audit_min = round(duration_audit_sum_all_ms / 60000, 1))

# naive duration isn't preserved anywhere anymore (we replaced it) - but we still have
# start_datetime/end_datetime in real_submissions.csv, so recompute naive fresh here
naive <- subs %>%
  mutate(naive_duration_min = as.numeric(difftime(end_datetime, start_datetime, units = "mins"))) %>%
  select(submission_uuid, org_id, interview_outcome, start_datetime, end_datetime, naive_duration_min) %>%
  rename(uuid = submission_uuid)

combined <- naive %>%
  inner_join(audit_cache %>% select(uuid, archive_name, archive_length, duration_audit_min), by = "uuid") %>%
  mutate(
    do_flagged = uuid %in% do_duration,
    real_audit_flagged = !is.na(duration_audit_min) & duration_audit_min < 20,
    naive_flagged = !is.na(naive_duration_min) & naive_duration_min < 20
  )

# the "surprising" bucket: naive said comfortably NOT short (>=25 to be clearly unambiguous),
# DO didn't flag either, but real audit says genuinely short
surprising <- combined %>%
  filter(!naive_flagged, !do_flagged, real_audit_flagged, naive_duration_min >= 25, interview_outcome == "completed") %>%
  arrange(archive_length)  # smallest audit files first = easiest to manually inspect

cat("Candidates in the 'surprising' bucket (naive said clearly long, real audit says short):", nrow(surprising), "\n")
cat("\nSmallest-file candidates (easiest to manually verify):\n")
print(as.data.frame(surprising %>% select(uuid, org_id, naive_duration_min, duration_audit_min, archive_length) %>% head(10)))

write_csv(surprising, "surprising_bucket_full.csv")
