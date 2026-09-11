# Partner data-recovery workbook pipeline

Scripts for the whole partner data-recovery workflow: develop a recovery
workbook → send to partners → receive their filled-in response → review/
verify it → approve or reject each row → approved rows feed either (a) an
overlay that will apply confirmed recoveries to `real_submissions.csv`, or
(b) a CSV handed to 1_sampling for confirmed deletions, to assess what
needs resampling. Consolidated here 2026-09-03 — previously split across
this folder's generated output, `cleaning/real/data_recovery_responses/`,
and a Claude scratchpad that was never committed anywhere.

**Sibling folders** (one level up, `reports/partner_data_recovery/`):
- `outputs/<Partner>/` — generated workbooks + email drafts, one folder
  per partner. Also where `verify_data_recovery_response.py` writes each
  partner's verification findings CSV, and (once built) the two downstream
  outputs (recovered-submissions overlay, 1_sampling deletion feed) —
  read directly by `prep_real_submissions.R` / copied by 1_sampling from
  there, no duplication into `data/`.
- `inputs/<Partner>/` — one folder per partner (pre-created for all 19,
  2026-09-03), each with two subfolders for the two things a partner
  sends back:
  - `workbook/` — their filled-in recovery workbook, as returned
    (suggested naming: `<Partner>_data_recovery_workbook_RETURNED_
    <date received>.xlsx`, keeping the original filename recognisable).
    This is what `verify_data_recovery_response.py` / `review_recovery_
    response.py` read.
  - `email/` — the email they sent it with (saved as `.msg`/`.eml`/
    `.html`/`.txt`, whatever's easiest to drop in). Read for context
    (partner comments, caveats, questions) and as the basis for drafting
    a reply — not parsed by any script.
  No autodetection/watch mechanism — run the verifier by hand per file.

**Verification/generation here is deliberately NOT the last step.**
Row outcomes have three different downstream homes (a recovered
survey_id, a confirmed deletion, a listing gap that feeds back into the
resampling side) — integrating those into `real_submissions.csv` or a
1_sampling handoff is a separate, explicitly-approved step per Jack
(2026-09-01), not automatic once a file passes verification or a decision
is recorded in the tracker.

## Files

**Generation** (produces the workbooks that go into `../outputs/<Partner>/`):
- `full_batch_pipeline.R` / `build_workbook_fn.R` / `build_email_fn.R` /
  `run_full_batch.R` — the logic that produced the original 2026-08-30
  19-partner batch. **`full_batch_pipeline.R` is a frozen snapshot, not
  currently runnable as-is** — see its own header: it depends on
  scratchpad-only intermediate `.rds` files and the sampling frame's
  superseded v2 paths. Kept as a reference/rebuild starting point.
- `real_hh_listing.R` — real per-cluster IDP household-listing pool, from
  the actual HH Listing RandomSelect tool's export (Jack supplied
  `cleaning/MSNA_Data_Cleaning/Kobo Downloads/hh_listing_tool/
  hh_listing.xlsx` 2026-09-03). Replaces the earlier proxy ceiling
  entirely. See its own header for the methodology: most-recent-
  submission-per-cluster (re-listings grow monotonically over time, not
  conflicting attempts), primary+reserve draw union (not the raw full
  listing, and not hh_listed_count directly — that field hits an apparent
  1000-submission-cap on huge camps that primary/reserve sidesteps
  entirely since it's bounded by the design's own draw size). Shared by
  both scripts below.
- `build_idp_listing_duplicates_data.R` — reusable, CURRENT (2026-09-03)
  data-prep for the "IDP Listing Duplicates" sheet specifically, fixing
  two bugs Jack found in the original (ceiling capped at
  `target_households` instead of the real listing size — now the real
  data via `real_hh_listing.R`, not a proxy; a "Nearest Unclaimed Numbers"
  suggestion column that undermines the design's own randomisation, now
  dropped). Outputs an `Available Numbers` column (the real space-
  separated numbers, not just a count) alongside the display ceiling.
  `--full` flag toggles "every row" vs "flagged duplicates only" mode. Use
  this (not the frozen full-batch script) for any future partner's IDP
  Listing Duplicates sheet.
- `rebuild_idp_listing_sheets.R` — in-place rebuilds the "IDP Listing
  Duplicates" + "Lookup_IDP" sheets inside every partner's ORIGINAL
  workbook (one workbook per partner, always), leaving every other sheet
  untouched. Standard partners get flagged-duplicates-only mode (same
  scope as their existing sheet); `FULL_MODE_ORGS` (currently just `zoa`)
  get every real IDP interview for their own clusters instead, with an
  added "Is Duplicate (Yes/No)" column and an explanatory note appended to
  their own READ ME sheet — same sheet name/position as everyone else,
  just a different scope. (This replaced an earlier, short-lived approach
  of sending ZOA a separate standalone supplement file — Jack: "I just
  wanted to have this extended sheet replace the existing IDP HH
  duplicates sheet within their main workbook... same as everyone's but
  they just get an extended sheet for this one sheet" — one workbook per
  partner, always.) Restores each workbook's original tab order after
  every rebuild (`removeWorksheet()`/`addWorksheet()` appends at the
  physical end, but a separate `worksheetOrder()` controls what a viewer
  actually sees — set it explicitly or the sheet ends up last) and calls
  `fix_openxlsx_roundtrip.py` on every save. Run 2026-09-03 across all 17
  partners with an IDP Listing Duplicates sheet, then RERUN the same day
  after a bug was found: `claimed[[1]] %||% integer(0)` was excluding only
  the FIRST already-claimed number per cluster, not the whole claimed set
  (rowwise() already auto-unwraps a list-column, so re-indexing with
  `[[1]]` grabbed just one element) — caught while assessing IMC's
  returned workbook, confirmed against IMC's own saved file (idp_NG008007_4
  showed 95 available when the correct figure is 55). This inflated
  "Total Numbers Available"/the CONFIRMED dropdown for every multi-claim
  cluster in all 17 workbooks from the first run — including ZOA and DRC,
  both already sent to partners before the fix. See `build_idp_listing_
  duplicates_data.R`'s header for the full note; same fix applied to both
  files, all 19 originals restored from `_backup_before_real_listing_fix_
  2026-09-03/` and the batch rerun before this note was added. Uses
  `openxlsx::loadWorkbook()` (not Python) since
  these files were built by R's openxlsx in the first place. **Always
  back up `outputs/` before rerunning this** (`cp -r outputs
  outputs_backup` or similar) — it overwrites partner-facing files in
  place.
- `fix_openxlsx_roundtrip.py` — fixes a real bug hit while building the
  above: `loadWorkbook()` → `saveWorkbook()` fails to re-escape a literal
  `&` already present in an EXISTING sheet name ("GPS Duplicates &
  Distant Pts", in every one of these workbooks) — produces invalid XML
  that fails to open in Excel or openpyxl at all, not just openpyxl's
  usual drawing-reference complaint. `rebuild_idp_listing_sheets.R` calls
  this automatically after every save; run it standalone on any other
  file if the same openxlsx round-trip pattern gets reused elsewhere.
  Different from `xlsx_repair.py` below — that one's a read-time-only
  workaround, this one fixes the file on disk since partners open these
  directly.

**State** (persists across batches — see `issue_tracker.R`'s own header
for the full schema/lifecycle):
- `issue_tracker.R` / `issue_tracker.py` — `recovery_issue_tracker.csv`
  (this folder), one row per detected issue (GPS duplicate, IDP listing
  duplicate, missing HH listing, confirmed deletion), status
  pending/sent/confirmed/rejected/contested. Built so a rerun of
  generation doesn't re-flag an issue a partner already resolved, and
  ingestion can apply the same resolution twice without creating a
  duplicate row. Deliberately doubles as the "trace/log" record for the
  data officer (export/filter a view of it when needed) rather than a
  separate document. NOT yet wired into generation or verification below
  — that's the next integration step.

**Verification** (checks a returned workbook before any row is trusted):
- `xlsx_repair.py` — every outgoing copy of this workbook family has the
  same corruption (each worksheet's `_rels` references a
  `xl/drawings/drawingN.xml` that doesn't exist in the archive — an
  openpyxl DataValidation-extension artifact, confirmed present before any
  partner ever touched the file, not partner damage). openpyxl's default
  loader raises `KeyError` on this. `load_repaired_workbook(path)` strips
  the dangling references in a temp copy and returns a normal
  `openpyxl.Workbook` — use this instead of `openpyxl.load_workbook()`
  directly for any file in this workbook family, sent or returned.
- `verify_data_recovery_response.py` — the actual checker. See its own
  header for exactly what's validated per sheet (GPS Duplicates & Distant
  Pts, IDP Listing Duplicates, Missing HH Listings, Confirmed Deletions) —
  derived directly from each sheet's own READ ME instructions plus the
  row-level ground truth already in the workbook (Cluster Availability's
  "Still Available" list, "Total Numbers Available in Cluster"), not from
  the workbook's own Excel dropdowns, which openpyxl can't read at all
  (same extLst issue as the drawing references).
- `_test_fixtures/` — a synthetic "returned" copy of FACT's workbook with a
  deliberate mix of valid and broken responses planted by hand, used to
  prove the verifier actually catches what it's supposed to before trusting
  it on a real response (no real partner response had landed yet as of
  2026-09-01 when this was built). Confirmed catching: wrong-cluster
  household IDs, double-claimed household/listing IDs, out-of-range listing
  numbers, non-Yes/No answers, missing dates, unparseable/future dates,
  and contested deletions with no explanation — while leaving genuinely
  clean rows with zero findings. Safe to delete once real responses are
  flowing and this has been exercised against at least one.

**Review** (the human "approve/reject" decision step):
- `review_recovery_response.py` — interactive CLI, run AFTER `verify_data_
  recovery_response.py` has produced findings for the same file. Walks
  through every row with something to decide (a CONFIRMED value, a Yes/No
  answer, a contest) that didn't fail structural verification, shows its
  context plus any WARNING/INFO findings, and prompts approve/reject/skip/
  quit. Records the outcome via `issue_tracker.py`'s `apply_resolution()`
  (auto-registering the issue first via `ensure_issue()` if generation
  never explicitly registered it - see its own header for the full status-
  mapping rationale, especially how Confirmed Deletions differs: an
  uncontested deletion auto-resolves with no prompt, only an actual
  contest needs Jack's judgment). Safe to re-run on the same file - an
  already-confirmed/contested row is skipped automatically.

**Consolidation** (turns a reviewed response into the partner's standing record):
- `apply_returned_response.R` — merges a partner's RETURNED workbook into
  their MASTER copy in `../outputs/<Partner>/` IN PLACE, once decisions are
  made. Three-way division of labour: the returned file in `../inputs/
  <Partner>/workbook/` is never modified (stays the literal record of what
  they sent); `recovery_issue_tracker.csv` is the audit trail for anything
  that needed an actual reviewer decision; this script bakes both the
  partner's own answers AND any tracker decision into the master workbook,
  matched by Interview ID (not row position, since the master's row set
  can differ from what was actually sent - e.g. a row a later data refresh
  surfaced that the partner never saw gets an explanatory note instead of
  being silently treated as answered). Built 2026-09-03 per Jack, so the
  master copy becomes both (a) something to send back to a partner showing
  what's resolved vs. outstanding, and (b) the base a NEXT round's fresh
  data + returned-response merge stacks onto, rather than each round
  starting blank. See its own header for the exact per-sheet merge rules
  (IDP Listing Duplicates' tracker-then-partner-then-retain precedence,
  the one-off `MISSING_HH_OVERRIDES` mechanism for when a partner's Yes/No
  answer is checked against source data rather than taken on their word).
  Always back up the target file first (same discipline as `rebuild_idp_
  listing_sheets.R`) - this overwrites a partner-facing file in place.
  Usage: `Rscript apply_returned_response.R <ORG_ID> <path_to_returned_xlsx>`.

**Not yet built** (next steps, per Jack 2026-09-03):
- Wiring `register_issues()`/`get_unresolved_issue_ids()` into generation,
  so a rerun doesn't re-propose an issue already resolved via the review
  step above.
- The recovered-submissions overlay `prep_real_submissions.R` will read,
  and the confirmed-deletions CSV handed to 1_sampling (scope: both
  data-officer-flagged deletions the partner didn't contest, AND any GPS/
  IDP-listing issue where no valid recovery was ever confirmed) - both
  should be straightforward exports FROM the now-populated
  `recovery_issue_tracker.csv` once real responses have been reviewed.

## Usage

```
python verify_data_recovery_response.py <Partner> <path_to_returned_xlsx>
```

Writes `<Partner>_verification_findings_<today>.csv` next to the input file
— one row per issue found (a clean row contributes nothing), each tagged
`ERROR` / `WARNING` / `INFO`:

- **ERROR** — internally inconsistent or impossible (wrong cluster, out of
  range, double-claimed, contested with no reason). Needs going back to the
  partner before the row is usable for anything.
- **WARNING** — plausible but worth a human look before trusting (e.g. a
  confirmed ID that isn't in the cluster's "Still Available" list — could
  be a genuine already-claimed conflict, could just be this checker's
  stale copy of Cluster Availability).
- **INFO** — no response yet (will default to "unresolved/excluded" per
  the workbook's own READ ME), or a soft note (e.g. confirmed listing
  number matches the original disputed number — not wrong, just worth a
  glance).

Also checks, before any row-level validation runs: every actionable sheet
is still present, headers weren't reordered/renamed, and the Interview
ID / Cluster ID row set still matches what was actually sent (a partner
adding, deleting, or reordering rows breaks every positional check below
it) — flagged as a sheet-level `ERROR` if not, and that sheet's row checks
are skipped rather than run against misaligned data.
