# ==============================================================================
# partner_registry.R - who counts as a partner even when they hold NO LGA.
#
# WHY (2026-09-25, Jack via Coordinator, prerequisite for the ACF -> ZOA
# reallocation): every partner list in this repo was derived from
# partner_lga_assignment.csv, so a partner whose LGAs are all moved to someone
# else simply DISAPPEARS: no row in the partner table or charts, absent from the
# sidebar partner filter (whose default "everything selected" then silently drops
# its submissions from every filtered view, including the LGAs' new owner's
# totals), no Partner Report, no recovery workbook or email (so its own
# collector-routed follow-up items are orphaned), and prep's "unknown org_id"
# sanity check fires for every one of its interviews. The registry is the fix:
#
#   registry = every org_id in the assignment  UNION  config/partner_registry.csv
#
# config/partner_registry.csv (not gitignored, so version-controlled once committed; hand-kept) lists ONLY the partners
# that must stay known although they hold no LGA - today: acf, pre-registered
# ahead of the move. Adding a partner there is a decision, not an inference from
# data, which is what makes an unregistered collector a real anomaly again.
#
# read_partner_registry() -> org_id, n_lgas, in_assignment, in_config
#                            (n_lgas = 0 is a "no LGAs assigned" partner)
# refresh_partner_registry() writes the derived copy the deployed dashboard reads
#   (input_data/partner_coverage/partner_registry.csv - the app cannot see config/).
#   Called from prep_partner_lga_assignment.R and deploy_dashboard.R, next to
#   refresh_coverage_state().
# ==============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})

PARTNER_REGISTRY_CONFIG <- "config/partner_registry.csv"
PARTNER_REGISTRY_PATH <- "input_data/partner_coverage/partner_registry.csv"
PARTNER_REGISTRY_ASSIGNMENT <- "input_data/partner_coverage/partner_lga_assignment.csv"

read_partner_registry <- function(project_dir = ".", assignment_path = PARTNER_REGISTRY_ASSIGNMENT, config_path = PARTNER_REGISTRY_CONFIG) {
  old_wd <- setwd(project_dir); on.exit(setwd(old_wd))
  asg <- read_csv(assignment_path, show_col_types = FALSE, col_types = cols(.default = "c"))
  cfg <- if (file.exists(config_path)) read_csv(config_path, show_col_types = FALSE, col_types = cols(.default = "c"), na = character()) else tibble(org_id = character())
  cfg_ids <- trimws(tolower(cfg$org_id)); cfg_ids <- cfg_ids[nzchar(cfg_ids)]
  # NB: not named n_lgas - inside tibble() that name would resolve to the column being built
  lga_counts <- table(asg %>% distinct(adm2_pcode, org_id) %>% pull(org_id))
  ids <- sort(union(names(lga_counts), cfg_ids))
  tibble(org_id = ids,
         n_lgas = as.integer(ifelse(ids %in% names(lga_counts), lga_counts[ids], 0L)),
         in_assignment = ids %in% names(lga_counts),
         in_config = ids %in% cfg_ids)
}

refresh_partner_registry <- function(project_dir = ".", quiet = FALSE) {
  reg <- read_partner_registry(project_dir)
  old_wd <- setwd(project_dir); on.exit(setwd(old_wd))
  write_csv(reg, PARTNER_REGISTRY_PATH)
  if (!quiet) cat(sprintf("refresh_partner_registry(): %d partners (%d with LGAs, %d with none%s)\n", nrow(reg), sum(reg$n_lgas > 0), sum(reg$n_lgas == 0),
                          if (any(reg$n_lgas == 0)) paste0(": ", paste(reg$org_id[reg$n_lgas == 0], collapse = ", ")) else ""))
  invisible(reg)
}

if (sys.nframe() == 0) refresh_partner_registry(if (basename(getwd()) == "shared") "../.." else ".")
