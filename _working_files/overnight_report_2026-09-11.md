# Overnight report — 2026-09-11

Everything below happened after you went to sleep. Nothing was deployed —
Monitoring and I both held to that instruction all night. Nothing here was
acted on beyond what's explicitly marked done; everything else is
recommendation, waiting on you.

## What actually got built/fixed tonight (with your sign-off already, or safe/reversible)

- **Git checkpoint**: commit `5ddae2f` — this is MY commit, made while
  executing the plan you'd already approved, not something you did
  yourself (Monitoring briefly mis-attributed this to you; corrected).
  Covers dashboard_app/, deploy_dashboard.R, CLAUDE.md, scripts/,
  redeploy.ps1. `cleaning/` and `reports/` — where the actual deletion
  logic lives — stay permanently outside git by the repo's existing
  design; that's not new tonight, but worth remembering this commit is a
  partial safety net, not a full one.
- **Master deletion log design** (`_working_files/master_deletion_log_design.md`):
  full proposal written, reviewed by Monitoring, and one real bug they
  caught got fixed before it went anywhere near code — my first draft
  would have silently promoted 1,100+ still-disputed duplicate rows into
  Achieved by using the wrong status condition. Corrected version is in
  the doc now. Not built, needs your sign-off on the schema.
- **Recovery workbook cycle** verified against actual code, not assumed:
  your described state machine (accept → settled, reject/blank → stays
  actionable, never overwrite a partner's actual returned file) is
  already correctly built today. Found the next-round outgoing-workbook
  builder too (`run_full_batch.R` → `build_partner_package()`).
- **Real bug found and fixed**: `full_batch_pipeline.R`'s Missing HH
  Listings sheet was still reading the old per-interview `listing_missing`
  field and had no path to the new cluster-level `missing_hh_listing`
  type — if run for a real partner round, it would have shown the 113
  already-resolved stale rows and silently missed all 62 real current
  gaps. Fixed and verified against real data (e.g. malteser: 3 clusters,
  31 households). Never actually ran for a real partner, so nothing
  shipped wrong.
- **Row-count mystery from your pushback**: fully resolved, not a bug. The
  09-09 file landed late that day; my first count predated a pipeline run
  picking it up, later counts postdate it. File-size ratio matches the
  row-count ratio almost exactly.

## Dashboard functional audit — 3 real bugs found

1. **mod_home.R's "Collected" figure can visibly break its own displayed
   identity.** The page states "Collected always equals Achieved +
   Confirmed Deleted + Pending Deletion, exactly," and three of the four
   numbers are sourced correctly, but Collected itself is computed
   differently (a raw sum over all submissions, not the same
   roster-scoped source as the other three). Any completed interview
   whose cluster has since been retired by resampling — which happens
   routinely on this project — would inflate Collected while being
   invisible to the other three numbers, breaking the arithmetic on the
   page that promises it never breaks. Same fix pattern as an existing
   2026-08-25 fix for Achieved, just never applied to Collected.
2. **mod_integrity.R's "Implausible daily counts" check counts refusals as
   if they were completed interviews.** Its own label says "completed
   interviews only," but the actual filter never excludes consent
   refusals — an enumerator-day mixing quick refusals with a normal
   completed workload can trip the threshold without ever exceeding a
   plausible number of real interviews.
3. **A zero-denominator gap in the partner report.** The live dashboard
   tile and the Excel export compute percent-achieved with no guard
   against a partner having zero current target; the PDF export
   correctly guards the same calculation. A partner in that state would
   see a broken number on two of three surfaces and a correct one on the
   third.

Also found: a cluster of copy-pasted stale tooltip text across 4-5 files
(fcs_zero still described as an active exclusion reason in the most
partner-visible export; the missing-HH-listing reason still described as
uuid-level when it's now cluster-level; a "narrower settled-only" phrase
that describes the relationship backwards); two spots where a file
hand-rolls "completed" instead of calling the canonical function
(currently harmless, silent drift risk if that definition ever changes);
and a real test-coverage gap — `smoke_test.R` has zero assertions on the
new Collected=Achieved+Confirmed+Pending identity at all, so nothing would
catch a future regression, including the mod_home.R bug above.

Full list of improvement ideas (Coverage Map badge tied to the exact
condition that needs it, Confirmed/Pending columns added to the partner
digest, a sidebar filter for deletion status, etc.) is in the workflow's
own output if you want the detail — happy to expand any of these into a
real writeup once you've picked which ones you want.

## Workspace audit — top priority, read these first

1. **Two DO-facing prep scripts would fail if run today**:
   `cleaning/prep/prep_admin3_wards.R` and
   `prep_partner_lga_assignment.R` still hardcode a path to the v5
   sampling frame, which no longer exists — the same bug already fixed
   in 4 other files this week after it once broke deploy_dashboard.R's
   first step.
2. **A stale verification cache with 9 partners pending**:
   `idp_real_listing_pools.csv` is 3 days stale against its source. The
   next verification run for any of DRC/FACT/INTERSOS/MALTESER/MDM/NRC/
   PLAN/SCI/SI would silently check against outdated data.
3. **The deploy mirror is 2 days behind tonight's redesign** —
   `dashboard_app/data/` still shows 667 confirmed-deletion rows against
   907 in the real data. `bundle_dashboard_mirrors.R` needs a re-run
   before any future push, which is normal pre-deploy process, just
   flagging given how much changed tonight specifically.
4. Same test-coverage gap as above, independently found by this audit too.

## Housekeeping — safe to archive, low stakes, your call on timing

Several genuinely dead, zero-reference files and folders (all gitignored,
so archiving costs nothing to reverse): `cleaning/combined_deletion_log.rds`
and `cleaning/real/handoff_for_resampling/` (superseded by the current
overlay system), a handful of dated `.bak` files from the 2026-09-06
migration (~12MB combined, one set is also riding uselessly into every
deploy bundle), an old non-edge-matched boundary shapefile, `__pycache__`,
a couple of stale documentation comments pointing at scripts that got
renamed. None of this is urgent. Full list with exact paths in the
workflow's own output if you want to action it directly rather than via a
conversation.

## Needs your judgment specifically, not a mechanical call

- `input_data/sampling_frame/_archive_*` — the biggest disk item found
  (~525MB, 10 folders in 12 days). This is your own deliberate archiving
  mechanism, not junk, but nobody's confirmed whether 1_sampling holds an
  independent copy of the same history. Retention-policy question, not a
  cleanup one.
- Two open questions in `QUESTIONS_FOR_DATA_OFFICER.md` logged since early
  September with nothing in "Resolved" — can't tell if they were answered
  outside the repo and never logged back, or are genuinely still open.
- A handful of DO-owned things worth raising with the Data Officer
  directly, not ours to touch: ~2.25GB of their own unread daily
  snapshots, a 945MB unreferenced raw-export folder with no consuming
  code, a quality-report tool run exactly once despite its own README
  saying to run it periodically, and a sampling-frame reference file
  three versions stale feeding what field teams see as household-count
  context.

## Coordination with Monitoring

Held the no-deploy line all night, confirmed multiple times. They fixed
their own documentation bug in CLAUDE.md, closed out the three items you
approved directly with them (no_consent auto-confirm, the 10 orphaned
duplicate rows, the corrected 780/62 listing_missing conversion — all
verified, reconciliation holds exactly: 16,813 = 13,740 + 868 + 2,205).
They're aware of everything above and didn't duplicate any of it.

## What's still genuinely open, not started

date_outlier and CRS's unmatched submissions still have no independent
check built. fcs_zero's actual "blank the FCS section" mechanism doesn't
exist anywhere in the codebase — only the "stop excluding from achieved"
half is done. The Coverage Map's confirmed-vs-pending visual is
deliberately left for your own design call. None of this needs deciding
right now — just the honest state of things.
