# System overview: `recovery_issue_tracker.csv`

Compiled 2026-09-11 by Coordinator, via a 14-agent parallel read of every
script in `cleaning/real/` and `reports/partner_data_recovery/scripts/`
that touches this file, directly or through a derived artifact, followed
by one synthesis pass. Every claim below is grounded in an actual file
read (cited by file:line where it matters), not inferred from
documentation alone — several places below exist specifically *because*
a file's own header/comments were found to disagree with its code.

## 1. What this file is

`recovery_issue_tracker.csv` (`2_monitoring/reports/partner_data_recovery/scripts/recovery_issue_tracker.csv`)
is the single persistent state file for the MSNA N-WEC 2026
partner-deletion-recovery workflow. It is the system of record for every
data-quality issue raised against a real submission or a household-listing
entry — a confirmed deletion, a suspected duplicate, a listing gap — from
first detection through however many recovery-workbook rounds it takes to
reach a partner or internal decision, to its final resolved (or contested)
state. It is read and written by a mix of R and Python scripts spread
across `2_monitoring/cleaning/real/` and
`2_monitoring/reports/partner_data_recovery/scripts/`, and its downstream
effects — via two overlay files it does not itself produce directly —
reach as far as `1_sampling`, a separate git repository, where partner
"Achieved" counts are computed.

As of 2026-09-11: 2,282 rows, four `issue_type` values (confirmed_deletion
2168, missing_hh_listing 62, idp_listing_duplicate 28, gps_duplicate 24),
three live `status` values (pending 1288, confirmed 984, contested 10 —
`sent`/`rejected` are supported by the schema/code but currently have zero
rows on disk).

## 2. Schema — 18 columns, what each means, what sets it

- **issue_id** — stable dedup key. `build_issue_id()`: `uuid` for most
  types, `cluster_id` for `missing_hh_listing`. Set once at creation
  (`register_issues()` in issue_tracker.R, or `ensure_issue()` in
  issue_tracker.py), never recomputed.
- **issue_type** — `confirmed_deletion` / `missing_hh_listing` /
  `idp_listing_duplicate` / `gps_duplicate`. Set at insert by the caller.
  Note: the listing-gap check is registered as `missing_hh_listing` despite
  its own function being named `run_independent_listing_missing_check()`
  (`independent_deletion_checks.R:319-385`) — a naming leftover from the
  correction made the night this was renamed.
- **deletion_reason** — e.g. `duration_under_20`, `no_consent`,
  `duplicate_point`, `pct_missing_flagged`. Set **only at first insert**,
  never on a re-seen row — this is why the five independent checks must
  run in the DO's priority order. Four of five checks' transmute blocks
  set it explicitly; `run_independent_listing_missing_check()`'s does not
  set it at all (`:363-377`). Never set by the Python side or either Python
  consumer script — zero hits grepped project-wide.
- **org_id** — set at insert from `real_submissions.csv`'s `org_id`
  (independent_deletion_checks.R) or, in register_deletion_log_issues.R,
  from two structurally different sources depending on path (daily-log
  path uses `all_del`'s own org_id; the legacy bridge uses a renamed
  `submission_org_id` joined in, since the legacy file carries no org_id).
- **cluster_id / strata_id** — same insert-time sourcing as org_id. Rows
  created via `review_recovery_response.py`'s `ensure_issue()` always get
  `strata_id=''` — that field is simply never passed by that caller.
- **uuid** — the KoBo submission UUID; natural dedup key for every type
  except missing_hh_listing.
- **listing_number** — for idp_listing_duplicate rows created via
  `review_recovery_response.py:160-161`, this stays the *originally
  flagged* number and is never updated to the confirmed replacement — the
  confirmed number only exists as free text inside `resolution` (`:163`).
  Reading `listing_number` as "the decided number" would be wrong for
  these rows.
- **status** — `pending` → (optionally) `sent` → `confirmed` /
  `rejected` / `contested`. `pending` at insert. `sent` only via
  `mark_batch_sent()` (issue_tracker.R) — **no caller of this function was
  found anywhere in the ecosystem reviewed**; the pending→sent transition
  may be structurally dead. `confirmed`/`rejected`/`contested` set by
  `apply_resolution()` (R or Python), `apply_review_decisions.R`'s inline
  equivalent, the two auto-confirm blocks in independent_deletion_checks.R,
  and register_deletion_log_issues.R's two no-appeal blocks.
  `TERMINAL_STATUSES <- c("confirmed", "contested")` (issue_tracker.R:178)
  means "excluded from re-flagging by register_issues()" — **not**
  "immutable": the file's own schema notes (85-91) say `apply_resolution()`
  can still move a contested row to confirmed later. This exact conflation
  is what produced the 1_sampling contested-status bug (section 6).
- **detected_date** — set once at insert, never changed.
- **first_batch_date / last_batch_date** — first set at insert;
  last_batch_date updated on every re-seen non-terminal row, and by
  mark_batch_sent().
- **rounds_outstanding** — initialized `"0"` at insert (R side only);
  incremented on re-seen non-terminal rows. Never touched by the Python
  side — rows from `ensure_issue()` get this hard-blanked to `""`.
- **resolution** — free text. Set by every resolution mechanism (see
  section 4) — each with its own literal wording ("validated methodology
  threshold, no appeal (independently computed)" for auto-confirms;
  partner's own contest text; "not contested, deletion stands"; etc.).
- **resolution_date** — set by every resolution mechanism, **always
  defaulting to `Sys.Date()` at call time and overwritten
  unconditionally** (issue_tracker.R:331, issue_tracker.py:101-103,
  apply_review_decisions.R:63) — unlike confirmed_by/recovery_type, not
  NA-guarded. Calling any of these twice on different days silently
  advances this field with no new decision made.
- **confirmed_by** — NA-guarded (only overwritten if truthy) everywhere.
  `'internal_team'` from the auto-confirm blocks; `'partner'` **only**
  from verify_data_recovery_response.py's writeback (`:366`) — confirmed
  live (56 rows carry `confirmed_by='partner'`). review_recovery_response.py
  never passes this, so rows it resolves keep whatever was already there.
- **recovery_type** — one live value, `false_positive` (46 rows), rest
  blank (2,236). NA-guarded. **Populated exclusively from the R side** —
  issue_tracker.py's apply_resolution() accepts the parameter but no
  Python caller was found passing it.
- **notes** — free text, set at insert; left `""` for Python-side inserts.

**A 19th column, `disposition`**, is proposed
(`_working_files/master_deletion_log_design.md`) but does not exist on
disk today — no script reads or writes it.

## 3. Lifecycle of a row

1. **Detection & registration** — `independent_deletion_checks.R` (manual,
   `cwd = 2_monitoring` root). Five `run_independent_*_check()` functions
   each re-read `data/real_submissions.csv` fresh (plus audit_duration.R /
   audit_missingness.R for two of the five; the DO's raw `hh_listing.xlsx`
   for missing_hh_listing). Each calls `register_issues()`: new issue_id →
   full new pending row; existing non-terminal → bump last_batch_date/
   rounds_outstanding; existing terminal → skipped untouched. Covers 5 of
   the DO's 6 reasons — **`fcs_zero` has no independent check anywhere in
   this 434-line file**, despite 2_monitoring/CLAUDE.md's summary claiming
   all six are covered.
2. **Immediate auto-confirmation** (duration_under_20, no_consent only) —
   right after registration, a duplicated ~12-line block
   (`:213-225`, `:264-276`) re-reads the tracker, finds just-registered
   non-terminal rows, sets confirmed/fixed-resolution/today/internal_team.
   Jack's 2026-09-11 no-appeal decision. The other three reasons
   (duplicate_point, missing_hh_listing, pct_missing_flagged) stay pending.
3. **Legacy DO-log path (now inert)** — register_deletion_log_issues.R can
   still be run against the DO's daily xlsx output, but as of the
   2026-09-06→11 edits it filters out all six current reasons plus one
   retired one before anything reaches register_issues() — a routine run
   registers nothing. Its only live remaining effect is a one-time bridge
   absorbing legacy `CONFIRMED_QUALITY_EXCLUSIONS.csv` rows.
4. **Batching to partners** — `run_full_batch.R` (Stage 1, manual) sources
   `full_batch_pipeline.R`'s `build_partner_package()` (reads the tracker
   for the Confirmed Deletions sheet) and `build_workbook_fn.R` to render
   the xlsx. `run_full_batch_emails.R` (Stage 2) reads a frozen RDS
   snapshot of Stage 1 — never the live tracker — to draft emails.
   `mark_batch_sent()` exists but **no caller was located**.
5. **Partner response — two coexisting mechanisms**:
   - *Python verify/review pair*: `verify_data_recovery_response.py` runs
     first (structural checks); its `verify_confirmed_deletions()` (since
     2026-09-06) writes straight to the tracker via `apply_resolution()`,
     gated on non-terminal status. `review_recovery_response.py` runs next
     as an interactive per-row CLI. Because it calls
     `verify_confirmed_deletions()` in-process with its default
     `apply_writeback=True`, **every review_recovery_response.py run also
     silently re-triggers verify's own writeback** before the operator is
     ever prompted — two different resolution-text/confirmed_by
     conventions land on the same kind of row depending on whether it
     pre-existed.
   - *Review-queue engine (2026-09-08 rebuild, chat-based)*:
     `generate_review_queue.R` reads the tracker, splits into
     confirmed/needs_review, writes a dated JSON (no tracker write). Jack
     is walked through it in chat; `apply_review_decisions.R` applies
     decisions in bulk — **despite its own header claiming to be "a thin
     wrapper around apply_resolution()," it never actually calls that
     function; it reimplements the field-setting inline.**
   - Neither path is confirmed from code alone to have fully superseded
     the other — both currently exist and are runnable.
6. **Merge into partner master record** — `apply_returned_response.R`
   (manual) reads the tracker via raw `read.csv()` (bypassing
   issue_tracker.R's API) only for the IDP Listing Duplicates sheet, and
   merges into a persistent per-partner MASTER workbook. Never writes the
   tracker.
7. **Overlay production** — `build_confirmed_deletions_overlay.R` (manual,
   documented as running after register_deletion_log_issues.R and before
   prep_real_submissions.R) reads the tracker and unconditionally rewrites
   two derived files every run. `prep_real_submissions.R` reads those two
   overlays (never the tracker) into `data/real_submissions.csv`, which
   feeds `dashboard_app/global.R`'s `is_achieved()` and, via
   `CONFIRMED_DELETIONS_OVERLAY.csv` directly, 1_sampling's partner-package
   scripts.

## 4. Who writes to the tracker

| Contributor | Trigger | Idempotent? |
|---|---|---|
| issue_tracker.R (register_issues/mark_batch_sent/apply_resolution) | Library, sourced by every R writer | Row identity always preserved; resolution_date is the exception (unconditional Sys.Date() reset on every apply_resolution() call). register_issues() also rewrites the file's mtime on every call, even a true no-op. |
| issue_tracker.py (ensure_issue/apply_resolution) | Library, imported by the two Python scripts | ensure_issue() genuine no-op on existing issue_id; apply_resolution() no-op if issue_id not found, but no internal guard against a *second, different* resolution on an already-terminal row — caller-side only. |
| independent_deletion_checks.R | Manual, cwd=2_monitoring root | Register-side idempotent; auto-confirm blocks exclude already-terminal rows. |
| register_deletion_log_issues.R | Manual | Rerun-safe by design (post a real 2026-09-06 bug that clobbered 10 partner-contested rows). Daily-ingestion bulk-confirm block is currently structurally unreachable (see §7) — only the legacy-file bridge is live. |
| apply_review_decisions.R | Manual, after a chat review session | Idempotent for decision fields on exact rerun; **not** for resolution_date or the audit log (a rerun of identical decisions duplicates the log line). No internal guard against re-deciding a terminal row — protected only by the queue's own construction. |
| verify_data_recovery_response.py (verify_confirmed_deletions) | Manual CLI | Idempotent — explicit non-terminal guard (`:349-361`). |
| review_recovery_response.py | Manual interactive CLI | Idempotent for confirmed/contested; deliberately NOT idempotent for rejected rows (reject = reopen for next round, by design). Also silently re-triggers verify's writeback (see §3). |

`build_confirmed_deletions_overlay.R` and `generate_review_queue.R` both
read the tracker but **never write it**.

## 5. Direct tracker readers vs. overlay/derived readers

**Direct**: issue_tracker.R/.py (the API); independent_deletion_checks.R
and register_deletion_log_issues.R (status-gating checks before writes);
build_confirmed_deletions_overlay.R (the canonical tracker→overlay
transform point — also hardcodes the tracker path a second time at `:67`
as a literal string, independent of issue_tracker.R's own dynamic
TRACKER_PATH resolution); generate_review_queue.R / apply_review_decisions.R;
apply_returned_response.R (raw `read.csv()`, bypassing the API);
full_batch_pipeline.R's build_partner_package(); the two Python
review/verify scripts (via issue_tracker.py).

**Derived/overlay only**: `prep_real_submissions.R` reads **both**
overlays for different purposes — `CONFIRMED_DELETIONS_OVERLAY.csv`
(conservative, resampling-facing, → `quality_exclusion_reason`) and
`FLAGGED_DELETIONS_OVERLAY.csv` (pessimistic, dashboard-facing, →
`flagged_deletion_reason`/`deletion_status`) — both baked into
`data/real_submissions.csv`. The comment at `:216-219` tells a human to
manually check the overlay's version.txt stamp for staleness — the script
itself never enforces this. 1_sampling's two partner-package scripts read
**CONFIRMED_DELETIONS_OVERLAY.csv directly** (not real_submissions.csv,
not the flagged overlay). `idp_real_listing_pools.csv` (built by
export_idp_real_pools.R) is a *separate* derived file with no tracker
lineage at all — don't confuse it with either deletion overlay.

Neither overlay ever includes idp_listing_duplicate, gps_duplicate, or
missing_hh_listing rows — both are filtered to `issue_type=="confirmed_deletion"`
only (build_confirmed_deletions_overlay.R:58) — so those three issue types
have zero effect on is_achieved()/deletion_status or on anything
1_sampling computes.

## 6. Downstream consumers outside this repo

1_sampling (a separate, independent git repo) has a live runtime
dependency on 2_monitoring's output. `build_partner_dc_packages.py`
(~line 455) and `refresh_partner_workbooks_daily.py` (~line 302) both read
`CONFIRMED_DELETIONS_OVERLAY.csv` directly and independently reimplement
`_is_achieved()` as a duplicated, **not imported**, mirror of
dashboard_app/global.R's logic — the same achieved-status rule maintained
in at least three places across two languages and two repos.

That mirror has a live bug: both scripts filter `status=="confirmed"`
only, omitting `"contested"` from the settled set, though
`TERMINAL_STATUSES` (issue_tracker.R:178) treats both as terminal. There
are 10 contested rows right now, all org_id=imc, resolved 2026-09-03.
IMC's package was last built 2026-09-08 — after that resolution — so if
it was sent, it likely already overstated their achieved count by 10.

## 7. Notable findings

**Stale documentation contradicting live behavior** — several files still
say "not yet wired" about integrations that have been live and writing to
production for days:
- issue_tracker.R:13-19 and issue_tracker.py:10-16 both claim not to be
  wired into full_batch_pipeline.R / verify_data_recovery_response.py —
  false; confirmed live and writing (56 rows carry confirmed_by='partner',
  a value only one call site sets).
- README.md:120-131, 199-208 repeats the same stale framing.
- verify_data_recovery_response.py's own header (8-14) says it does NOT
  write to anything live — contradicted by its own docstring three
  hundred lines later documenting the 2026-09-06 writeback.
- register_deletion_log_issues.R's header still frames registering all
  six DO reasons as the normal case; the actual filter excludes all six
  before registration — a routine run processes zero rows on that path.
- real_hh_listing.R's header describes a join the actual code never
  implements.

**Terminology risk** — `TERMINAL_STATUSES` means "excluded from
re-flagging," not "settled" or "immutable." This exact conflation
produced the 1_sampling contested-status bug.

**resolution_date non-idempotency** — present independently in three
places (issue_tracker.R, issue_tracker.py, apply_review_decisions.R), all
three unconditionally reset to Sys.Date() on every call.

**Duplicated logic, no shared source of truth**:
- apply_review_decisions.R claims to wrap apply_resolution() but never
  calls it — reimplemented inline.
- DURATION_FLOOR_MINUTES (independent_deletion_checks.R:165) and
  MISSINGNESS_STRONGNESS_FACTOR (audit_missingness.R:29) both duplicate a
  DO constant with no shared source.
- The auto-confirm block is copy-pasted near-verbatim between the
  duration and no_consent checks.
- Three independent implementations of "find the latest sampling-frame
  file": global.R's latest_frame_file(), prep_real_submissions.R's own
  copy (already caused one real production break), and sanity_checks.R's
  third, structurally different version.
- NG037-repair/dup_key logic implemented three ways — canonically in
  prep_real_submissions.R, independently re-duplicated between
  build_idp_listing_duplicates_data.R and rebuild_idp_listing_sheets.R.
  This exact duplication already caused a real partner-facing bug
  (2026-09-03: inflated availability numbers already sent to ZOA and DRC
  before the fix).
- build_workbook_fn.R self-documents its no-appeal logic as "kept in sync
  with NO_APPEAL_DELETION_REASONS, not sourced from it directly."
- The duration-cutoff policy paragraph is duplicated near-verbatim between
  build_workbook_fn.R and build_email_fn.R.

**Dead or structurally unreachable code**:
- register_deletion_log_issues.R:190-211 (daily-log bulk-confirm) can
  never execute today — its input is always pre-filtered to zero rows,
  yet still logs a "processed N files" line giving a false impression of
  work done.
- full_batch_pipeline.R:478-483 — an unguarded self-test
  (`build_partner_package("mdm")`) with no execution gate; every real
  Stage-1 run silently also builds and discards a throwaway MDM package.
- fcs_zero has no independent-check implementation anywhere, contradicting
  CLAUDE.md's "all six reasons" summary.
- build_idp_listing_duplicates_data.R may be dead/superseded by
  rebuild_idp_listing_sheets.R — not confirmed either way from text alone.

**Hardcoded, non-self-deriving values**:
- run_full_batch.R:32 — bare partner list `c("street_child","care","plan")`.
- rebuild_idp_listing_sheets.R:122 — bare `FULL_MODE_ORGS <- c("zoa")`.
- rebuild_idp_listing_sheets.R:160 and apply_returned_response.R:71 — both
  hardcode the literal date `"2026-08-30"` in a target workbook filename;
  will silently miss any newer dated workbook.
- review_recovery_response.py:243 hardcodes the same date and exits if not
  found — verify_data_recovery_response.py fixed the identical problem on
  2026-09-06 with find_latest_workbook(), but the fix was never ported
  here.
- apply_returned_response.R:86-120 — a bespoke single-case IMC/Kafin Soli
  override permanently embedded in general-purpose logic, no expiry.
- build_workbook_fn.R:3-10 — a `duration_under_30` map key whose
  description text actually describes the 20-minute reason; not among the
  current six DO reasons or five independent-check reasons — inert legacy
  or live risk, unclear from these files alone.
- export_idp_real_pools.R hardcodes a user-specific absolute Windows path;
  the file it sources uses a relative path assuming cwd=repo root — a
  portability risk given this workspace has already moved once.

**Unchecked failure modes**:
- rebuild_idp_listing_sheets.R and apply_returned_response.R both shell
  out to fix_openxlsx_roundtrip.py with no exit-status check — report
  success regardless of whether the patch worked.
- run_full_batch.R:42 — per-partner tryCatch swallows errors to console
  only; a failed partner leaves no trace in any written artifact.
- run_full_batch.R:65 — unguarded for the case where every partner errored.
- verify_data_recovery_response.py:76 — one unguarded int() parse, unlike
  nearly every other value-parse in that file.

**Path/working-directory fragility**: independent_deletion_checks.R and
register_deletion_log_issues.R both require cwd=2_monitoring root despite
living in cleaning/real/. build_confirmed_deletions_overlay.R has no
cwd-anchoring and hardcodes the tracker path a second time as a literal,
independent of issue_tracker.R's dynamic resolution. generate_review_queue.R
and apply_review_decisions.R each independently hardcode the identical
absolute PROJECT_DIR and call setwd() rather than sharing a constant.

**Silent staleness risk**: build_confirmed_deletions_overlay.R has no
assert_fresh() usage; a missing tracker path produces empty overlays with
no error, not a failure. prep_real_submissions.R tells a human to manually
check overlay staleness but never enforces it in code. register_issues()
rewrites the tracker's mtime on every call even with zero content change
— relevant given the workspace's mtime-based assert_fresh() mechanism.

**Two coexisting review mechanisms, not confirmed reconciled**:
review_recovery_response.py frames itself as *the* human review step
(built 2026-09-03); CLAUDE.md's "review-queue engine" describes a
materially different, newer chat-based mechanism as current practice.
Whether the Python CLI is still actually run in practice post-2026-09-08
was not verifiable from code alone.

**Double-write path for Confirmed Deletions**: review_recovery_response.py
calling verify_confirmed_deletions() with apply_writeback=True by default
means every run of the former silently re-triggers the latter's own
writeback before the operator is prompted — two different
resolution-text/confirmed_by conventions land depending on whether the row
pre-existed, and the Python CLI's own printed tally undercounts.

**No shared guard against re-deciding a terminal row**: neither
apply_resolution() implementation (R or Python) internally prevents
overwriting an already-settled row — every caller reimplements this
protection independently. apply_review_decisions.R additionally enforces
its own stricter rule (confirmed requires confirmed_by) that
issue_tracker.R's own apply_resolution() explicitly declines to enforce.

**Scope/ownership notes**: apply_returned_response.R and
apply_review_decisions.R are two distinctly-purposed scripts with easily
confused names. apply_returned_response.R bypasses issue_tracker.R's API
entirely. summarise_cleaning_logs.R implements its own severity
classification for "should this be deleted" that is completely separate
from, and never wired into, the tracker's vocabulary — a tier-A row only
surfaces on a human-facing sheet, never auto-creates a tracker row.
sanity_checks.R documents a real, still-unresolved cross-project question
(flagged 2026-09-09) about which script owns the accessibility-layer
freshness-stamp format between 2_monitoring and 1_sampling. The legacy
CONFIRMED_QUALITY_EXCLUSIONS.csv is deliberately left in place indefinitely
after being superseded — same class of issue as the five stale
`.bak_pre_*` tracker files already flagged for archiving.
