# ==============================================================================
# Python counterpart to issue_tracker.R - same CSV
# (recovery_issue_tracker.csv, same directory), same schema, so the
# generation side (R) and the verification side (Python,
# verify_data_recovery_response.py) can both read/update cross-batch state
# without needing to shell out to the other language. See issue_tracker.R's
# own header for the full schema/lifecycle documentation - not repeated
# here, keep both files' comments in sync if the schema changes.
#
# UPDATED 2026-09-11 (was stale since 2026-09-03): this IS called from
# verify_data_recovery_response.py's verify_confirmed_deletions() (live
# since 2026-09-06 - confirmed against production data, 56+ rows carry
# confirmed_by='partner', a value only that one call site ever writes) and
# from review_recovery_response.py's interactive review loop, which also
# calls ensure_issue() for issue types generation didn't pre-register. The
# header used to say this wiring was "a following step" - it happened days
# ago and the comment was never updated.
# ==============================================================================
import csv
import datetime
import os

TRACKER_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "recovery_issue_tracker.csv")

COLUMNS = [
    "issue_id", "issue_type", "deletion_reason", "org_id", "cluster_id", "strata_id", "uuid", "listing_number",
    "status", "detected_date", "first_batch_date", "last_batch_date", "rounds_outstanding",
    "resolution", "resolution_date", "confirmed_by", "recovery_type", "notes",
]
# Schema note (2026-09-06): deletion_reason/rounds_outstanding/confirmed_by/
# recovery_type added - see issue_tracker.R's header for the full schema
# doc, kept in sync between both files.

# NAMING CAUTION (added 2026-09-11, after this exact conflation produced a
# real bug in 1_sampling's partner-package scripts, which filtered
# status=="confirmed" only): "terminal" here means ONLY "excluded from
# re-flagging / excluded from get_unresolved_issue_ids()". It does NOT
# mean "settled" or "immutable" - apply_resolution() can still move a
# contested row to confirmed later via allow_reopen=True. Both statuses
# are equally terminal for achieved-status purposes; code that treats
# "confirmed" as more final/trustworthy than "contested" is almost
# certainly wrong.
TERMINAL_STATUSES = {"confirmed", "contested"}


def read_tracker():
    if not os.path.exists(TRACKER_PATH):
        return []
    with open(TRACKER_PATH, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    # Backfill any COLUMNS missing from an on-disk tracker written before a
    # schema addition - mirrors issue_tracker.R's read_tracker() migration.
    for row in rows:
        for col in COLUMNS:
            row.setdefault(col, "")
    return rows


def write_tracker(rows):
    with open(TRACKER_PATH, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)


def ensure_issue(issue_type, org_id, cluster_id, uuid=None, listing_number="", strata_id="", status="sent"):
    """Inserts a row for this issue if it doesn't exist yet (status
    defaults to "sent" - the caller is reviewing a RETURNED response, so by
    definition a workbook carrying this row was already sent). No-op if
    the issue_id is already present - existing status/history is left
    alone. Used by review_recovery_response.py so review/resolution can
    happen even for issues generation never explicitly registered via
    issue_tracker.R's register_issues() (e.g. gps_duplicate/
    idp_listing_duplicate rows, which that script's checks don't create).
    Returns the issue_id."""
    issue_id = build_issue_id(issue_type, uuid=uuid, cluster_id=cluster_id)
    rows = read_tracker()
    if any(r["issue_id"] == issue_id for r in rows):
        return issue_id
    today = datetime.date.today().isoformat()
    rows.append({
        "issue_id": issue_id, "issue_type": issue_type, "org_id": org_id,
        "cluster_id": cluster_id or "", "strata_id": strata_id or "",
        "uuid": uuid or "", "listing_number": str(listing_number) if listing_number else "",
        "status": status, "detected_date": today, "first_batch_date": today,
        "last_batch_date": today, "resolution": "", "resolution_date": "", "notes": "",
    })
    write_tracker(rows)
    return issue_id


def apply_resolution(issue_id, new_status, resolution="", resolution_date=None,
                      confirmed_by="", recovery_type="", allow_reopen=False):
    """Records a resolution against one issue_id, e.g. once
    verify_data_recovery_response.py has confirmed a row's CONFIRMED
    Household ID / Listing Number passes every check. new_status must be
    one of confirmed/rejected/contested. Returns True if the issue_id was
    found, not already terminal (or allow_reopen=True), and updated;
    False otherwise (logs a warning either way via the caller - this
    function doesn't raise, matching issue_tracker.R's apply_resolution()
    behaviour).

    allow_reopen (added 2026-09-11): by default this function now REFUSES
    to overwrite a row already at a TERMINAL_STATUS, mirroring the guard
    every real caller used to reimplement independently (this file's own
    callers already check status before calling, so this should be a
    no-op change for them - it exists to protect any future caller that
    doesn't). Pass allow_reopen=True to deliberately re-decide an
    already-terminal row (e.g. settling a contested row to confirmed).

    confirmed_by ("partner"/"internal_team") and recovery_type
    ("false_positive"/"justified_exception") mirror issue_tracker.R's same
    params (added 2026-09-06) - pass whichever applies to the calling
    context; left blank (not overwritten) if omitted.

    resolution_date (fixed 2026-09-11): NA-guarded like confirmed_by/
    recovery_type instead of unconditionally defaulting to today on every
    call - an explicitly-passed date always wins, otherwise today's date
    is only written on a row's FIRST resolution (existing value blank);
    a later call preserves whatever date is already there."""
    if new_status not in ("confirmed", "rejected", "contested"):
        raise ValueError(f"new_status must be confirmed/rejected/contested, got {new_status!r}")
    rows = read_tracker()
    found = False
    for row in rows:
        if row["issue_id"] == issue_id:
            if row["status"] in TERMINAL_STATUSES and not allow_reopen:
                import warnings
                warnings.warn(
                    f"apply_resolution(): issue_id {issue_id} is already at a terminal "
                    f"status ({row['status']!r}) - refusing to overwrite. Pass "
                    "allow_reopen=True if this is a deliberate re-decision."
                )
                return False
            row["status"] = new_status
            row["resolution"] = resolution
            row["resolution_date"] = resolution_date or row["resolution_date"] or datetime.date.today().isoformat()
            if confirmed_by:
                row["confirmed_by"] = confirmed_by
            if recovery_type:
                row["recovery_type"] = recovery_type
            found = True
            break
    if found:
        write_tracker(rows)
    return found


def get_unresolved_issue_ids(org_id=None, issue_type=None):
    """The set of issue_ids NOT yet resolved (pending/sent/rejected) -
    mirrors issue_tracker.R's get_unresolved_issue_ids()."""
    rows = read_tracker()
    out = []
    for row in rows:
        if row["status"] in TERMINAL_STATUSES:
            continue
        if org_id is not None and row["org_id"] != org_id:
            continue
        if issue_type is not None and row["issue_type"] != issue_type:
            continue
        out.append(row["issue_id"])
    return out


def build_issue_id(issue_type, uuid=None, cluster_id=None):
    """Mirrors issue_tracker.R's build_issue_id() - same key convention
    (missing_hh_listing keys on cluster_id, every other type keys on uuid)."""
    key = cluster_id if issue_type == "missing_hh_listing" else uuid
    if not key:
        raise ValueError(f"build_issue_id(): missing key for issue_type={issue_type!r}")
    return f"{issue_type}::{key}"
