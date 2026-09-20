# 2_monitoring — MSNA N-WEC 2026 monitoring & dashboard

No CLAUDE.md existed for this repo before 2026-09-08, despite substantial
work having already accumulated here (dashboard app, cleaning pipeline,
deletion/recovery tracker) — written now as part of the 2026-09-08 pipeline
rebuild, alongside the rebuild itself. Not a full history of everything
that's happened in this repo before that date; focused on current structure
and, in detail, on the rebuild.

## Structure

- `dashboard_app/` — the Shiny monitoring dashboard (`global.R` + `R/mod_*.R`
  modules). Reads `../data` and `../input_data` locally; for a real deploy,
  `deploy_dashboard.R` (repo root) bundles both INTO `dashboard_app/data` /
  `dashboard_app/input_data` first, since shinyapps.io only bundles the app
  directory itself. See "Known sync gaps" below — this bundled copy can go
  stale between deploys.
- `cleaning/` — `MSNA_Data_Cleaning/` (the data officer's own cleaning
  pipeline; READ-ONLY resource from 2026-09-11 on — its `deletion_log.R` no
  longer drives any actual deletion decision, though its six rules/
  thresholds are still the reference methodology 2_monitoring's own checks
  replicate — see "Independent deletion checks" below) and `real/`
  (`prep_real_submissions.R` builds the canonical `data/real_submissions.csv`
  from the cleaning pipeline's output; `independent_deletion_checks.R` +
  `audit_duration.R` + `audit_missingness.R` independently recompute five of
  the DO's six deletion reasons (**not** `fcs_zero` — see below, that one
  was deliberately REMOVED from deletion consideration entirely, not
  recomputed), see below; `sanity_checks.R`;
  `build_confirmed_deletions_overlay.R` builds the two deletion overlays —
  see below).
- `reports/partner_data_recovery/` — the deletion/recovery-confirmation
  tracker and partner-facing recovery workbook pipeline. `scripts/
  issue_tracker.R` is the tracker's own read/write/resolve API
  (`recovery_issue_tracker.csv`); everything else in this folder builds on
  top of it. See "The review-queue engine" below for how to actually work
  through it.
- `input_data/`, `data/` — static copies of other projects' outputs (never
  read live across repos — see the parent workspace's own data-handoff
  convention) plus this repo's own derived data (`real_submissions.csv`,
  the two deletion overlays).

## Two Achieved bases — by design, expected to disagree

- **Dashboard/provisional** (`is_achieved()`, `dashboard_app/global.R`):
  `interview_outcome == "completed" & !is_duplicate & !is.na(matched_survey_id)
  & is.na(deletion_status)` — excludes ANY flagged issue, ANY status
  (pending/sent/confirmed/contested all exclude equally, not just settled
  ones) — pessimistic default, incentivizes a partner to respond before
  their number visibly drops. CORRECTED 2026-09-11: an earlier version of
  this section wrongly said Achieved only excludes settled
  (confirmed/contested) items — that is NOT what `is_achieved()` does; a
  merely-pending flag excludes here too. Reads `deletion_status`, not
  `flagged_deletion_reason` (the latter can be legitimately blank on
  pre-2026-09-06-schema tracker rows even when `deletion_status` is
  populated — using the wrong field here was a real bug, fixed 2026-09-09).
  "Pending Deletion" is a SEPARATE, third bucket sitting alongside Achieved,
  not something Achieved itself absorbs — see "Collected/Achieved/Confirmed
  Deletion/Pending Deletion" below.
- **Resampling/confirmed-only** (`05_build_accessibility_impact_workbook.py`,
  1_sampling): excludes only settled (`confirmed`/upheld-`contested`)
  deletions — conservative, avoids drawing replacements for something that
  might still be recovered.
  Reads `CONFIRMED_DELETIONS_OVERLAY.csv`.

Both overlays are built by `cleaning/real/build_confirmed_deletions_overlay.R`
from the tracker, same source, two different filters. See that file's own
header for the full reasoning.

## Collected/Achieved/Confirmed Deletion/Pending Deletion — reconciliation model (2026-09-09/10 redesign)

Every stratum-level and cluster-level progress figure satisfies one identity
EXACTLY, by construction, not by careful bookkeeping:

    Collected = Achieved + Confirmed Deletion + Oversampling Surplus

(CORRECTED 2026-09-20 — this section previously named the third term
"Pending Deletion" and gave it the `pmax(collected_n - achieved_n -
confirmed_deletion_n, 0L)` residual formula; that formula and name both
belong to Oversampling Surplus, and had since the 2026-09-11 rename this
section was never updated for. Pending Deletion is real but is NOT part of
this identity — see its own bullet below.)

- **Collected** (`collected_n`): every submission matched to the
  stratum/cluster, regardless of quality flags.
- **Achieved**: `is_achieved()` — the NARROW, pessimistic count (excludes any
  flag at all) — see "Two Achieved bases" above. UNCAPPED as of 2026-09-20
  (Jack's decision, informed by discussion with donors) — every oversampled
  interview now counts in full; until then this was additionally capped at
  each cluster's own target before being summed to stratum/LGA/national
  grain. Target itself is untouched by this change.
- **Confirmed Deletion** (`is_confirmed_deletion()`, `dashboard_app/global.R`):
  `interview_outcome == "completed"` AND `deletion_status %in% c("confirmed",
  "contested")` — settled, either via an automated no-appeal rule (currently
  `duration_under_20` and `no_consent`, see `NO_APPEAL_DELETION_REASONS` in
  `issue_tracker.R`) or a resolved recovery-workbook item. Deliberately
  gates on `interview_outcome == "completed"` too, not just `deletion_status`
  — otherwise a non-collected row could inflate this count.
- **Oversampling Surplus** (`oversampling_surplus_n`): a RESIDUAL,
  `pmax(collected_n - achieved_n - confirmed_deletion_n, 0L)` — deliberately
  NOT summed independently from duplicate/unmatched/pending-flag counts, so
  the identity above can never drift out of balance from double-counting.
  Named for what it used to capture (real interviews beyond a cluster's
  target, back when Achieved was capped); since Achieved absorbed that
  2026-09-20, this residual is normally near zero now — whatever's left is
  a genuinely different, much smaller thing (a completed, collected row
  that never resolved to a specific `matched_cluster_id`, so it can't enter
  Achieved's per-cluster count, and isn't a confirmed deletion either). It
  is NOT where to look for real oversampling any more — see
  `compute_oversampled_clusters()` (`dashboard_app/global.R`), unaffected by
  this change, for which clusters/partners actually collected past target.
- **Pending Deletion** (`pending_deletion_n`) — NOT part of the identity
  above, a separate informational subset of Achieved: how many of a
  stratum/cluster's Achieved interviews still carry an unresolved tracker
  flag (pending/sent/rejected, not yet confirmed/contested) that could
  still become a real deletion later. Directly counted, not a residual.

`compute_progress_by_stratum()` (stratum grain) and `compute_cluster_progress()`
(cluster grain) both implement this same identity — both fully uncapped as
of 2026-09-20 (cluster grain always was; there was never anything else at
single-cluster grain for a cap to protect against masking).
`TOTAL_PLANNED_INTERVIEWS_CURRENT` (alongside the original, frozen
`TOTAL_PLANNED_INTERVIEWS`) tracks the LIVE revised target as resampling adds
clusters — computed after `cluster_targets`/`strata_target_current` are
available, so it can't sit next to the original constant at file-load time.

## Independent deletion checks — replacing the DO's deletion log (2026-09-10/11)

`cleaning/MSNA_Data_Cleaning/R/deletion_log.R` (`build_deletion_log()`, six
reasons in priority order: `no_consent` > `duration_under_20` >
`duplicate_point` > `listing_missing` > `pct_missing_flagged` > `fcs_zero`)
is READ-ONLY from here on and no longer drives any actual deletion decision.
Its per-day `report_dates` output filter turned out to be a PERMANENT,
NEVER-REGENERATED snapshot (`Ak_data_cleaning_msna.R:719-728`): if a given
day's run doesn't complete, that day's flags are gone forever, since no
later run ever revisits an earlier day. This produced real, quantified
under-flagging across every reason (`no_consent` alone missed 11 of 31 real
refusals, 35% — a reason with zero judgment call involved, so there's no
"different methodology" explanation available). Jack's decision: replace
every reason with an independent recomputation on 2_monitoring's own side
that always runs against the CURRENT full dataset, never a day-snapshot.

- `cleaning/real/independent_deletion_checks.R` — the five
  `run_independent_*_check()` functions (`no_consent`, `duration_under_20`,
  `duplicate_point` [key-based only — see below], `missing_hh_listing`
  [was briefly built as `listing_missing`, corrected same night — see
  below], `pct_missing_flagged`), each registering via `issue_tracker.R`'s
  idempotent `register_issues()`. **Run order matters**: `register_issues()`
  only sets `deletion_reason` on a row's FIRST insert, never on a re-seen
  one — so these must run in the DO's own priority order (above) whenever a
  uuid could trip more than one check, or a lower-priority reason could win
  the race. `deploy_dashboard.R` and this file's own `sys.nframe()==0` block
  both encode that order. `NO_APPEAL_DELETION_REASONS` (`issue_tracker.R`)
  currently covers `duration_under_20` and `no_consent` — both validated
  methodology, no partner judgment call, auto-confirmed immediately;
  `duplicate_point`/`pct_missing_flagged` stay appeal-eligible.
- **`fcs_zero` is deliberately absent from this file** — not a gap, a
  2026-09-10 policy decision (Jack): downgraded from an automatic
  no-appeal deletion reason to a plain logical-error flag. It does
  nothing in the deletion pipeline any more — an fcs_zero interview is
  kept, same as any other, as long as it clears every other criterion.
  Existing tracker rows that had `deletion_reason=fcs_zero` were bulk-
  recovered (`recovery_type=false_positive`) the same night so they
  stopped being excluded from Achieved retroactively too. Verified
  2026-09-11 (re-checked in response to a direct question about whether
  this needed building) — confirmed this decision, not a missed check,
  after searching the whole `cleaning/real/`/`reports/partner_data_
  recovery/` tree turned up no other fcs_zero deletion logic anywhere.
  Still genuinely unbuilt, separately: the actual "blank the FCS survey
  module's fields" mechanism this decision implies — see
  `_working_files/master_deletion_log_design.md` for the open item, this
  is data-cleaning work, not tracker/deletion logic, and needs its own
  build.
- `cleaning/real/audit_duration.R` / `audit_missingness.R` — the two reasons
  needing a real recompute rather than just reading an existing column: both
  reuse the SAME `cleaningtools` functions the DO's own pipeline uses
  (`create_duration_from_audit_sum_all()`; `add_percentage_missing()` +
  `check_percentage_missing()`, strongness_factor=8 — a statistical-outlier
  flag, NOT a literal cutoff), run independently against 2_monitoring's own
  reads of `audit.zip` / the raw anonymised export + the DO's kobo tool
  XLSForm (all read-only resources inside `cleaning/MSNA_Data_Cleaning/`).
- `duplicate_point` is independently rebuilt for its KEY-BASED half only
  (reuses `real_submissions.csv`'s own `is_duplicate`/`dup_key` — the same
  identifier logic as the DO's `check_duplicate_cluster_visits()` check #1,
  `gps_cluster_checks.R`). GPS-proximity matching (that function's checks
  #2/#3) is DELIBERATELY not built: 2_monitoring's own anonymised export
  carries no raw GPS coordinates for the vast majority of rows, and the DO's
  own pipeline already excludes GPS-proximity from automatic deletion for a
  documented reason (`Ak_data_cleaning_msna.R:730-742` — ~91% of flagged
  pairs in a spot-checked file were legitimate distinct IDP households
  sitting close together, not real duplicates). Revisit only if a real
  raw-GPS source becomes available — see that file's own header for the
  full reasoning.
- `missing_hh_listing` vs `listing_missing` — a cluster with ZERO Household
  Listing submissions at all is a CLUSTER-LEVEL process gap (no single
  interview from it is individually at fault), so it registers as
  `issue_type="missing_hh_listing"` (cluster-keyed, `uuid=NA`, zero Achieved
  impact — `deletion_status` joins by uuid, so a `uuid=NA` row structurally
  can never exclude any interview) rather than
  `confirmed_deletion`/`listing_missing` (interview-level, Achieved-
  impacting). There is no current check anywhere (ours or the DO's) for
  "cluster HAS a listing but this interview's household number isn't among
  the drawn set" — that would be the DO's own L4 check
  (`listing_link_checks.R`), REMOVED 20 Aug 2026 — so every
  `listing_missing`-flavored flag, historical or current, has only ever
  meant "zero listing for the whole cluster." A small number of historical
  rows (flagged when their cluster genuinely had no listing, which has
  SINCE been submitted) are left as plain `listing_missing`, appeal-eligible
  — the cluster-level gap closed, but nothing currently verifies the
  specific interview's household number against the now-existing listing,
  so they stay in the normal per-interview flow rather than being silently
  resolved or converted.
- `register_deletion_log_issues.R` (the DO-log-reading script) — **retired
  2026-09-11**, moved to `reports/partner_data_recovery/scripts/_archive/
  2026-09-11_do_log_ingestion_retired/`. By this date it had already been
  dropping all six reasons from its own ingestion at read-time (to avoid
  two mechanisms ever disagreeing about the same reason), leaving its
  daily-ingestion path a structural no-op; its one remaining live job — a
  one-time legacy `CONFIRMED_QUALITY_EXCLUSIONS.csv` bridge — was verified
  fully executed (all 578 legacy uuids already in the tracker) before
  archiving. `deploy_dashboard.R` no longer sources it. Kept in the
  archive folder, not deleted, in case this ever needs reviving.

## The review-queue engine (2026-09-08 rebuild)

Every decision point in the deletion-recovery and accessibility pipelines
now follows one shape: classify against established rules → rule-confident
items auto-apply → anything needing a human judgment call gets grouped and
staged → presented to Jack in chat (not a workbook, not a dashboard — his
explicit preference, matches how this was already actually being worked) →
his decisions get applied in bulk with a durable audit trail → rejected
items route to the next outgoing round.

**To run a deletion review session:**
```r
source("reports/partner_data_recovery/scripts/generate_review_queue.R")
generate_review_queue()  # writes reports/partner_data_recovery/outputs/_review_queue/<date>.json
```
Read that JSON, present it partner-by-partner: the `confirmed` section is
informational only (already auto-applied, rule-confident), the
`needs_review.groups` section is what to walk through with Jack — each group
is already collapsed by (issue_type, deletion_reason) within a partner (e.g.
tested 2026-09-08 against the live tracker: 994 individual pending items
collapsed to 34 groups across 18 partners). **Only ever print the group
summary fields to Jack (`issue_type`, `deletion_reason`, `n`,
`example_notes`, `rounds_outstanding_max`)** — never the raw `uuids`/
`issue_ids` arrays into the conversation; those exist in the file purely for
the apply step below to act on. At the end of each partner, ask Jack
directly whether any rejected items warrant an immediate follow-up email or
just go into the next scheduled round — don't guess at a severity threshold,
that's explicitly his call each time, not a rule to encode.

**To apply Jack's decisions:**
```r
source("reports/partner_data_recovery/scripts/apply_review_decisions.R")
apply_review_decisions(list(
  list(issue_ids = <a group's own issue_ids field>, new_status = "confirmed",
       resolution = "<what Jack actually said>", confirmed_by = "internal_team"),
  # ... one entry per group Jack decided on
))
```
`new_status` is the tracker's own real vocabulary (`confirmed`/`rejected`/
`contested`) — this function doesn't offer a simplified approve/reject
mapping, because "reject" can mean either "deletion confirmed, appeal
denied" or "recovered, false positive" depending on `recovery_type`, and
that's Jack's distinction to make in the conversation, not something to
infer. Always apply a whole group at once, matching how it was presented,
unless Jack explicitly splits one. Every applied decision is logged to
`reports/partner_data_recovery/outputs/_review_decisions_log/<date>.log`,
append-only — a chat-based decision is exactly as auditable as a
workbook-based one.

The accessibility-side generator (`1_sampling/resampling/scripts/
generate_review_queue_accessibility.py`) produces the same JSON shape from
`analysis_review_returned_reports.py`'s existing QA findings (partial
answers, contradictions, missing/extra ward coverage). No accessibility
"apply" step exists yet — accessibility rules 1/2 apply directly at ingest
(not staged for review, since neither is a judgment call; see 1_sampling's
CLAUDE.md), so what needs review there is QA findings to fix in the
partner's file before re-ingesting, not a tracker row to resolve.

## `assert_fresh()` — freshness enforcement (2026-09-08 rebuild)

`scripts/shared/assert_fresh.R` (identical copy in 1_sampling's
`scripts/shared/`) — checks an artifact's real, current mtime/hash against
its source, live, every time (never trusts a `_*_version.txt` stamp file as
ground truth — those can themselves go stale, found exactly this during the
2026-09-07 incident review). Two modes: `"auto"` (safe, deterministic
regenerate/copy, runs automatically) or `"stop"` (judgment-sensitive or
explicitly not-casual-to-rerun, blocks with the exact fix command, never
runs anything itself). See 1_sampling/CLAUDE.md's rebuild section for the
full classification of which artifacts are which.

`scripts/shared/bundle_dashboard_mirrors.R` — the `data`/`input_data` →
`dashboard_app/data`/`dashboard_app/input_data` copy, extracted from
`deploy_dashboard.R` so it can run standalone (assert_fresh-safe) instead of
only as a side effect of a full deploy. **Known sync gap, found live
2026-09-08**: this mirror was 3 sampling-frame versions stale (still v5
while canonical was v6) because nothing had triggered a full deploy since —
fixed for that specific staleness and `global.R`'s frame reads made
version-agnostic (`latest_frame_file()`, finds the current version
dynamically instead of a hardcoded number), but re-run
`bundle_dashboard_mirrors(".")` before trusting a local `dashboard_app/`
session reflects current data, same as any other mirror in this rebuild.

## Sampling-frame versioning & archiving

Not this repo's own frame (1_sampling owns that — see its CLAUDE.md for the
version-bump/archive discipline), but the same discipline applies to
anything this repo generates ad hoc backup copies of before an in-place fix:
archive immediately to a dated `_archive/<date>_<reason>/` folder, don't
leave a `*_PRE_*_backup*` file sitting at top level "for now."

## Partner packages — two-tier refresh (2026-09-08 rebuild)

Lives in 1_sampling (`scripts/field_guide_production/
refresh_partner_workbooks_daily.py` for the daily/auto tier,
`build_partner_dc_packages.py` for the resampling-push tier — see that
repo's CLAUDE.md, "Update 2026-09-08b", for the full design and test
results), but reads this repo's canonical `data/real_submissions.csv`
directly, so noted here too: run `refresh_partner_workbooks_daily.py`
*after* this repo's own daily submission refresh, not before, or achieved
status in the partner workbooks will lag by a day.
