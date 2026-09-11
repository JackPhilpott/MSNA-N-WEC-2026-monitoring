suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(readr); library(purrr); library(stringr)
})

DELETION_LOG_DIR <- "cleaning/MSNA_Data_Cleaning/output/checking/db/deletion"
deletion_files <- list.files(DELETION_LOG_DIR, pattern = "_deletion_log_full_dataset\\.xlsx$", full.names = TRUE)
cat("Found", length(deletion_files), "DO deletion log files\n")

all_del <- map_dfr(deletion_files, function(f) {
  df <- read_excel(f)
  if (nrow(df) == 0) return(tibble())
  df$source_file <- basename(f)
  df
})
cat("Combined rows across all files:", nrow(all_del), "\n")
cat("all_reasons sample:\n")
print(head(all_del$all_reasons[!is.na(all_del$all_reasons)], 5))

# latest file per uuid, matching register_deletion_log_issues.R's own convention
latest_del <- all_del %>%
  arrange(uuid, desc(source_file)) %>%
  distinct(uuid, .keep_all = TRUE)

do_flagged_dup <- latest_del %>%
  filter(str_detect(coalesce(all_reasons, ""), "duplicate_point")) %>%
  pull(uuid) %>% unique()

cat("\nDO's latest-per-uuid duplicate_point-flagged count:", length(do_flagged_dup), "\n")

subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE)
cat("Total rows in real_submissions.csv:", nrow(subs), "\n")
cat("Total is_duplicate==TRUE in real_submissions.csv:", sum(subs$is_duplicate, na.rm = TRUE), "\n")

ours_only <- subs %>%
  filter(is_duplicate == TRUE, !(submission_uuid %in% do_flagged_dup))
cat("Flagged by us, NOT flagged duplicate_point by DO (latest file per uuid):", nrow(ours_only), "\n")

# Reconstruct claim groups to pull full pairs, self-verified against claim_group_size
subs2 <- subs %>%
  mutate(
    recon_key = case_when(
      pop_type == "idp" & !is.na(idp_hh_number_from_listing) ~ paste0(matched_cluster_id, "|listing_", idp_hh_number_from_listing),
      pop_type == "idp" & !is.na(idp_walk_position) ~ paste0(matched_cluster_id, "|walk_", idp_walk_position),
      pop_type == "idp" ~ NA_character_,
      TRUE ~ non_idp_point_id
    )
  ) %>%
  group_by(recon_key) %>%
  mutate(recon_group_size = if_else(is.na(recon_key), 1L, n())) %>%
  ungroup()

# candidate rows: ours_only, where our reconstruction matches the real claim_group_size (verified-safe)
candidates <- subs2 %>%
  filter(submission_uuid %in% ours_only$submission_uuid, recon_group_size == claim_group_size, !is.na(recon_key)) %>%
  arrange(desc(claim_group_size), recon_key, start_datetime)

cat("\nVerified-safe candidate flagged rows (reconstruction matches claim_group_size):", nrow(candidates), "\n")

# pick up to 6 distinct claim groups, show every member of each (so the DO sees the full pair, kept + dropped)
top_keys <- candidates %>% distinct(recon_key) %>% head(6) %>% pull(recon_key)

example_groups <- subs2 %>%
  filter(recon_key %in% top_keys) %>%
  select(recon_key, submission_uuid, org_id, matched_cluster_id, pop_type,
         non_idp_point_id, idp_hh_number_from_listing, idp_walk_position,
         is_duplicate, claim_group_size, start_datetime, submission_date) %>%
  arrange(recon_key, start_datetime)

cat("\n==== EXAMPLE GROUPS (full pair/group, kept + flagged) ====\n")
print(as.data.frame(example_groups))

write_csv(example_groups, "duplicate_examples_for_do.csv")
cat("\nWritten to duplicate_examples_for_do.csv\n")
