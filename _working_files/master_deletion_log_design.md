# Master deletion/exclusion log — design proposal

Status: PROPOSAL, not built, not approved. For Jack's morning review.
Written by Coordinator overnight 2026-09-10/11, after the session mix-up
and the resulting audit/reconciliation work with Monitoring.

## Where this actually stands after tonight

The original ask (2026-09-10) was to design one unified master log
replacing the tracker → two-overlay-CSV → deletion_status chain, so
is_achieved() collapses to one clean filter. Tonight's independent-checks
build got most of the way there in substance without building that literal
architecture — five of six DO reasons (soon six, with no_consent's
auto-confirm now added) already funnel through the SAME shared mechanism
(issue_tracker.R's register_issues()/recovery_issue_tracker.csv), which is
real, substantive progress. What's still true: the tracker still filters
down through build_confirmed_deletions_overlay.R into two separate overlay
CSVs, and real_submissions.csv/global.R still key off a single mirrored
deletion_status column rather than querying the tracker directly.

**Revised recommendation, given what's already working:** don't replace the
tracker. Its schema is already close to right (issue_id, issue_type,
deletion_reason, org_id, cluster_id, strata_id, uuid, listing_number,
status, detected_date, first_batch_date, last_batch_date,
rounds_outstanding, resolution, resolution_date, confirmed_by,
recovery_type, notes). The actual gaps are: (1) no explicit disposition
field — what happens to the data isn't a column, it's inferred from
issue_type + status, which is why fcs_zero needed special-casing everywhere
it's touched; (2) two reason types still missing entirely (date_outlier,
crs_unmatched); (3) the two-overlay step downstream is more machinery than
the two genuinely-different audiences (dashboard-provisional vs
resampling-confirmed-only) actually need.

## Proposed schema addition: one new column

Add `disposition` to recovery_issue_tracker.csv, set once at registration,
alongside deletion_reason. Four values cover every case decided so far:

| disposition | meaning | current issue_types |
|---|---|---|
| `remove` | settled = excluded from achieved, unsettled = achieved (existing pending-counts-as-achieved rule, unchanged) | no_consent, duration_under_20, duplicate_point, listing_missing, pct_missing_flagged, gps_proximity (not built), date_outlier (not built), crs_unmatched (not built) |
| `blank_section` | interview kept, one survey module blanked, never excluded | fcs_zero |
| `no_impact` | visible/tracked, never gates any individual submission's achieved status | missing_hh_listing |
| `keep` | not an appeal, a roster/geography fact, always achieved | accessibility_reclassification (fast-follow, not tonight) |

**CORRECTED 2026-09-11 after Monitoring's technical review caught a real bug
in the first draft below** — the original version of this section proposed
gating `is_achieved()` on `status %in% TERMINAL_STATUSES`, which is wrong:
today's actual policy (global.R, `deletion_status` sourced from
FLAGGED_DELETIONS_OVERLAY.csv, which excludes on `recovery_type` only, no
status filter at all) excludes on the MERE EXISTENCE of an open-or-settled
flag, any status, not just settled ones — the deliberate "pessimistic
dashboard" incentive CLAUDE.md documents. Applying the settled-only
condition to is_achieved() would have silently promoted every currently-
pending disposition=remove row (1,100+ from duplicate_point alone) into
Achieved. Also missing from both formulas below in the original draft:
`recovery_type` — 46 live rows (11 duplicate_point, 35 fcs_zero) are
recovered (recovery_type=false_positive) and must never gate anything.

Corrected:

- **`is_achieved()`**: completed, matched, and NO tracker row exists for
  this uuid (or its cluster, for no_impact/keep types) with
  `disposition == "remove" AND is.na(recovery_type)` — any status counts
  (pending/sent/rejected/confirmed/contested all exclude), matching today's
  pessimistic-incentive policy exactly.
- **`is_confirmed_deletion()`**: same guard, PLUS `status %in%
  TERMINAL_STATUSES` specifically. This is a strict subset of the
  is_achieved()-exclusion set by construction (same disposition/
  recovery_type condition, with the settled requirement added on top),
  which is what keeps the Collected = Achieved + Confirmed + Pending
  identity well-defined as a non-negative residual — Confirmed can never
  exceed the achieved-exclusion set.

Net effect versus today: same three separately-maintained conditions become
one shared guard clause (disposition + recovery_type) with a status check
layered on top only for the confirmed-specific function — genuinely fewer
places the policy can drift out of sync, not a policy change.

The two-overlay step (build_confirmed_deletions_overlay.R) can collapse to
one function with a `settled_only` parameter instead of two separate CSV
outputs — same two audiences (dashboard-provisional reads settled_only =
FALSE, resampling reads settled_only = TRUE), one code path instead of two
near-duplicate ones. Lower priority than the disposition column itself;
worth doing when someone's next in that file anyway, not urgent on its own.

## What's still genuinely unbuilt (not a design gap, an implementation gap)

- **date_outlier**: currently silently dropped in prep_real_submissions.R
  before ever reaching real_submissions.csv or the tracker — no row, no
  appeal path, worse than a no-appeal deletion. Needs: a
  run_independent_date_outlier_check() alongside the existing five,
  registering disposition=remove, appeal-eligible (same treatment as
  listing_missing, per Jack's decision). The rows currently being dropped
  in prep_real_submissions.R would need to flow through instead of being
  filtered out of the output entirely.
- **crs_unmatched**: no check exists. Needs a
  run_independent_unmatched_check() flagging is.na(matched_survey_id) rows,
  disposition=remove, appeal-eligible, same treatment as listing_missing.
  CRS's 27 (Plateau/Bassa, pop_type entirely NA) plus the IDP-side pattern
  Monitoring found (SCI 26, INTERSOS 7, SI 3) both fall under this.
- **fcs_zero's actual blanking mechanism**: confirmed by tonight's review to
  not exist anywhere in the codebase. The deletion-avoidance half is done
  (no longer excludes from achieved), but nothing currently blanks the FCS
  survey fields themselves. This is data-cleaning work, not tracker logic —
  needs deciding where it runs (2_monitoring's own post-processing of the
  anonymised export, most likely, since it's about response content not
  achieved-status logic) and needs building from scratch.
- **gps_proximity**: deliberately not rebuilt (2_monitoring's own export
  lacks raw GPS for most rows; the DO's own version had a 91% false-positive
  rate). Monitoring's recommendation, not yet Jack-confirmed: leave out
  permanently rather than build our own version.
- **accessibility_reclassification**: the original opening ask (data from
  areas that go inaccessible should still count). Real, agreed direction,
  explicitly scoped as a fast-follow needing 1_sampling coordination — not
  part of this design's immediate scope.

## Recovery workbook cycle — Jack's explicit state-machine requirement (2026-09-11)

Jack's own description, verified against the actual current code rather than
taken at face value: build a workbook → send to partners → process feedback
→ **accept** (partner's response is trusted, resolution recorded as either
delete or keep, both are settled outcomes) or **reject/blank** (nothing
trusted yet, stays pending, no distinction between an explicit rejection and
silence) → next outgoing workbook = only the still-unresolved rows, plus any
newly-flagged items → repeat. Both the tracker and the workbook themselves
need to make it obvious at a glance what stage every item is at.

Checked directly against generate_review_queue.R and apply_returned_response.R:

- **Reject/blank correctly stays actionable today, already.**
  generate_review_queue()'s own split is `confirmed = status %in%
  TERMINAL_STATUSES` vs `needs_review = everything else` — and
  `TERMINAL_STATUSES <- c("confirmed", "contested")` does NOT include
  "rejected." So a rejected or blank row is already grouped with pending/sent
  as still needing review, not silently treated as resolved. This already
  matches what Jack described — worth confirming explicitly with him it's
  doing what he wants, since it's easy to assume this needed building when
  it's actually already correct.
- **Never overwriting a partner's actual response is already a first-class
  design property, not something to newly enforce.** apply_returned_response.R's
  own header states the RETURNED file a partner sends back is "never
  modified — it stays the untouched, literal record of what the partner
  sent back"; only a separate MASTER copy in outputs/<Partner>/ gets
  written to, matched by uuid not row position specifically so a
  partner's own file can never be silently overwritten by a later refresh.
  recovery_issue_tracker.csv is the separate audit trail for any row that
  needed an actual reviewer decision. Confirmed this is a deliberate,
  already-built safeguard — Jack's caution is already architecturally
  enforced, not a new requirement.
- **NOT yet directly verified: the actual "next workbook = only unresolved +
  new" generation step.** Read generate_review_queue.R (the staging/grouping
  half) and apply_returned_response.R (the accumulate-into-master half) in
  full — neither is the script that builds a fresh OUTGOING workbook file
  for the next round. That script (if it exists as its own piece, or if
  this logic lives inside a wider daily-refresh script not yet located)
  needs finding and confirming before this can be called fully verified.
  Flagging honestly rather than assuming it's there.

## Recovery workbook implications

Two new sheets needed once the above checks exist: a "Date Outlier" sheet
(partner confirms/corrects the submission date, or the deletion stands) and
an "Unmatched" sheet (partner supplies the correct sample-point/listing
identity, or the deletion stands) — both mirroring the existing appeal
pattern (review_recovery_response.py / verify_data_recovery_response.py /
apply_returned_response.R) already used for GPS Duplicates, IDP Listing
Duplicates, and Missing HH Listings sheets. The missing_hh_listing sheet
itself already exists and already has workbook-side handling
(review_missing_hh_listings() in review_recovery_response.py) — just needed
feeding the right issue_type, which Monitoring's 780/62 conversion tonight
now does.

## Suggested build order, once approved

1. Add the `disposition` column to the tracker schema (issue_tracker.R),
   backfill it for every existing row from today's issue_type (mechanical,
   no judgment calls — the mapping table above is exhaustive for every
   issue_type currently in the tracker).
2. Rewrite is_achieved()/is_confirmed_deletion() to read disposition
   directly (dashboard_app/global.R) — should be a small, surgical change
   given the underlying logic doesn't actually change, just its expression.
3. Build the two missing checks (date_outlier, crs_unmatched) and their two
   workbook sheets.
4. Build the fcs_zero blanking mechanism (separate track — cleaning-side,
   not tracker-side).
5. Collapse the two-overlay step to one parameterized function (cleanup,
   not urgent).

None of this should happen without Jack's sign-off on the schema above
first — same standing rule as everything else tonight.
