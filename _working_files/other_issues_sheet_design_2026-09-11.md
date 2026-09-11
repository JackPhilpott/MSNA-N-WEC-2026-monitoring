# Other Issues Sheet — Design, Wiring, Safety Plan, Build Order

Produced 2026-09-11 via an 11-agent workflow: 10 parallel deep-reads (full
file reads, not summaries) across the 1_sampling accessibility pipeline and
2_monitoring's own recovery-workbook pipeline, then one synthesis pass.
Every code claim below was verified by directly reading the cited
file/lines, not taken from a secondary summary.

All paths below are relative to `2_monitoring/` unless stated otherwise.

---

## 1. What Other Issues needs to contain and look like

**Both new reasons are registered identically at the tracker level** —
`issue_type="confirmed_deletion"`, `deletion_reason` = `"date_outlier"` or
`"crs_unmatched"` (`cleaning/real/independent_deletion_checks.R:452-522`),
uuid-keyed (`build_issue_id()`, `issue_tracker.R:224-229` keys on uuid for
every issue_type except `missing_hh_listing`), appealable (neither reason
is in `NO_APPEAL_DELETION_REASONS = c("duration_under_20","no_consent")`,
`issue_tracker.R:181`). **But the underlying problems are genuinely
different**, confirmed directly in the tracker CSV:

- `date_outlier` rows (3, all `org_id=nrc`) carry a normal `cluster_id`
  (e.g. `idp_NG002020_6`) — the interview *is* matched to a point, only its
  `submission_date`/`start_datetime` are corrupted.
- `crs_unmatched` rows (19 new tonight, all `org_id=crs`) carry
  **`cluster_id` blank** for every row — there is no cluster to anchor a
  correction to at all.

So the sheet needs one shared identity/location block, a shared reason
block, and **two disjoint response-column pairs**, not one explain-yourself
box — matching exactly how Confirmed Deletions already splits
appealable/no-appeal presentation *within one column* rather than two
headers. `verify_data_recovery_response.py`'s `check_headers_and_alignment()`
compares one literal header list per sheet name, position-sensitive — so
the sheet **must** have one flat header, with the non-applicable response
pair left `NA` per row.

Proposed 13-column layout (order is load-bearing — see Test 7):

| # | Column | Notes |
|---|---|---|
| 1 | Interview ID | uuid — must be literally this string, the id-column detector keys on it |
| 2 | Enumerator ID | reuse `del_enum_id` join already built in `confirmed_deletion_all` |
| 3 | State | `del_state` |
| 4 | LGA | `del_lga` |
| 5 | Ward | `del_ward` |
| 6 | Cluster ID | `del_cluster_id` — **legitimately blank for every `crs_unmatched` row**; say so in the README |
| 7 | Issue Type | "Date Outlier" / "CRS Unmatched" |
| 8 | What We Found | reason text, from a new `other_issue_text_map` (mirrors `reason_text_map`) |
| 9 | Corrected Interview Date (if known) | **date_outlier only**, NA otherwise |
| 10 | Genuine Interview on That Date? (Yes/No/Unsure) | **date_outlier only**, dropdown scoped to those rows only |
| 11 | Correct Cluster/Site ID (if known) | **crs_unmatched only**, free text — no candidate-suggestion possible, unlike GPS Duplicates |
| 12 | Can Your Team Identify This Household? (Yes/No) | **crs_unmatched only**, dropdown scoped to those rows only |
| 13 | Notes / Explanation | shared, both types |

Both dropdowns row-scoped (never whole-column) — a Yes/No/Unsure on a
crs_unmatched row would be meaningless.

---

## 2. Exact wiring, function by function

**A. `issue_tracker.R`/`.py` — no change.** Already generic over
issue_type/deletion_reason.

**B. `independent_deletion_checks.R` — no change.** Already built, already ran.

**C. `full_batch_pipeline.R` → `build_partner_package()` — 2 changes.**
- **C.1 — fix the sheet-routing filter, line 153.** Today:
  `del_all_org <- confirmed_deletion_all %>% filter(org_id == org, deletion_reason != "listing_missing" | is.na(deletion_reason))`
  This does NOT exclude date_outlier/crs_unmatched — without this fix both
  would flow straight into Confirmed Deletions with a generic Yes/No
  Contest box. Change to exclude both new reasons too.
- **C.2 — add an `other_sheet` block**, modeled on the Missing HH Listings
  block. **Open question — see §6.1.**

**D. `build_workbook_fn.R` — add a sheet block.** Always `addWorksheet()`
(matches the recurring-sheet convention, not the sometimes-omitted-when-
empty GPS/IDP convention) — this sheet is meant to be an ongoing home for
future ad hoc checks, per Jack's own framing.

**E. `build_email_fn.R` — add a section.** Recommend the `input_para`
(actionable) template over the FYI `oversampled_para` template — **flagged
for confirmation, §6.2**, since it changes the `total_needing_input`
headline partners see. Miss the `EMAIL_SECTION_HEADERS` entry and it fails
*silently*, not with an error — specific test-plan item.

**F. `verify_data_recovery_response.py`.** New `EXPECTED_HEADERS` entry +
`verify_other_issues()` modeled on `verify_missing_hh_listings()` — **not**
`verify_confirmed_deletions()`. Deliberately **no** `apply_writeback` path:
unlike an uncontested Confirmed Deletion, both new reasons need a real
judgment call on the correction itself, not a silent auto-apply.

**G. `review_recovery_response.py`.** New `review_other_issues()` modeled
on `review_gps_duplicates()`. Reuses `already_resolved()` unmodified — Other
Issues rows share the exact same issue_id key space as Confirmed
Deletions. **Critical divergence**: must use the skip-if-blank shape (GPS/
IDP/Missing-HH pattern), NOT `review_confirmed_deletions()`'s auto-apply-
if-uncontested shape — a blank row must stay pending, per Jack's own words.

**H. `apply_returned_response.R` — add a 5th merge block.** Reuses
`tracker_lookup()` unmodified. Also closes a gap the other 4 sheets don't
have: handle a row present in the partner's return but absent from the
current master (today only the reverse direction — master has it, return
doesn't — is handled).

**I. `generate_review_queue.R`/`apply_review_decisions.R` — no generation
change, one real fix needed.** `generate_review_queue()` groups by
`(issue_type, deletion_reason)` with zero dependency on which sheet a
reason lives in — the chat engine **already sees tonight's new rows with
no wiring at all**. But see §3/§6.3 for a real bug found here.

---

## 3. The safety pattern — a correction to the stated premise

Verified against real code, not header comments: **the accessibility
pipeline is not actually the stronger reference.**
`01_generate_accessibility_reports.py` builds a brand-new workbook and
unconditionally overwrites the per-partner file every run, zero
merge-preserve logic — its own header comment admits this ("do NOT rerun
this script" once a partner has filled anything in — a rule enforced by a
human remembering it, not by code). `generate_review_queue_accessibility.py`
has no confirmed/terminal concept at all on that side.

2_monitoring's own pipeline is already the stronger one on the exact
question asked — never lose/overwrite partner feedback:
1. `apply_returned_response.R` never writes back to the partner's own
   file — only ever reads it, writes exclusively to a separate master copy.
2. Every merge matches by uuid, never row position.
3. The terminal-status guard (added tonight) lives once, in `apply_resolution()`
   itself — every new call site inherits it automatically.
4. `already_resolved()` skips an already-terminal row before a human is
   even asked.
5. Registration reruns are already idempotent.

The two pipelines share *shape* (classify → stage → apply); on the
specific safety question, 2_monitoring is the one to extend, not import from.

---

## 4. Concrete test plan (7 tests)

1. **Registration rerun is a no-op** — run both new checks twice, assert
   identical tracker state.
2. **Sheet-routing disjointness** — assert zero overlap between
   `del_sheet` and `other_sheet` uuids; this is the actual regression risk
   of the §2C.1 fix (a filter typo mis-routes, doesn't drop).
3. **Terminal-row protection blocks a stale rerun**, end to end (approve,
   rerun, confirm no re-prompt; call `apply_resolution()` twice without
   `allow_reopen`, confirm the 2nd call is refused and nothing on disk changes).
4. **`apply_returned_response.R` never touches the returned file** — hash
   before/after, assert identical. Recommend as a standing regression
   check for this file generally, not just this feature.
5. **Reverse-direction merge gap** — a synthetic returned row not in the
   current master must be logged, not silently vanish.
6. **The actual race Jack asked about — and it's real, today, independent
   of Other Issues.** Approve a row via `review_recovery_response.py`
   (status → confirmed), then run `apply_review_decisions.R` targeting the
   same row with a conflicting decision. **Verified directly:
   `apply_review_decisions.R` writes the tracker with a raw dataframe
   mutation, never calls `apply_resolution()`, has no terminal-status check
   at all.** This test currently **fails** — a chat-based decision can
   silently overwrite what the Python reviewer just decided, for ANY
   reason type already, not just the two new ones. Needs fixing (route
   through `apply_resolution()`) before Phase 3, not scoped to this feature.
7. **Full cycle dry run** — build workbook → hand-fill synthetic returns
   (accept/reject/blank) → verify → review → apply → rebuild fresh → assert
   the rejected row is still present (proves "reject stays pending, only
   unresolved carries to next round").

---

## 5. Build order

**Phase 1 — Sheets only, nothing sent.** Settle §6.1/§6.2 first → fix
`full_batch_pipeline.R` line 153 + add `other_sheet` → `build_workbook_fn.R`
→ `build_email_fn.R` → checkpoint: build clean for every affected partner
(currently just `nrc` and `crs`), zero disjointness failures.

**Phase 2 — Full cycle, proven before any real partner sees anything.**
`verify_data_recovery_response.py` → `review_recovery_response.py` →
`apply_returned_response.R` (with the reverse-gap fix) → **fix
`apply_review_decisions.R`'s guard gap** (cross-cutting, must land before
Phase 3) → run Test 7 end to end against a real (not-yet-sent) workbook
with synthetic returns → run Test 6 explicitly, confirm fail-before/
pass-after → checkpoint: Jack reviews one real sheet before anything goes out.

**Phase 3 — Batch send, everything flagged tonight together.** Add an
`other` count to `run_full_batch.R`'s summary → run Stage 1 for all
partners (this already includes today's `duration_under_20` auto-confirms
and the two new reasons automatically, same `build_partner_package()`
call) → Jack reviews the batch summary + individual workbooks (existing
gate, unchanged) → Stage 2 emails → send.

---

## 6. Flagged, not resolved

1. **Unresolved-scoping for `other_sheet` is genuinely undecided.**
   Confirmed Deletions' existing behavior resurfaces resolved *appealable*
   rows in every future batch forever; the chat engine's own queue
   generator strictly separates terminal from needs-review. These two
   existing behaviors already disagree with each other today. Jack's own
   words tonight ("next round only includes unresolved items") point
   toward strict `!status %in% TERMINAL_STATUSES` for `other_sheet` — which
   would make it behave differently from Confirmed Deletions on purpose.
   **Needs Jack's explicit call before Phase 1.**
2. **Email framing** (actionable vs. informational) — recommend
   actionable; changes a headline count partners see; confirm before it ships.
3. **`apply_review_decisions.R` bypasses the terminal-status guard
   entirely, today, for every reason type** — not new, not scoped to this
   feature, but surfaced by this work and should be fixed before Phase 3.
4. **The reverse-direction merge gap exists today for all 4 existing
   sheets**, not just the new one — the new sheet is designed to not
   inherit it, but whether to retrofit the existing 4 is a separate
   decision this surfaced, not made here.
5. **The accessibility-pipeline-as-safety-model framing itself needed
   correcting** (§3) — said plainly rather than quietly built around.
6. **`crs_unmatched` rows carry a `strata_id` containing the literal
   substring "NA_"** (e.g. `NA_NG032002`) — not traced whether this is a
   real strata_id or a stringified-NA leak from upstream matching. Worth
   confirming before treating it as meaningful anywhere downstream.
7. **A small, pre-existing, unrelated inconsistency noticed in passing**:
   `review_confirmed_deletions()`'s auto-confirm path never sets
   `confirmed_by`, unlike its Excel-verify-side equivalent, which always
   sets `confirmed_by="partner"`. Not in this feature's scope, flagged
   since `issue_tracker.R` explicitly says this should never be left to infer.
8. **Only 19 of the 27 existing `crs_unmatched` rows are new tonight** — the
   other 8 predate tonight's registration by some mechanism not traced.
   Worth a quick status check before the Phase 3 batch send to rule out a
   stale/orphaned earlier batch.
