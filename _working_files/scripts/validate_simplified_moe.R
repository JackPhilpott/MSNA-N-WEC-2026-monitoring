# Checks the dashboard's simplified margin-of-error functions (global.R, STAGED margin-of-error toggle, flag OFF by
# default) against Coordinator's prototype outputs (1_sampling/resampling/output/round1_representativity_prototype_
# 2026-10-02/ - the prototype's own file and column names still say "Round 1"), stratum by stratum and LGA by LGA,
# on the unfiltered data. Run from the 2_monitoring repo root:
#   Rscript _working_files/scripts/validate_simplified_moe.R
Sys.setenv(MSNA_FEATURE_SIMPLIFIED_MOE = "1")
setwd("dashboard_app")
suppressMessages(source("global.R"))
proto_dir <- "../../1_sampling/resampling/output/round1_representativity_prototype_2026-10-02"
norm_label <- function(x) sub("^Indicative.*", "Indicative", sub("^Dropped.*", "Dropped", x))

r1 <- add_simplified_moe(progress_by_stratum)
ps <- read_csv(file.path(proto_dir, "round1_strata.csv"), show_col_types = FALSE) %>%
  transmute(strata_id, p_n = `Achieved (Round 1)`, p_moe = `MoE Round 1 (deff=1) %`, p_label = norm_label(`Round 1 label`))
cmp <- r1 %>% select(strata_id, achieved_n, smoe_moe, smoe_label) %>% inner_join(ps, by = "strata_id")
cat("strata compared:", nrow(cmp), "of", nrow(r1), "dashboard /", nrow(ps), "prototype\n")
cat("achieved differs:", sum(cmp$achieved_n != cmp$p_n), "| label differs:", sum(cmp$smoe_label != cmp$p_label),
    "| MoE differs by > 0.01:", sum(abs(coalesce(cmp$smoe_moe, -1) - coalesce(cmp$p_moe, -1)) > 0.01), "\n")
print(table(dashboard = r1$smoe_label))
print(cmp %>% filter(smoe_label != p_label | achieved_n != p_n) %>% head(10))

lg <- simplified_moe_lga_summary(r1) %>%
  left_join(r1 %>% distinct(adm2_pcode, adm1_name, adm2_name), by = "adm2_pcode")
pl <- read_csv(file.path(proto_dir, "round1_lga.csv"), show_col_types = FALSE) %>%
  transmute(adm1_name = State, adm2_name = LGA, p_moe = `MoE Round 1 (deff=1) %`, p_label = norm_label(`Round 1 label`))
cl <- lg %>% inner_join(pl, by = c("adm1_name", "adm2_name"))
cat("\nLGAs compared:", nrow(cl), "of", nrow(lg), "dashboard /", nrow(pl), "prototype\n")
cat("label differs:", sum(cl$smoe_label_lga != cl$p_label), "| MoE differs by > 0.01:",
    sum(abs(coalesce(cl$smoe_moe_lga, -1) - coalesce(cl$p_moe, -1)) > 0.01), "\n")
print(table(dashboard_lga = lg$smoe_label_lga))
print(cl %>% filter(smoe_label_lga != p_label) %>% select(adm1_name, adm2_name, smoe_moe_lga, smoe_label_lga, p_moe, p_label) %>% head(10))
cat("\nFull design on the same strata: Complete =", sum(r1$status == "Complete"), "| Dropped =", sum(r1$status == "Dropped"), "\n")
