# Questions for the data officer

Running list — add to this as new questions come up during dashboard/
cleaning work; clear an item once it's been asked and resolved (note the
answer inline rather than deleting, so the reasoning survives).

## Open

### 1. GPS-outlier flag reference point (raised 2026-09-01)
The dashboard's "GPS outliers" KPI (`flag_gps_outlier` in
`cleaning/real/prep_real_submissions.R`, threshold
`dist_btn_sample_collected > 500m`) disagrees with the officer's own
`dist_btn_sample_collected` field for ~91% of flagged non-IDP rows — those
rows show a currently-valid distance well under 500m by our own
recomputation, despite being flagged.

**Ask:** what point is `dist_btn_sample_collected` actually measured
against on your end — the originally-assigned sample point, or something
else (a replacement/reserve point, a resampled point)? We're matching
against `matched_survey_id` as currently assigned in the frame; if your
field is computed against a different reference point, that would explain
the mismatch and tell us which side needs to change.

### 2. Anonymised export naming convention (raised 2026-09-02)
Two 2026-09-01-dated exports appeared side by side in
`cleaning/MSNA_Data_Cleaning/output/anonymised_data/` under two different
naming conventions: `NGA2605_MSNA_anonymised_2026-09-01.xlsx` and
`anon_2026-09-01.xlsx` (the latter was the newer/correct one to use).

**Ask:** has the export naming convention changed, or was this a one-off?
If it's changed going forward, let us know the new pattern so our "pick
the latest file" logic can be aligned with it rather than just working
around it.

## Resolved
(none yet)
