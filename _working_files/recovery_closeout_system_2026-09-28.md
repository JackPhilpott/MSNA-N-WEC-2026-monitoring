# Recovery-workbook closeout system — built & tested 2026-09-28

Built per Jack's spec (relayed by Coordinator, 28 Sep — the final partner-response deadline day).
Goal: whatever's still open after tomorrow's real partner-response ingestion gets a pre-computed,
defensible fallback resolution instead of quietly staying lost data, and the whole thing produces
one CSV Jack can sanity-check before it goes to the data officer at midday.

**Code:** `reports/partner_data_recovery/scripts/fallback_resolvers.R` (new). Schema extended in
`issue_tracker.R`/`issue_tracker.py` (4 new tracker columns — see below). Nothing else changed.

## Tomorrow morning runbook

```r
source("reports/partner_data_recovery/scripts/issue_tracker.R")
source("reports/partner_data_recovery/scripts/fallback_resolvers.R")

# 1. Ingest real partner responses AS USUAL, UNCHANGED (verify_data_recovery_response.py /
#    review_recovery_response.py) — this always runs first and always wins.

# 2. Preview the fallback sweep against whatever's still open after that ingestion:
preview_fallback_sweep()

# 3. Apply it (only after step 1 has actually run — needs Jack's go, same as every other
#    apply_*(confirm=TRUE) script this project uses):
apply_fallback_sweep(confirm = TRUE)

# 4. Produce the DO-facing log:
build_do_deletion_log()   # writes reports/partner_data_recovery/outputs/deletion_log_for_DO_<date>.csv

# Undo, if ever needed (one call, from the snapshot path apply_fallback_sweep() printed/returned):
restore_fallback_sweep("<snapshot csv>")
```

## What it does

A generic resolver **registry** keyed by `(issue_type, deletion_reason)`, not hardcoded to two
mechanisms — anything with no registered resolver comes out as `no_fallback_defined`, never
silently guessed at.

**Mechanism 1 — `missing_hh_listing` (IDP, cluster-level) → IOM DTM site.** Joins the cluster's
`iom_site_id` (already on the sampling frame) against the two *live* DTM files in
`1_sampling/input_data/population/iom/` (NCNW R18 + NGA R51 NE — not `_archive/`, not the dated
`.bak`). Records the DTM household count as the listing source.

**Mechanism 2 — `confirmed_deletion/duplicate_point` + `gps_duplicate` → nearest available
household.**
- Non-IDP: real haversine GIS distance, reusing `full_batch_pipeline.R`'s own vetted
  `frame_nonidp`/`claimed_ids_national`/`haversine_m()` definitions (a fallback candidate can
  never disagree with what a partner already saw offered in their own workbook). **Anchor point**
  prefers the interview's own submitted GPS reading (`latitude_submitted`/`longitude_submitted`)
  when present (this is the whole premise of a `gps_duplicate` row); most `duplicate_point` rows
  have NO device GPS at all (2_monitoring's own anonymised export only carries raw coordinates for
  a minority of rows — CLAUDE.md's "Independent deletion checks" section), so for those it falls
  back to the **disputed point's own known frame coordinate** (`non_idp_point_id` looked up by
  `survey_id`) — found empirically today that without this fallback, 0 of 739 non-IDP candidates
  were found at all (100% had NA device GPS); with it, 1,374 of 1,615 found a real candidate.
- IDP: nearest unclaimed household **number** in the cluster's real HH-listing drawn pool
  (`real_hh_listing.R`'s `compute_real_avail_pools()`/`resolve_avail_list()` — same pool
  `full_batch_pipeline.R`'s own IDP Listing Duplicates dropdown uses). IDP sites have one GPS point
  per *site*, not per household, so there's no household-level lat/lon to run GIS matching on —
  listing-number proximity is the established, correct analogue, not a simplification.
- A shared, mutable `claimed_state` (an R environment, not a local variable) tracks which
  candidates have already been handed out **within one sweep**, across BOTH registry entries that
  route to this same function — found and fixed a real 3-collision bug from an earlier version that
  reset this state per-bucket instead of per-sweep.

**Deliberately unregistered** (per Jack): `pct_missing_flagged`, `idp_listing_duplicate` (Jack
working these out himself, separately, today — 0 pending of the latter right now regardless).
**Not asked for, so also unregistered:** `confirmed_deletion/{listing_missing, crs_unmatched,
date_outlier}` (`date_outlier` already has its own separate resolver for its 2 genuinely-stale
rows — `resolve_stale_date_outlier_rows.R`). **`fcs_zero` is completely out of this system** — not
a deletion reason any more since 2026-09-10, never touched here.

## Framework rules (non-negotiable, enforced in code)

1. A fallback resolution is **never** a real "confirmed" resolution. It's written to 4 new tracker
   columns only (`fallback_status`/`fallback_mechanism`/`fallback_resolution`/
   `fallback_applied_date`) and never touches `status`/`confirmed_by`/`recovery_type`.
   `apply_resolution()` is never called from `fallback_resolvers.R`.
2. A real partner response always wins, **even after** a fallback has already been applied — tested
   explicitly (see below): applying a fallback never marks an issue terminal, so nothing blocks a
   later `apply_resolution(..., "confirmed", confirmed_by="partner")` call on the same issue_id.
3. Same preview → explicit confirm → snapshot-before-apply → undo discipline as
   `resolve_live_claimant_duplicates.R`/`resolve_stale_date_outlier_rows.R` (structure only — the
   matching logic is new, see above). `apply_fallback_sweep()` only ever writes a row whose
   `fallback_status` is still blank, so re-running it is a safe no-op for anything already
   processed.

## Tested today (read-only preview + a full apply/restore cycle on an isolated scratch copy of the
tracker — the REAL tracker was never touched, verified by md5 before/after)

Live tracker, 4,895 rows, 2,112 currently open without a `fallback_status`:

| issue_type | deletion_reason | outcome | n |
|---|---|---|---|
| confirmed_deletion | duplicate_point | applied_candidate | 1,374 |
| missing_hh_listing | — | applied_candidate | 348 |
| confirmed_deletion | duplicate_point | no_candidate_available | 241 |
| confirmed_deletion | listing_missing | no_fallback_defined | 113 |
| confirmed_deletion | crs_unmatched | no_fallback_defined | 20 |
| gps_duplicate | — | applied_candidate | 11 |
| confirmed_deletion | date_outlier | no_fallback_defined | 5 |

**Overall: 1,733 applied_candidate / 241 no_candidate_available / 138 no_fallback_defined.**

Scratch-copy apply→restore test (`_working_files/scripts/test_fallback_apply_restore.R`) verified,
step by step: (1) apply only ever changed the 4 fallback_* columns — diffed every other column,
zero changes; (2) simulated a late real partner response on an already-fallback-applied row — not
blocked, `fallback_status` left as a historical record; (3) a second `apply_fallback_sweep()` call
was a full no-op on already-processed rows; (4) `restore_fallback_sweep()` correctly reverted
exactly the 4 columns and nothing else (the simulated partner-confirmed row's real `status` stayed
`confirmed` through the restore); (5) the live `recovery_issue_tracker.csv` was byte-identical
(md5) before and after the entire test. `build_do_deletion_log()` tested separately
(`test_do_log.R`) — output row count matches the tracker exactly (4,895), no drops, and the
`resolution_path` split reads cleanly (`partner_or_internal_confirmed` / `fallback_sweep` /
`fallback_attempted_no_candidate` / `no_fallback_defined`).

## Known scope simplification (stated, not hidden)

The Non-IDP "still-accessible" check is `ward_accessible_status` only (a direct frame column) — it
does **not** reproduce `1_sampling/scripts/shared/frame_status.R`'s full
`compute_cluster_accessibility()` stack (below-4-accessible-primary-HH threshold, cluster-overlay
exclusions, target-correction drops). Judged not worth the same-day risk for a proxy this close
already; a handful of the 1,374 `applied_candidate` non-IDP rows could in principle point at a
household that stack would additionally exclude. Flagged here for whoever reviews the DO log.

## Nothing applied for real

`apply_fallback_sweep(confirm = TRUE)` was **not** run against the real tracker today — per the
spec, that's tomorrow's step, after real partner responses are ingested. Today's work is the
infrastructure + the read-only/scratch-tested proof it works.
