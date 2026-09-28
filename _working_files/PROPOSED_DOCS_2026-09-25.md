# PROPOSED documentation text — 2026-09-25 — NOT APPLIED

**Status:** proposal only. Nothing in this file has been copied into `2_monitoring/CLAUDE.md` or
`3_analysis/README.md`; both are Jack's files and stay untouched until he says yes.
**How to use:** each block below is headed with the file it would go in, where it would go, and an
**`apply when:`** condition — the point at which the text becomes true of the *deployed* system, not just of the
working tree. Apply a block only once its condition holds, and re-check the figures marked `[verify]` first.
**Written by:** the Dashboard session (2_monitoring), from the code and data as of 2026-09-25 afternoon.

Five mechanisms (Coordinator's list), then a short list of things worth recording that were not asked for.

| # | Mechanism | Working-tree state 2026-09-25 | apply when |
|---|---|---|---|
| 1 | Coverage completeness: UNASSIGNED / UNRESOLVED + `config/coverage_decisions.csv` | built, tested; record seeded 2026-09-25 and Marte decided (60 rows; 323 LGAs OK, 0 UNASSIGNED, 0 UNRESOLVED) | the dashboard change is deployed |
| 2 | Partner registry (zero-LGA partners) | built, tested | ACF -> ZOA is executed (Resampling side) AND the dashboard change is deployed |
| 3 | Live-claimant duplicate rule | built, tested; change (4) APPLIED to the working-tree data 2026-09-25 (304 rows, Jack's decision D option 1) | a prep run with the rule is deployed |
| 4 | Export guard + date reconstruction (+ readxl guard) | built, tested; reconstruction never fired on real data; `BLANK_DATE_EXPORT_POLICY` default now `"reconstruct"` (Jack, decision I) | the guard is deployed (the reconstruction paragraph no longer waits on a policy call) |
| 5 | Option C attribution (whole-LGA credit, collector-only pace) | built, verified against all 19 partners | the dashboard + recovery pipeline change is deployed |

---

# PART A — `2_monitoring/CLAUDE.md`

Suggested placement: new `##` sections after "Collected/Achieved/Confirmed Deletion/Pending Deletion —
reconciliation model" and before "Independent deletion checks", except A4 which belongs next to the
existing `assert_fresh()` section.

## A1. Coverage completeness — UNASSIGNED / UNRESOLVED   *(apply when: dashboard change deployed; record seeded and Marte decided 2026-09-25)*

```markdown
## Coverage completeness — UNASSIGNED / UNRESOLVED (2026-09-25)

Jack's rule: any LGA or point without a partner is flagged for immediate resolution, never shown as a quiet
label. The dashboard's old catch-all org `other` ("Other / unassigned") and the bare "Not partner-assigned"
label are gone. `scripts/shared/coverage_state.R` classifies every LGA from the strata-level FULL frame +
`partner_lga_assignment.csv` + `config/coverage_decisions.csv`:

- **UNASSIGNED** — the frame says the LGA is covered (>= 1 covered stratum) but no partner owns it: no row in
  `partner_lga_assignment.csv`, or a covered stratum whose `partners_covering` is blank. An error state.
- **UNRESOLVED** — the frame says the LGA (or a stratum of it) is `not_covered` and there is NO valid decision
  for it in `config/coverage_decisions.csv`.
- An LGA whose every stratum is `excluded` is NOT flagged: the frame's own `exclusion_reason` already is the
  documented decision (shown as "Excluded (was: X)").

**The decision record** `config/coverage_decisions.csv` is hand-maintained and version-controlled (NOT
gitignored, unlike `input_data/` and `data/`; `[verify: committed by the time this is applied]`). Columns: `scope` (`state`|`lga`), `pcode`, `name`, `decision`, `decided_by`,
`decision_date`, `note`. The only decision value that clears anything is `accepted_not_covered` ("assign a
partner" is a frame/Partnerscoverage change that makes the LGA covered; a deferral must not clear the flag). A
malformed row clears nothing and is reported by the validity check. A state row covers every `not_covered` LGA
of that state; an LGA row covers only itself. Seed with `scripts/shared/seed_coverage_decisions.R`
(`preview_...` is read-only; `apply_...` needs `confirm = TRUE` and a named `decided_by`, and only seeds an
EMPTY record; undo = restore the header-only file, or `git checkout` it once committed).

**State on 2026-09-25** `[verify]`: 147 not-covered LGAs = whole states Kano 44 / Niger 25 / Kogi 21, 56 LGAs in
the partially covered states Benue 17 / Kaduna 21 / Nasarawa 6 / Plateau 12, and Marte (Borno) — the only one
that needed an actual decision. The other 146 were recorded as accepted at Jack's word on 2026-09-25 (3 state rows
covering Kano/Kogi/Niger = 90 LGAs + 56 LGA rows; Kano keeps its real 2026-07-30 date). **Marte was decided the same
day (Jack, decision B, "option 2; excluded due to insecurity-related inaccessibility")**: one `lga` row, `NG008022`,
`accepted_not_covered`, decided_by Jack Philpott, 2026-09-25, note "Excluded due to insecurity-related
inaccessibility ... No partner was ever assigned; earlier label partner_coverage_declined is an automatic default,
not a decision." The record is 60 rows; the state is 323 LGAs OK / 0 UNASSIGNED / 0 UNRESOLVED and Marte reads "Not
covered (decision on record)". If Resampling later changes Marte's frame label, `refresh_coverage_state()` must be re-run
`[verify at apply time]`. Kano's exclusion is documented
in 1_sampling/CLAUDE.md (user, 2026-07-30: "Kano is a completely excluded state, no partner is wanting to cover
it"); for the rest, `partner_coverage_declined` is the design script's DEFAULT label for an LGA with no partner
marker in `Partnerscoverage.xlsx` (analysis_partner_coverage.py), not a recorded choice `[Coordinator's Marte info
pack, 2026-09-25 - re-verify before applying]`.

**Where it shows:** `input_data/partner_coverage/coverage_state_by_lga.csv` (regenerated by
`refresh_coverage_state()` from `prep_partner_lga_assignment.R` and `deploy_dashboard.R`, so a frame change is
caught at deploy time, not only when the assignment prep is re-run; a banner prints and `SANITY_WARNINGS` gets an
entry only when the flagged set CHANGES; `STRICT_UNASSIGNED=1` makes it stop instead). Dashboard: red Home alert,
always-on map overlay (UNASSIGNED = dashed red outline; UNRESOLVED = red fill once the record is seeded; until then
Home shows one line with the count), `partner_coverage_label()` names every case. In `filter_base` a covered
stratum with no partner is org `unassigned` and a dropped stratum of an excluded LGA is org `excluded`
(neutral); `NON_PARTNER_ORG_IDS` is what every "drop the non-partners" filter uses now.
**Validity:** `validity_checks/modules/coverage_assignment_complete.R` recomputes the state independently from
1_sampling's FULL frame and FAILs on any UNASSIGNED/UNRESOLVED, an invalid decision row, an unregistered collector
or a stale state/registry file.
```

## A2. Partner registry — partners who hold no LGA   *(apply when: ACF -> ZOA executed + dashboard change deployed)*

```markdown
## Partner registry — partners with no LGA (2026-09-25)

Every partner list here used to be derived from `partner_lga_assignment.csv`, so a partner whose LGAs were all
reassigned (ACF -> ZOA, five Sokoto LGAs) simply vanished: no row in the partner table or charts, absent from the
sidebar partner filter (whose "everything selected" default then dropped its submissions from every filtered
view, including the LGAs' NEW owner's totals), no Partner Report, no recovery workbook or email (its own
collector-routed follow-up items orphaned), and prep flagged every one of its interviews "UNKNOWN ORG_ID".

**Registry = the assignment's partners UNION `config/partner_registry.csv`** (version-controlled, hand-kept; today
one row, `acf`). `scripts/shared/partner_registry.R`: `read_partner_registry()` -> `org_id`, `n_lgas`,
`in_assignment`, `in_config`; `refresh_partner_registry()` writes the copy the deployed app reads
(`input_data/partner_coverage/partner_registry.csv`, since the app cannot see `config/`), called next to
`refresh_coverage_state()`. Consumers: prep's `known_org_ids`, `run_full_batch.R`'s partner list, the dashboard.
In `global.R`, `PARTNERS_ASSIGNED` = partners holding >= 1 LGA, `PARTNERS_NO_LGAS` = registered partners holding
none; the registry also unions any labelled collector that has submitted, so a collector can never silently
drop out of a filtered view. A no-LGA partner is always offered in the partner filter, gets the status
**"No LGAs assigned"** (never "Complete"), is left off both partner charts (nothing to plot), stays in the partner
table (its row shows its OWN Collected / Achieved / Confirmed / Pending counts, with target, credited and still
needed at 0 - decisions F + L, 2026-09-25; the old "Collected outside assigned LGAs" column is hidden), and its
Partner Report says so and lists what it
collected by LGA and who owns each now. Its recovery email uses a headline with no target, percentage or "still
needed" figure (`pkg$no_lgas`); its follow-up sheets are unchanged because they are routed by COLLECTOR (`org_id`),
not by LGA owner. A registered partner with no LGA, no interviews and no tracker rows is skipped by the batch.
To register a partner: add a row to `config/partner_registry.csv` and re-run the refresh.
```

## A3. Live-claimant duplicate rule   *(apply when: prep with the rule deployed; change (4) decided and applied 2026-09-25)*

```markdown
## Duplicate flag — the live-claimant rule (2026-09-25)

`is_duplicate` marks a row that is not the first to claim its key (a non-IDP point id, or an IDP cluster +
listing/walk slot). It used to count every earlier row, even one later settled-deleted (almost always
`duration_under_20`) or never a completed interview, so the valid re-collection was flagged `duplicate_point` and
sent to the partner: 274 rows on the 09-23 build (304 on the 09-25 build) `[verify]`.

**Rule** (`scripts/shared/live_claims.R`, `apply_live_claim_rule()`, called by `prep_real_submissions.R` and, from
the CSV, by `refresh_deletion_columns.R`): a claimant is LIVE when it is a completed interview that is not a settled
(confirmed/contested, not recovered) deletion. Within a claim key the first LIVE claimant is not a duplicate,
whatever came before it; everything else keeps the flag it had, in particular a settled-deleted duplicate stays
`is_duplicate = TRUE` so counts that exclude duplicates are not inflated by rows deleted anyway. "First" =
earliest `uploaded_at` (the same key prep has always used, so an existing group's canonical claimant never
changes); rows with no upload time (reconstructed dates) sort AFTER every exact one, then by `start_datetime`.
Do NOT order by the audit form-start globally: it would change the canonical claimant in 251 of 1,604 claim groups.
New column `n_live_claims` (live claimants sharing the row's key). **Achieved is unaffected**: since 2026-09-11
`is_achieved()` never reads `is_duplicate`. `independent_deletion_checks.R`'s duplicate check uses the same
settled set and rule.

**Tracker side (change (4)) — APPLIED 2026-09-25 (Jack, decision D "option 1", relayed verbatim by Coordinator):**
pending `duplicate_point` tracker rows for interviews the rule clears were stale.
`reports/partner_data_recovery/scripts/resolve_live_claimant_duplicates.R` resolved them in one bulk call as
`confirmed` + `recovery_type = false_positive` + `confirmed_by = internal_team` (the 2026-09-10 fcs_zero precedent):
snapshot first, `restore_...()` undoes it, refuses without `confirm = TRUE`. 304 of 1,895 pending rows on the 09-25
data (281 with no other live claimant + 23 first-of-several; 1,591 pending remain; the 34 later live claimants in those
23 groups stay flagged). Then only `build_confirmed_deletions_overlay.R` + `refresh_deletion_columns()` were re-run
(NOT the independent checks). Achieved was identical before/after (24,133 file-level; every org and every matched
stratum) and the CONFIRMED overlay (resampling basis) is byte-identical. Snapshot:
`reports/partner_data_recovery/outputs/_review_decisions_log/2026-09-25_live_claimant_dups_BEFORE.csv`; file-level
backup: `data/_archive/2026-09-25_pre_live_claimant_dup_clear/`. Rows conflicting with a LIVE claimant (e.g. IMC's six
Chibok/Damboa items) are real and are not touched. **CORRECTION (2026-09-25, later the same evening):** an earlier
draft of this paragraph, and the first report of decision D, said partners' review lists "drop these 304 at the next
recovery batch build". That was NOT true when written: `full_batch_pipeline.R` built every sheet from tracker rows
with no `recovery_type` filter, so all 350 recovered rows (these 304 + the 46 earlier ones) were still listed on the
partner workbooks (Non-IDP Duplicates 269, IDP Listing Duplicates 46, Confirmed Deletions 35). D's tracker, overlay,
`real_submissions.csv` and dashboard effects were always correct; the workbooks were not. It is true from the fix
described in Part C item 7 (fix A), which removes recovered rows from every partner sheet; until the next recovery
batch is built with that fix, no workbook or email carries it.
```

## A4. Export guard, date reconstruction, readxl guard   *(apply when: guard deployed; the reconstruct-default policy was decided 2026-09-25, decision I)*

```markdown
## Anonymised-export guard, date reconstruction and the readxl guard (2026-09-25)

**Incident.** The DO's 2026-09-24 export was overwritten with `start`, `end`, `today` and `_submission_time`
BLANK in all 26,222 rows (every other column intact). Nothing errored: prep wrote a `real_submissions.csv` with
every date NA, which would have shipped a dashboard where every partner reads "Not started". The DO reissued a
valid export on 2026-09-25.

**Guard** (`prep_real_submissions.R`, top): exports are tried newest-first; the first whose `start`/`end`/`today`
columns are populated in >= `EXPORT_MIN_DATE_SHARE` (0.5) of rows wins; a skipped export is announced in the
console AND a persistent `SANITY_WARNINGS` entry; if none passes, prep stops rather than write undated data.
`real_meta.rds$skipped_exports` records it.

**Reconstruction** (`scripts/shared/date_reconstruction.R`; built, tested in a sandbox, NEVER fired on real
data): if an export is accepted with blank dates, blank `start`/`end`/`today`/`_submission_time` are filled from the
previous build (exact, by uuid) and the KoBo `audit.zip` (start = form-start event + 1 h WAT; validated on 24,849
known rows: start within 1 s 98.4%, date exact 99.97%, end within 60 s ~90%; `uploaded_at` and sync lag are NOT
derivable). New columns `dates_source` (`export` | `carried_forward` | `audit_reconstructed` | `missing`) and
`dates_reconstructed`; a carried-forward row KEEPS its original source, so a reconstructed row can never turn
"exact". Policy constants: `ALLOW_DATE_RECONSTRUCTION` (TRUE; a no-op on a valid export) and
`BLANK_DATE_EXPORT_POLICY` (`"fallback"` = skip the blank export and use the newest valid one, staler but exact;
`"reconstruct"` = use the newest and reconstruct, fresher but partly approximate). **`"reconstruct"` is the default
(Jack, decision I, "option 2", 2026-09-25 — standing rule for the next blank-date export).** `"fallback"` remains the
LAST RESORT: reconstruction needs the KoBo audit logs (`DATE_RECON_AUDIT_ZIP`), and with none present a blank newest
export is still skipped in favour of the newest valid one. Every reconstructing run says so (console, sanity-warnings
banner, `real_meta$dates`, `dates_source` in `real_submissions.csv`), and a reconstructed row is never presented as
exact. The default was changed in code only; it did not fire on the valid 25 Sep export. On a valid export the
reconstruction path cannot fire (output byte-identical) and `dates_source` is `export` for every row.

**readxl guard.** readxl types a column from its first `guess_max` (5,000) rows; a column blank there is typed
logical and later TEXT values are dropped (with a warning) and later NUMERIC values become TRUE (with none). On
the 09-25 export that hit seven columns (22,635 values; incl. the per-state repair columns
`sample_point_NG026_non_idp`, `idp_cluster_NG026`). `read_sheet_guarded()` in prep keeps the same first read
(so every already-typed column is typed exactly as before), then re-reads only the logical-typed columns as text
and replaces any that hold a non-boolean value; a typed numeric/date column meeting a foreign value is NOT
re-typed but raises a `READXL COERCION` sanity warning. `real_meta$readxl_forced_text` records what was healed.
Acceptance on the 09-25 export: byte-identical `real_submissions.csv`. Other scripts still read the export with
`guess_max = 5000` unguarded (`audit_missingness.R`, `build_idp_listing_duplicates_data.R`,
`rebuild_idp_listing_sheets.R`).
```

## A5. Option C attribution — whole-LGA credit, collector-only pace   *(apply when: dashboard + recovery pipeline change deployed)*

```markdown
## Attribution after a reallocation — "option C" (2026-09-25)

Jack's decision when LGAs move between partners (2026-09-25: Chibok + Damboa IMC -> FACT; ACF -> ZOA planned):
**credit, target and Still Needed follow the CURRENT LGA owner and count EVERY collector's interviews** in that
LGA (a real interview counts wherever it was collected, so all ties keep working); **pace is the partner's OWN
collection** (`credited_own_n` per day since its own first submission, `build_partner_progress_summary()`).
Credited stays capped per stratum before it is summed (`credited + remaining == target` by construction).
**Where the split is shown (Jack, decision F, 2026-09-25, "option 2 as the dashboard is for internal + partners"):
the recovery EMAILS ONLY.** The dashboard (Progress by partner table and hover, Partner Report on screen and its
Excel) shows whole-LGA totals; `SHOW_ATTRIBUTION_SPLIT <- FALSE` in `global.R` hides the split columns, which are
still computed (pace needs `credited_own_n`), so flipping it to `TRUE` restores every display. A registered partner
with no LGA (ACF) keeps a visible row showing ITS OWN Collected / Achieved / Confirmed / Pending counts (every
completed interview it did, matched or not; one definition, `partner_own_counts()` in `global.R`), Status "No LGAs
assigned", target / credited / still needed 0, and Current daily pace / Required daily pace / Projected finish BLANK
(a computed 0.0 read like a stalled team; Coordinator, under Jack's F/G answers). Its Partner Report tiles
(Collected / Achieved / Confirmed Deleted / Pending Deletion), the Excel Summary sheet and the PDF headline show the
same own totals instead of 0, and the report still lists its own interviews by LGA and the LGA's current owner
(they are its own counts; LGA ownership is public on the Coverage Map). Ordinary partners' rows, tiles and pace are
unchanged. Split columns (now emails-only):
"of which collected by other
partners" (`credited_by_others_n`), "Collected outside assigned LGAs" (own Achieved interviews in an LGA the partner
does not currently own — a previous owner's collection stays visible on its own row) and "In dropped strata
(indicative only)" (own interviews in a dropped stratum of its own LGAs, e.g. FACT's Gubio; an excluded LGA counts
as the partner's own if it is on record as the prior partner in `excluded_lga_prior_partners.csv`). IRC/LHI shared
LGAs stay as they were (standing agreement, no visibility of their split) — a different case from a
reallocation. **Follow-up ITEMS (duplicates, deletions, listings) stay routed to the COLLECTOR (`org_id`)**, not
the LGA owner (Jack, 2026-09-25: option 1); IMC keeps its six open Chibok/Damboa duplicate queries.
`org_id` in the data is always the collector (KoBo `l_org_id`); ownership lives in `partner_lga_assignment.csv`
(current) and, in the frame, `original_partner_covering` + `coverage_reallocated_on` (+ 1_sampling's
`coverage_change_log.csv`). `full_batch_pipeline.R` and the dashboard tie exactly for all 19 partners (the old
pipeline understated eight partners' credited by 1-11 because it dropped 46 recovered false_positive rows).
```

---

# PART B — `3_analysis/README.md` (bullets for "Data-quality context inherited from 2_monitoring")

These are written for an analyst who receives a static copy of the final dataset. Suggested placement: append to
the bullet list, after the `is_duplicate` bullet. **Also see B0 first.**

### B0. The existing Collected/Achieved bullet is stale   *(apply when: Jack agrees; apply with B-blocks)*

The README's "Collected vs. Achieved" bullet still describes the pre-2026-09-11 definition (Achieved excludes
duplicates and unmatched rows and is capped per cluster). Current: **Achieved = completed interview that is not a
SETTLED (confirmed/contested, not recovered) deletion**; pending flags, duplicates and unmatched rows still count;
UNCAPPED since 2026-09-20 (every oversampled interview counts in full). `Collected = Achieved + Confirmed Deletion +
Oversampling Surplus` holds exactly at every grain. Suggested replacement: point at `2_monitoring/CLAUDE.md`,
"Achieved — one rule, read two ways" and "Collected/Achieved/Confirmed Deletion/Pending Deletion".

### B1. `org_id` is the collector, not the LGA's owner   *(apply when: option C deployed)*

```markdown
- **`org_id` = who COLLECTED, not who OWNS the LGA.** Partners' LGAs were reassigned mid-collection (2026-09-25:
  Chibok + Damboa IMC -> FACT; ACF stopped and its five Sokoto LGAs went to ZOA; Kankia IMC -> FACT, leaving IMC with
  no LGA) — so a partner's interviews can sit in LGAs it no longer owns (ACF: 777 collected, none in an LGA it still
  holds now that ZOA has the five LGAs; IMC: 328 collected, 313 achieved, all in Chibok/Damboa/Kankia, now FACT's
  `[verified 2026-09-25 after the frame patch and assignment rerun; re-verify at apply time]`).
  `partner_lga_assignment.csv` is the
  CURRENT assignment, not the assignment at collection time; the sampling frame carries `original_partner_covering`
  and `coverage_reallocated_on` per row and 1_sampling keeps `coverage_change_log.csv`. Group by `org_id` for "who
  did the fieldwork", by the LGA's current owner for "whose target/credit". Do not drop a partner just because it holds
  no LGA: `partner_registry.csv` lists every valid collector.
```

### B2. `is_duplicate` follows the live-claimant rule   *(apply when: change (4) decided + prep deployed)*

```markdown
- **`is_duplicate` (revised 2026-09-25):** still "not the first row to claim its point/listing slot", but the first
  LIVE claimant — a completed interview that is not a settled deletion — is NOT a duplicate even if an earlier
  submission (typically a `duration_under_20` one) claimed the same slot first; a settled-deleted duplicate keeps
  `TRUE`. `n_live_claims` gives the number of live claimants per slot. This changes the flag on ~300 rows relative
  to the definition above; it never changes Achieved.
```

### B3. Dates: provenance and known gaps   *(apply when: the guard is deployed)*

```markdown
- **Submission dates: `dates_source`, and what is NOT reliable.** Every row carries `dates_source`
  (`export` = as exported; `carried_forward` / `audit_reconstructed` only if a blank export ever had to be
  patched — check that column is all `export` in the frozen file, otherwise `end_datetime` is approximate and
  `uploaded_at`/`sync_lag_min` are unavailable for those rows). The DO's 2026-09-24 export came through with every
  date blank (reissued 2026-09-25). `submission_date`/`start_datetime` are deliberately blank on `flag_date_outlier`
  rows (an implausible device clock). NB a start-date-ahead-of-upload pattern on some FACT tablets (~45 rows, start
  one calendar day AFTER the upload) means `submission_date` is one day early there; `flag_date_outlier` does not
  catch it once "tomorrow" has passed.
```

### B4. Not-covered LGAs are outside the design, not missing data   *(apply when: record seeded + deployed)*

```markdown
- **Coverage: which LGAs were never in the sample and why.** 147 of 323 LGAs are `not_covered` in the frame: whole
  states Kano (documented, 2026-07-30), Niger and Kogi, 56 LGAs in Benue/Kaduna/Nasarawa/Plateau, and Marte (Borno).
  `2_monitoring/config/coverage_decisions.csv` records who accepted each as not covered and when (the frame's
  `partner_coverage_declined` label alone is the design script's default, not a recorded decision); LGAs dropped for
  accessibility keep their own `exclusion_reason`. Weighting/representativity work must treat these as outside the
  sampling universe. Ask for `coverage_state_by_lga.csv` and the decision record alongside the dataset.
```

---

# PART C — worth recording, not on the Coordinator's list   *(each: apply when the change is decided/deployed)*

1. **`deploy_dashboard.R` only ran 5 of the 7 independent checks** until the two-line addition prepared on
   2026-09-25 (`run_independent_date_outlier_check()`, `run_independent_unmatched_check()`); CLAUDE.md's
   "Independent deletion checks" lists five. *apply when: the addition is approved and deployed.* Include that an
   unmatched CARE/Lafia interview (uploaded 2026-09-23) was in no tracker row because of it.
2. **`flag_date_outlier` lapses:** the rule is `start < 2026-08-01 or start > Sys.Date()`, so a start one day ahead
   is flagged only until the next day. 45 FACT rows affected; two FACT `date_outlier` tracker rows are therefore
   real, not stale. *apply when: Jack decides whether to make the rule stable.*
3. **`FIELDING_PLANNED_END` (2026-09-27) is the ROUND 1 END / IPC-CH CUT-OFF, not the end of all fielding**
   (Jack, decision Q, 2026-09-25: "officially our end of collection date is the 27/09/2026, this is our cut off to
   have the data into a key decision making forum (IPC/CH) in Nigeria ... Round 1 is finishing on the 27/09/2026 in
   order to clean and analyse our data in time for the IPC/CH. Round 2 is aimed to be the comprehensive full
   collection that will be reported on later. This will also reflect two rounds of cleaning/analysis"). It drives the
   partner On pace / Behind pace status, `required_daily_pace`, the "Days to Round 1 cut-off" tile (was "Planned days
   remaining"), the Home "Round 1 window" row (was "Fielding window") and the trend chart's "Pace needed by Round 1
   cut-off" line (it does NOT drive "Est. days required", which uses the last 7 days' rate). The constant keeps its
   name; every displayed label says Round 1 / cut-off, and a line under the partner table says Status, Required daily
   pace and Projected finish are measured against it. One constant in `global.R`, nothing else to change when it
   moves. *apply when: the relabel is deployed.* **README.md wording to change when README edits are released**
   (not edited — held): line ~82-83 "pace needed to finish on time" -> "pace needed to finish by the Round 1
   cut-off"; line ~131-136 the "Assumption to confirm ... placeholder end date of 2026-08-26" bullet is stale ->
   "`FIELDING_PLANNED_END` (2026-09-27) is the Round 1 end / IPC-CH cut-off; Round 2 is the fuller collection";
   line ~232-235 "pace vs. deadline" -> "pace vs. the Round 1 cut-off". (Line ~787-789 is dated changelog history;
   leave it.)
3b. **The recovery workbook's "return by" date and the email's now share ONE constant** (`EMAIL_DEADLINE`, in the new
   `reports/partner_data_recovery/scripts/recovery_deadline.R`, "28 September 2026"). Before 2026-09-25 the email had
   its own literal while every workbook printed `build_partner_workbook()`'s stale "4 September 2026" default
   (`run_full_batch.R` never passed one). The workbook builder's default is now the constant, so forgetting to source
   it fails loudly instead of printing a stale date. It is a hand-set per-round date, deliberately NOT linked to
   `FIELDING_PLANNED_END`; bump it in `recovery_deadline.R` for the next round. *apply when: the next recovery batch
   is built with it.*
4. **`rounds_outstanding` bumps on every run of the independent checks** (every re-seen open row +1), so extra local
   runs inflate it. *apply now-ish: a one-line caution under "Independent deletion checks".*
5. **Sandbox testing needs the renv library on `R_LIBS`** and short paths; see the Dashboard session's notes
   (not repo docs) — only worth adding if Jack wants a "how to test safely" paragraph.
6. **The recovery package's headline "Achieved" (`n_achieved_total`) excluded RECOVERED false positives** — found
   2026-09-25 while preparing IMC's package. `full_batch_pipeline.R` (line ~303) built `achieved_excluded_uuids` from
   every terminal-status tracker row without requiring `is.na(recovery_type)`, so a recovered row (status
   "confirmed", `recovery_type = false_positive`) read as a settled deletion: 350 rows across 18 partners on the
   09-25 data (the 46 earlier recoveries + the 304 cleared under decision D; FACT 183, DRC 40, NRC 24, Malteser 24).
   The same set feeds the Oversampled Clusters counts and the Enumerator Performance "% counting as Achieved" flag;
   credited / still needed / % and the follow-up sheets were not affected. IMC's preview email said "308 currently
   count as Achieved" against the dashboard's 313. **APPLIED 2026-09-25 (Coordinator's GO, working tree only):**
   `is.na(recovery_type)` added to that line (the definition the dashboard and the pipeline's own credited figure
   already use). Verified on all 19 packages built in memory, old vs new: package Achieved now equals the dashboard's
   own count for 17 partners; total gap 370 -> 20. **The 20 remaining rows (CRS 19, CARE 1) are DELIBERATELY left as
   they are (a definition question):** they are completed, non-deleted interviews with no `matched_survey_id`, no
   matched cluster and no IDP listing/walk position, which the dashboard counts as Achieved nationally
   (2026-09-11 policy) but the recovery pipeline's `!is.na(matched_survey_id)` terms (lines ~626/698/738) leave out.
   Credited / remaining / target are unchanged for every partner. Effect of the fix: 14 partners' Oversampled Clusters
   sheet/line changes (more clusters/surplus, e.g. FACT 340 -> 355 clusters, CRS 17 -> 22, DRC 3 -> 6, Malteser 18 ->
   22); 165 enumerators' "currently count as Achieved" number changes (18 partners); three enumerator flag lists change
   (FACT fact_zam_msna_023 drops out of the under-50%-Achieved list, 49% -> 51%; IMC imc_kat_msna_006 drops out, 40% ->
   80%, IMC flagged enumerators 4 -> 3; SI si_keb_msna_009 is newly in it, 0% -> 20%, SI 13 -> 14). apply when: the next
   recovery batch is built.
7. **RECOVERED rows were listed on every partner recovery sheet - FIXED 2026-09-25 (fix A; Coordinator's GO,
   working tree only, not yet in any built workbook or email).** `confirmed_deletion_all` (full_batch_pipeline.R
   ~129) is every tracker row with no `recovery_type` filter, so every sheet built from `del_sheet_all` listed
   recovered false positives: on the 09-25 data 350 recovered rows across the packages - Non-IDP Duplicates 269, IDP
   Listing Duplicates 46, Confirmed Deletions 35 (the 35 `fcs_zero` rows recovered on 2026-09-10, shown as "confirmed
   for removal": CRS 11, COOPI 4, FACT 4, IMC 4, DRC 3, INTERSOS 2, Malteser 2, PLAN 2, Street Child 2, CARE 1) - 304
   of them decision D's. Fix: the DISPLAY sets (`del_sheet_display`, and the missing-listing / other-issues sources)
   use `is.na(recovery_type)` rows only; `excluded_uuids` (candidate suppression for the GPS / IDP Listing sheets)
   deliberately stays on the UNFILTERED set, so a recovered row is never re-flagged as a fresh candidate. Verified on
   all 19 packages built in memory, before vs after: recovered rows listed 350 -> 0; no non-recovered row lost from
   any sheet; recovered rows do not reappear as GPS/IDP candidates; collected / achieved / credited / still needed /
   target / duration counts and Oversampled Clusters identical. Effect: 340 net sheet rows fewer (350 recovered rows
   gone, 10 legacy rows added - item 8): e.g. FACT Non-IDP Duplicates 634 -> 473 and IDP 1,033 -> 1,015, DRC
   Non-IDP Duplicates 40 -> 4, Malteser 28 -> 7, NRC 32 -> 12, MDM IDP 20 -> 9. Email lines change for 13 partners
   ("N interviews are confirmed for removal" and "N interviews still needing an IDP listing slot confirmed"; e.g. FACT
   1,113 -> 1,109 and 1,033 -> 1,015, CRS 129 -> 118 and 119 -> 115, DRC 84 -> 81 and 40 -> 39); ACF, FHI 360, IRC,
   LHI, SCI and ZOA emails are unchanged. One enumerator list changes: CRS's "at least 30% already confirmed for
   deletion" drops crs_ben_msna_014 (CRS flagged enumerators 11 -> 10).
8. **Legacy blank-`deletion_reason` rows were dropped from every sheet - FIXED 2026-09-25 (fix B; same GO).** Line
   ~244 `filter(reason != "duplicate_point")` silently dropped rows whose reason is blank (`NA != x` is NA and
   `dplyr::filter()` drops it). 10 rows on the 09-25 data, all IMC's "contested" rows: settled deletions on the
   dashboard (Confirmed Deleted, excluded from Achieved) that appeared in NO sheet. Now `is.na(reason) | reason !=
   "duplicate_point"`. Audit of the other `!=` filters in the pipeline and helpers: no other silent drop on a list
   partners see (278/282 compare non-null keys; 629/664 compare the frame's always-populated `coverage_status`; the
   rest are scalar or `!= ""` on columns initialised to ""). The `== "duplicate_point", del_pop_type == ...` filters
   are safe today (0 of 2,011 duplicate_point rows has a blank population type). Same-day companion change in
   `build_workbook_fn.R`: a blank reason, or any reason with no entry in `reason_text_map`, now prints a plain
   fallback in the Confirmed Deletions "Reason" cell instead of NA (exact wordings in item 9; ACF's 2
   `gps_no_match_partner_confirmed` rows, the one unmapped reason in today's data, now have their own plain-English
   entry instead of the fallback). After A + B, EVERY settled deletion the dashboard counts appears on some partner sheet for all 19
   partners (before: 10 on none). IMC reconciliation: dashboard Confirmed Deleted 15 = 10 legacy "contested" +
   3 `duration_under_20` + 2 confirmed `duplicate_point` (1 on the Non-IDP and 1 on the IDP Listing Duplicates sheet);
   the Confirmed Deletions sheet, and so the email line "N interviews are confirmed for removal", holds 13 (10 + 3;
   was 7 = 3 + 4 recovered fcs_zero), and 13 + the 2 duplicates on their own sheets = 15. IMC's 4 recovered fcs_zero
   rows and 1 recovered duplicate are NOT part of the 15 (a recovered row counts as Achieved), and appear on no sheet.
   IMC: 328 collected = 313 achieved + 15 confirmed deleted.
9. **Partner-facing wording added to the Confirmed Deletions sheet, and the closed-row rule for already-contested
   rows (2026-09-25; Coordinator's instructions; working tree only, nothing built or sent). EXACT TEXTS, for Jack to
   see before any batch is built:**
   - Reason cell when the tracker has NO reason (IMC's 10 legacy rows): *"Confirmed deletion - historical record from
     an earlier round (the specific reason was not recorded)."*
   - Reason cell for `gps_no_match_partner_confirmed` (ACF's 2 rows; new `reason_text_map` entry; the tracker's own
     record of ACF's GPS Duplicates answer of 2026-09-06, "no nearby household match found; enumerator resolved to redo
     the survey; partner confirmed deletion"): *"This interview's GPS location did not match any household available in
     its cluster. In your team's response to the GPS Duplicates sheet, no nearby household match was found and your
     team confirmed the deletion (the enumerator planned to redo the survey)."*
   - "Contest This? (Yes/No)" cell for a row the partner has ALREADY contested (new; replaces a second dropdown):
     *"No action needed -- your team has already contested this interview, and the MSNA team has it on record."*
     (The no-appeal rows keep their existing note, "No action needed -- confirmed per validated assessment
     methodology, not open to contest.")
   - Fallback for any FUTURE reason that has no text: *"Confirmed deletion (<reason code>)."* (none exist today).
   **The rule (generic):** `is_already_contested = status "contested" and the reason is not a no-appeal reason`;
   `is_appealable = not no-appeal and not already contested`. Only that state changes. pending / sent / rejected rows
   (live, first-time or re-asked appeals) and confirmed rows keep their dropdown; a no-appeal reason keeps its
   methodology note whatever the status. Checked on every status x reason combination (25, synthetic) and on all real
   rows: across ALL partners the Confirmed Deletions sheets hold 2,110 rows = 2,098 no-appeal (2,013 short interviews +
   85 no-consent) + 10 IMC "contested" rows that showed the dropdown (now closed) + 2 ACF `gps_no_match` "confirmed"
   rows that keep it; there is NO pending / sent / rejected row on any of these sheets, so no live appeal changes.
   Rendered check: IMC's sheet has no dropdown range at all (10 contested-note rows + 3 methodology-note rows); ACF's
   has `I2:I3` (its 2 rows); FACT none. The returned-workbook verifier `verify_data_recovery_response.py` gets the
   matching constant `CONTESTED_CLOSED_NOTE` (a returned workbook carrying the note logs an INFO, not the "not Yes/No"
   warning; tested on the IMC preview: 10 INFO + 3 INFO, 0 warnings/errors); `review_recovery_response.py` already
   skips rows that are resolved in the tracker, so it needs no change. The 10 IMC rows' tracker resolution reads
   "contest reviewed and rejected - deletion stands" (2026-09-03), i.e. genuinely closed; the note is deliberately
   neutral ("on record") because the same status is also written when a contest is upheld (see item 10). Only IMC's row
   ORDER on that sheet changes (appealable rows sort first).
10. **Latent issue, NOT fixed (found 2026-09-25 while reading `review_recovery_response.py`):** when a reviewer
   overturns a partner's contest, the script records status "contested" with resolution "contest upheld - deletion
   overturned, recover interview" but sets NO `recovery_type` (line ~285), whereas an approved correction sets
   `recovery_type = false_positive`. The dashboard and both overlays read "contested and no recovery_type" as a
   settled deletion, so an overturned contest would still be excluded from Achieved. No such row exists today (the
   only 10 contested rows, all IMC's, were all "rejected - deletion stands"), so nothing is wrong yet. Proposed: have
   the overturn branch set `recovery_type` (e.g. `false_positive` / `justified_exception` as the reviewer decides) so it
   rejoins Achieved; needs Jack's word on which value.

---
*Proposal file only. Path: `2_monitoring/_working_files/PROPOSED_DOCS_2026-09-25.md`.*
