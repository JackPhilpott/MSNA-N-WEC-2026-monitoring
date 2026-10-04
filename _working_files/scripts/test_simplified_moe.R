# Exercises the STAGED margin-of-error toggle (Full design vs Simplified; built 2 Oct, renamed 4 Oct) through
# mod_map_server with the flag ON: with "Simplified (design effect 1)" the LGA view colours by the simplified-MoE
# label and the summary line renders; switching back to "Full design" restores the % of target colours.
# Run from the 2_monitoring repo root:
#   Rscript _working_files/scripts/test_simplified_moe.R
Sys.setenv(MSNA_FEATURE_SIMPLIFIED_MOE = "1")
setwd("dashboard_app")
suppressMessages(source("global.R"))
rule <- reactiveVal("simplified")
testServer(mod_map_server, args = list(
  filtered_stratum = reactive(progress_by_stratum), filtered_subs = reactive(submissions_raw),
  target_basis = reactive("original"), moe_basis = rule
), {
  session$setInputs(map_view = "lga", status_filter = names(CLUSTER_STATUS_COLORS))
  session$flushReact()
  cat("map rendered ok:", !is.null(output$map), "\n")
  cat("summary line:", gsub("<[^>]+>", "", as.character(output$smoe_summary$html)), "\n")
  md <- lga_map_data()
  cat("LGA polygons by simplified-MoE label:", paste(names(table(md$smoe_label_lga)), table(md$smoe_label_lga), sep = " ", collapse = ", "), "\n")
  stopifnot(all(md$fill_color %in% SMOE_COLORS), all(!is.na(md$smoe_label_lga)))
  rule("design")
  session$flushReact()
  md2 <- lga_map_data()
  cat("back on Full design - fill is the % of target colour again:", all(md2$fill_color == md2$progress_color), "\n")
  stopifnot(all(md2$fill_color == md2$progress_color), is.null(output$smoe_summary))
})
cat("Margin-of-error toggle test passed\n")
