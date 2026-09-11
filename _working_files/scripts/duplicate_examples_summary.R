suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(readr); library(purrr); library(stringr)
})

DELETION_LOG_DIR <- "cleaning/MSNA_Data_Cleaning/output/checking/db/deletion"
deletion_files <- list.files(DELETION_LOG_DIR, pattern = "_deletion_log_full_dataset\\.xlsx$", full.names = TRUE)
all_del <- map_dfr(deletion_files, function(f) {
  df <- read_excel(f); if (nrow(df) == 0) return(tibble()); df$source_file <- basename(f); df
})
latest_del <- all_del %>% arrange(uuid, desc(source_file)) %>% distinct(uuid, .keep_all = TRUE)
do_flagged_dup <- latest_del %>% filter(str_detect(coalesce(all_reasons, ""), "duplicate_point")) %>% pull(uuid) %>% unique()

subs <- read_csv("data/real_submissions.csv", show_col_types = FALSE) %>%
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

ours_only <- subs %>% filter(is_duplicate == TRUE, !(submission_uuid %in% do_flagged_dup))

cat("=== interview_outcome mix among the 374 'ours-only' flagged rows ===\n")
print(table(ours_only$interview_outcome, useNA = "ifany"))

cat("\n=== org_id distribution among the 374 ===\n")
print(table(ours_only$org_id, useNA = "ifany"))

cat("\n=== pop_type mix among the 374 (idp vs non-idp) ===\n")
print(table(ours_only$pop_type, useNA = "ifany"))

cat("\n=== how many DISTINCT claim groups (recon_key) do the 374 fall into? ===\n")
verified <- subs %>% filter(submission_uuid %in% ours_only$submission_uuid, recon_group_size == claim_group_size, !is.na(recon_key))
n_groups <- n_distinct(verified$recon_key)
cat("Distinct groups:", n_groups, " | rows covered:", nrow(verified), " of 374\n")

cat("\n=== group size distribution (claim_group_size) across those groups ===\n")
grp_sizes <- verified %>% distinct(recon_key, claim_group_size)
print(summary(grp_sizes$claim_group_size))
print(table(grp_sizes$claim_group_size))

cat("\n=== how many groups have size == 2 (simplest, single-pair examples)? ===\n")
pair_groups <- grp_sizes %>% filter(claim_group_size == 2)
cat("Count:", nrow(pair_groups), "\n")
print(head(pair_groups, 10))

cat("\n=== full detail for 3 small (size-2 or 3) pair examples, across different orgs ===\n")
small_keys <- grp_sizes %>% filter(claim_group_size %in% c(2,3)) %>% distinct(recon_key) %>%
  inner_join(subs %>% distinct(recon_key, org_id), by = "recon_key") %>%
  group_by(org_id) %>% slice(1) %>% ungroup() %>% pull(recon_key) %>% head(4)

pair_detail <- subs %>% filter(recon_key %in% small_keys) %>%
  select(recon_key, submission_uuid, org_id, matched_cluster_id, pop_type, interview_outcome,
         idp_hh_number_from_listing, idp_walk_position, is_duplicate, claim_group_size, start_datetime) %>%
  arrange(recon_key, start_datetime)
print(as.data.frame(pair_detail))
write_csv(pair_detail, "duplicate_pair_examples_for_do.csv")

cat("\n=== the 6 mega-groups shown earlier: date span per group ===\n")
mega_keys <- grp_sizes %>% arrange(desc(claim_group_size)) %>% head(6) %>% pull(recon_key)
mega_spans <- subs %>% filter(recon_key %in% mega_keys) %>%
  group_by(recon_key, org_id, matched_cluster_id, claim_group_size) %>%
  summarise(n_completed = sum(interview_outcome == "completed", na.rm=TRUE),
            n_total = n(),
            first_date = min(submission_date), last_date = max(submission_date),
            days_span = as.integer(max(submission_date) - min(submission_date)) + 1,
            .groups = "drop")
print(as.data.frame(mega_spans))
