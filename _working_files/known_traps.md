# Known traps (2_monitoring data prep)

## Labels looked up in the WORKING frame go blank when an area leaves WORKING (found 2026-09-27)
- WORKING is the shrinking "still needs sampling" pool. An LGA or cluster leaves it when fully achieved or when its area goes inaccessible.
- `prep_real_submissions.R` used to translate `admin2` pcode to `admin2_submitted` and `matched_cluster_id` to `idp_population_category` through WORKING,
  so interviews already collected lost their LGA name / IDP category after an accessibility change (27 Sep: Shagari 31 rows, 5 IDP clusters 62 rows; about
  1,090 older IDP rows and Gubio's 31 were already blank). Fixed 2026-09-27: the state name, LGA name and IDP category lookups now read FULL.
- STILL on WORKING, left alone on purpose:
  - `cleaning/prep/prep_partner_lga_assignment.R:107-112` (`frame_lga`) matches partner LGA names against WORKING. It is a manual script, not in the deploy chain.
    It has a FULL fallback (`full_frame`, line 125) only so an LGA the design excluded is not fuzzy-matched onto a different active one.
    TRAP: an LGA that has left WORKING but is still covered in FULL and assigned to a partner (Shagari, since 27 Sep) may not exact-match on the next run.
    The 16 Sep warning "11 partner-LGA row(s) could not be matched" (Gubio, Kukawa, Gujba, Isa, Kebbe, Sakaba, Shanga, Sabon Birni) was this class.
    After any rerun, read the "could not be matched" warning in `data/SANITY_WARNINGS.txt` and compare the assignment row count before trusting it.
  - `cleaning/prep/prep_admin3_wards.R:27-31` uses strata-level WORKING only for the list of states (one-time script).
  - `scripts/shared/coverage_state.R:184-187` uses stage2 WORKING as the ACTIVE-clusters set. Deliberate; not a label lookup.
- Already on FULL: `dashboard_app/global.R` `household_frame` (covered / none), `cleaning/prep/prep_psu_geometries.R`.
