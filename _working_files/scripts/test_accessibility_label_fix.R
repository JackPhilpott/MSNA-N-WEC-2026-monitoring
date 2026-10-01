suppressPackageStartupMessages({library(dplyr); library(readr)})
setwd("c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring")
INPUT_DIR <- "input_data"  # the canonical copy - matches global.R's own INPUT_DIR resolution
                            # when sourced from dashboard_app/ during a local deploy run
                            # (dir.exists("../input_data") is TRUE in a full repo checkout)

strata_frame <- read_csv(
  Sys.glob("input_data/sampling_frame/NGA_MSNA_2026_strata_level_sampling_frame_v*_WORKING.csv")[1],
  show_col_types = FALSE
) %>% distinct(strata_id, adm2_pcode)

raw <- read_csv(file.path(INPUT_DIR, "accessibility/accessibility_strata_level.csv"), show_col_types = FALSE)
cat("raw column classes:\n")
print(sapply(raw[, c("% of population remaining", "Updated population within accessible area", "Total population (design, n_pop)")], class))

accessibility_pop_remaining_label <- raw %>%
  mutate(
    `% of population remaining` = suppressWarnings(as.numeric(`% of population remaining`)),
    `Updated population within accessible area` = suppressWarnings(as.numeric(`Updated population within accessible area`)),
    `Total population (design, n_pop)` = suppressWarnings(as.numeric(`Total population (design, n_pop)`))
  ) %>%
  left_join(strata_frame, by = c("Strata ID" = "strata_id")) %>%
  filter(!is.na(adm2_pcode)) %>%
  transmute(
    adm2_pcode,
    label = ifelse(
      is.na(`% of population remaining`) | is.na(`Updated population within accessible area`) | is.na(`Total population (design, n_pop)`),
      paste0(`Pop type`, ": N/A"),
      paste0(
        `Pop type`, ": ", round(`% of population remaining`), "% (",
        formatC(round(`Updated population within accessible area`), big.mark = ",", format = "d"), " of ",
        formatC(round(`Total population (design, n_pop)`), big.mark = ",", format = "d"), ")"
      )
    )
  ) %>%
  group_by(adm2_pcode) %>%
  summarise(pop_remaining_label = paste(label, collapse = " | "), .groups = "drop")

cat("\nNO CRASH. rows:", nrow(accessibility_pop_remaining_label), "\n")
cat("\nsample rows containing 'N/A':\n")
print(as.data.frame(head(accessibility_pop_remaining_label[grepl("N/A", accessibility_pop_remaining_label$pop_remaining_label), ], 5)))
cat("\nsample normal rows:\n")
print(as.data.frame(head(accessibility_pop_remaining_label[!grepl("N/A", accessibility_pop_remaining_label$pop_remaining_label), ], 3)))
cat("\ntotal rows with at least one N/A pop type:", sum(grepl("N/A", accessibility_pop_remaining_label$pop_remaining_label)), "\n")
