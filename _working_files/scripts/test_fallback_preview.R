source("reports/partner_data_recovery/scripts/issue_tracker.R")
cat("issue_tracker.R sourced OK\n")
source("reports/partner_data_recovery/scripts/fallback_resolvers.R")
cat("fallback_resolvers.R sourced OK\n")

t0 <- Sys.time()
res <- preview_fallback_sweep()
cat(sprintf("\nelapsed: %.1fs\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))

# spot-check a few real rows from each outcome/mechanism so this isn't just
# summary counts - print actual candidate resolutions
cat("\n--- sample applied_candidate rows, iom_dtm_listing ---\n")
print(as.data.frame(head(res[res$outcome == "applied_candidate" & res$fallback_mechanism == "iom_dtm_listing", c("issue_id","org_id","cluster_id","fallback_resolution")], 3)), row.names = FALSE)

cat("\n--- sample applied_candidate rows, gis_nearest_household (non-IDP) ---\n")
nonidp_applied <- res[res$outcome == "applied_candidate" & res$fallback_mechanism == "gis_nearest_household" & grepl("^Non-IDP", res$fallback_resolution), ]
print(as.data.frame(head(nonidp_applied[, c("issue_id","org_id","cluster_id","fallback_resolution")], 3)), row.names = FALSE)

cat("\n--- sample applied_candidate rows, gis_nearest_household (IDP) ---\n")
idp_applied <- res[res$outcome == "applied_candidate" & res$fallback_mechanism == "gis_nearest_household" & grepl("^IDP", res$fallback_resolution), ]
print(as.data.frame(head(idp_applied[, c("issue_id","org_id","cluster_id","fallback_resolution")], 3)), row.names = FALSE)

cat("\n--- sample no_fallback_defined rows ---\n")
print(as.data.frame(head(res[res$outcome == "no_fallback_defined", c("issue_id","issue_type","deletion_reason")], 5)), row.names = FALSE)

cat("\n--- sample no_candidate_available rows ---\n")
print(as.data.frame(head(res[res$outcome == "no_candidate_available", c("issue_id","fallback_resolution")], 5)), row.names = FALSE)

# double-check: same nearest household never handed to two different
# duplicates in one run (the claimed_this_sweep_* tracking)
gis_rows <- res[res$fallback_mechanism == "gis_nearest_household" & res$outcome == "applied_candidate", ]
nonidp_survey_ids <- regmatches(gis_rows$fallback_resolution, regexpr("non_idp_[A-Za-z0-9_]+", gis_rows$fallback_resolution))
cat(sprintf("\nno-double-assignment check: %d non-IDP candidates assigned, %d distinct survey_ids\n",
            length(nonidp_survey_ids), length(unique(nonidp_survey_ids))))
