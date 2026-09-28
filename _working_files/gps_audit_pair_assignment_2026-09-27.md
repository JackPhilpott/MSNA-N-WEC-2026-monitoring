# The "GPS duplicate submissions" KPI counts audit pairs, not reused GPS (found 2026-09-27)

Decision needed from Jack. Nothing has been changed: GPS assignment, the audit union and the KPI are as they were.

## What happens today
- The anonymised export contains no submitted coordinates. `prep_real_submissions.R` (section 6) takes `latitude_submitted` / `longitude_submitted`
  from the newest daily `spatial_duplicate_audit_<date>.xlsx` (`cleaning/MSNA_Data_Cleaning/output/checking/internal_audit/`).
  Each audit row is a flagged pair (`uuid`, `matched_uuid`) with ONE lat/lon and the `distance_m` between the two.
- Prep copies that one lat/lon onto BOTH members of the pair.
- The audit is a one-day snapshot, so coordinates come and go every day (26 Sep audit: 310 uuids; 27 Sep audit: 242).

## Whose coordinates are they? The `uuid` member's own; the `matched_uuid` member never gets its own
- Test: a uuid that appears as a `uuid` row (its own coordinates) and, in another row, as a `matched_uuid` (the coordinates it was given).
  If the audit lat/lon are the `uuid` member's GPS, the gap between the two must equal that pair's `distance_m`.
  **566 of 566** combinations (118 uuids, 27 Sep audit) satisfy it, 494 of them with a pair distance of 5 m or more, so it is not a trivial test.
  Across all 40 daily audit files it held without exception.
- Limit: I could not confirm it against raw device points. The only raw geopoint in the export (`idp_tier2_geopoint`) is 170 to 220 m from the audit
  coordinates for both members, so it is a different measurement.
- 96 of the 242 uuids that carry coordinates (40%) only ever appear as a `matched_uuid`, so their "submitted GPS" is the partner's.
  Distance from the partner's coordinates to theirs: median 43 m, p90 513 m, max 660 m (all 802 pairs: median 12.5 m, p90 39 m, max 660 m).

## Effect on the dashboard KPI
- Data Integrity tab "GPS duplicate submissions" = completed rows sharing identical coordinates (`find_gps_duplicate_groups()` in `global.R`).
- Current data: 60 groups, 151 rows. **60 of 60 groups (100%) are produced by pair assignment**: every member is in a 27 Sep audit row carrying exactly
  that coordinate. No group has two members that are both the `uuid` (own-coordinate) member. 92 of the 151 rows (61%) are assigned-only.
- So the KPI cannot detect genuine reuse. It shows no evidence of it, because it only ever sees one own reading per group.

## Side effect on `dist_to_claimed_device_m` (non-IDP only)
- 69 rows have a value today; 30 of them (43%) rest on assigned coordinates. For those 30 the coordinate error is the pair separation:
  median 36 m, p90 49 m, max 100 m (one row is at 100 m).
- IDP rows have no such distance, so their larger errors (66 assigned-only IDP rows: median 170 m, max 660 m) only matter to the KPI.
- The recovery workbook's GPS Duplicates sheet reads rows with a distance (`full_batch_pipeline.R`, `gps_all`). Do not build that sheet before this is decided.

## Options
1. **Stop assigning the partner's coordinates (recommended first step).** Only the `uuid` member gets coordinates: 146 rows instead of 242 today.
   `dist_to_claimed_device_m` becomes correct for those rows, and the KPI drops to about zero. It changes what the KPI means.
2. **Retire the KPI** (and keep or drop the coordinates).
- A union across audits (keeping coordinates that disappear from the newest file) fixes the day-to-day flicker but keeps the artefact, so it should follow option 1, not replace it.

Reproduce: `python -B "_working_files/scripts/audit_pair_assignment_check.py" 2026-09-27` (stdlib only, read-only).
