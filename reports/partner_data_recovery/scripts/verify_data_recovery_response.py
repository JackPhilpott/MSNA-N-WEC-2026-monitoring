# ==============================================================================
# Verifies a partner's RETURNED copy of the 2026-08-30 data_recovery_workbook
# (2_monitoring/reports/partner_data_recovery/outputs/<Partner>/<Partner>_
# data_recovery_workbook_2026-08-30.xlsx, sent out per the READ ME sheet
# inside each file) before any of it is trusted or integrated anywhere.
# Built 2026-09-01 per Jack: partner responses are expected to have "lots of
# errors and issues", same as every other partner-input file this project
# ingests (accessibility reports, KML feedback, etc.) - this is a
# CHECKING/VERIFICATION step only. It does NOT write to real_submissions.csv,
# the sampling frame, or anything else live - that integration is a
# separate, later, explicitly-approved step per row outcome (some rows
# recover a submission, some confirm a deletion, some need a fresh listing
# picked up by the resampling side - three different downstream homes,
# which is exactly why this stays a standalone verification pass for now).
#
# Usage:
#   python verify_data_recovery_response.py <Partner> <path_to_returned_xlsx>
#   (put the returned file in reports/partner_data_recovery/inputs/<Partner>/
#   first, per that folder's own convention)
#   Writes <Partner>_verification_findings_<date>.csv next to the input
#   file (one row per issue found, not one row per workbook row - a clean
#   row contributes zero rows to the output) plus a console summary.
#
# Validated per sheet, derived directly from each sheet's own READ ME
# instructions (see 2_monitoring/reports/partner_data_recovery/outputs/
# <Partner>/<Partner>_data_recovery_workbook_2026-08-30.xlsx's "READ ME"
# tab) and from the row-level ground truth already present in the workbook
# itself (Cluster Availability's "Still Available" list, "Total Numbers
# Available in Cluster") - NOT from the workbook's own Excel dropdown
# definitions, which openpyxl cannot read (extLst-format data validation,
# silently dropped on load - confirmed 2026-09-01, "Data Validation
# extension is not supported" warning). Every row-count/Interview-ID/header
# check below compares the RETURNED file against the ORIGINAL outgoing copy
# still sitting in 2_monitoring/reports/partner_data_recovery/outputs/
# <Partner>/ - the strongest available integrity check, since a partner
# could otherwise reorder, delete, or accidentally overwrite the pre-filled
# reference columns without it being obvious from the returned file alone.
#
# 2026-09-03: moved here from cleaning/real/data_recovery_responses/ as
# part of consolidating the whole recovery-workbook pipeline (generation +
# verification + state tracking) into one place that mirrors the actual
# workflow - see this folder's own README.md for the full layout.
# ==============================================================================
import csv
import datetime
import os
import re
import sys

from xlsx_repair import load_repaired_workbook
import issue_tracker

MONITORING_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
RECOVERY_DIR = os.path.join(MONITORING_ROOT, "reports", "partner_data_recovery", "outputs")
IDP_REAL_POOLS_CSV = os.path.join(os.path.dirname(__file__), "idp_real_listing_pools.csv")

# BUG FIX 2026-09-06: verify_idp_listing_duplicates() used to flag CONFIRMED
# Listing Number > "Total Numbers Available in Cluster" as an ERROR - found
# reviewing DRC/ACF/FACT's returned workbooks that this compares a real
# listing NUMBER against a COUNT of remaining open slots, not against any
# real upper bound (a Tier-1 IDP household listing can legitimately run into
# the hundreds, unrelated to how many slots are still needed for target).
# Checked directly: every one of DRC's 14 "over the count" confirmed numbers
# turned out to be a genuine real household in that cluster's actual HH
# Listing RandomSelect KoBo tool submission. Replaced with a real membership
# check against idp_real_listing_pools.csv (export_idp_real_pools.R, sourced
# from the same real listing data full_batch_pipeline.R now uses) - falls
# back to the old count-based check only for a cluster with no real listing
# data on file at all, same fallback rule real_hh_listing.R itself uses.
def load_idp_real_pools():
    pools = {}
    if not os.path.exists(IDP_REAL_POOLS_CSV):
        return pools
    with open(IDP_REAL_POOLS_CSV, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            pools.setdefault(row["cluster_id"], set()).add(int(row["listing_number"]))
    return pools

# Must match build_workbook_fn.R's NO_APPEAL_CONTEST_NOTE exactly (2026-09-06)
# - rows with this exact text in "Contest This? (Yes/No)" are the validated-
# methodology-threshold reasons (duration/fcs_zero) that were never actually
# open to contest; a partner returning the workbook unchanged for these rows
# would otherwise trip the "not Yes/No" warning below on every single one.
NO_APPEAL_CONTEST_NOTE = "No action needed -- confirmed per validated assessment methodology, not open to contest."

SURVEY_ID_RE = re.compile(r"^(non_idp|idp)_(NG\d{6})_(\d+)_(HH|R)\d+$")
DATE_FORMATS = ("%Y-%m-%d", "%d/%m/%Y", "%Y-%m-%d %H:%M:%S")

EXPECTED_HEADERS = {
    "GPS Duplicates & Distant Pts": [
        "Interview ID", "Enumerator ID", "State", "LGA", "Ward", "Date of Submission",
        "Point ID Recorded", "Cluster ID", "Distance From Recorded Point (m)", "Match Confidence",
        "Households Still Available in Cluster", "Option 1 - Nearby Household", "Distance to Option 1 (m)",
        "Option 2 - Nearby Household", "Distance to Option 2 (m)", "Option 3 - Nearby Household",
        "Distance to Option 3 (m)", "CONFIRMED Household ID", "Genuine, Distinct Visit? (Yes/No/Unsure)",
        "Notes / Explanation",
    ],
    "IDP Listing Duplicates": [
        "Interview ID", "Enumerator ID", "State", "LGA", "Ward", "Date of Submission", "Cluster/Site ID",
        "Listing Number Recorded", "Nearest Unclaimed Numbers", "Total Numbers Available in Cluster",
        "CONFIRMED Listing Number", "Notes / Explanation",
    ],
    "Missing HH Listings": [
        "Cluster/Site ID", "IOM Site Name", "Population Type", "State", "LGA", "Ward",
        "Target Households (required sample)", "Households in Cluster (population estimate)",
        "Affected Interviews", "Interview IDs Affected", "Household Listing Now Submitted? (Yes/No)",
        "Date Submitted (if Yes)", "Notes / Explanation",
    ],
    "Confirmed Deletions": [
        "Interview ID", "Enumerator ID", "State", "LGA", "Ward", "Cluster ID", "Reason",
        "Contest This? (Yes/No)", "If Yes, Explain",
    ],
    # ADDED 2026-09-11 - must match build_workbook_fn.R's other_sheet
    # transmute() column order EXACTLY (two languages, no shared source of
    # truth for this list - a mismatch here fails silently as a header
    # ERROR, not a crash).
    "Other Issues": [
        "Interview ID", "Enumerator ID", "State", "LGA", "Ward", "Cluster ID",
        "Issue Type", "What We Found", "Corrected Interview Date (if known)",
        "Genuine Interview on That Date? (Yes/No/Unsure)", "Correct Cluster/Site ID (if known)",
        "Can Your Team Identify This Household? (Yes/No)", "Notes / Explanation",
    ],
}


def col_index(header, name):
    return header.index(name)


def sheet_rows(ws, header):
    idx = {h: i for i, h in enumerate(header)}
    for r in range(2, ws.max_row + 1):
        row = [ws.cell(row=r, column=c + 1).value for c in range(len(header))]
        if all(v is None for v in row):
            continue
        yield r, {h: row[idx[h]] for h in header}


def parse_date_flexible(raw, today):
    """Same tolerant-format / future-date-is-unparseable philosophy as
    04_build_master_accessibility_status.py's parse_date_flexible() in
    1_sampling - deliberately not imported (this project's standalone-
    script convention), reused here because partner date fields hit the
    exact same DD/MM/YYYY-vs-YYYY-MM-DD ambiguity and Excel-autofill-drag
    risk that motivated it there."""
    if raw is None:
        return None
    if isinstance(raw, datetime.datetime):
        d = raw.date()
        return d if d <= today else None
    if isinstance(raw, datetime.date):
        return raw if raw <= today else None
    raw = str(raw).strip()
    if not raw:
        return None
    for fmt in DATE_FORMATS:
        try:
            d = datetime.datetime.strptime(raw, fmt).date()
        except ValueError:
            continue
        return d if d <= today else None
    return None


class Findings:
    def __init__(self):
        self.rows = []

    def add(self, sheet, row_num, severity, issue, detail=""):
        self.rows.append({"sheet": sheet, "row": row_num, "severity": severity, "issue": issue, "detail": detail})

    def write_csv(self, path):
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["sheet", "row", "severity", "issue", "detail"])
            w.writeheader()
            w.writerows(self.rows)


def check_headers_and_alignment(wb_orig, wb_ret, findings):
    """Every actionable sheet must exist, have the same header order, and
    the same set of Interview ID / Cluster ID (or Cluster/Site ID) values
    in the same row order as what was actually sent - a partner reordering,
    deleting, or adding rows breaks every positional assumption below."""
    for sheet_name, expected_header in EXPECTED_HEADERS.items():
        if sheet_name not in wb_ret.sheetnames:
            findings.add(sheet_name, None, "ERROR", "Sheet missing from returned workbook entirely")
            continue
        ws_ret = wb_ret[sheet_name]
        actual_header = [c.value for c in ws_ret[1]]
        if actual_header != expected_header:
            findings.add(sheet_name, 1, "ERROR", "Header row does not match the sent template",
                         f"expected={expected_header} actual={actual_header}")
            continue  # positional checks below aren't safe if headers moved

        ws_orig = wb_orig[sheet_name]
        id_col = "Interview ID" if "Interview ID" in expected_header else "Cluster/Site ID"
        orig_ids = [r[1][id_col] for r in sheet_rows(ws_orig, expected_header)]
        ret_ids = [r[1][id_col] for r in sheet_rows(ws_ret, expected_header)]
        if orig_ids != ret_ids:
            missing = set(orig_ids) - set(ret_ids)
            added = set(ret_ids) - set(orig_ids)
            detail = f"missing={sorted(missing)[:10]} unexpected_new={sorted(added)[:10]} (order/count changed)"
            findings.add(sheet_name, None, "ERROR", f"Row set/order for '{id_col}' no longer matches what was sent", detail)


def verify_gps_duplicates(ws, cluster_availability, findings):
    sheet = "GPS Duplicates & Distant Pts"
    header = EXPECTED_HEADERS[sheet]
    seen_confirmed = {}  # confirmed_id -> first row that used it
    for row_num, r in sheet_rows(ws, header):
        confirmed = (r["CONFIRMED Household ID"] or "").strip() if r["CONFIRMED Household ID"] else ""
        genuine = (r["Genuine, Distinct Visit? (Yes/No/Unsure)"] or "").strip() if r["Genuine, Distinct Visit? (Yes/No/Unsure)"] else ""
        notes = (r["Notes / Explanation"] or "").strip() if r["Notes / Explanation"] else ""
        cluster_id = r["Cluster ID"]

        if not confirmed and not genuine and not notes:
            # FIXED 2026-09-11 (Jack): no longer true that a non-response
            # gets excluded from Achieved - only an automatic no-appeal
            # deletion or an actually-confirmed-incorrect resolution does.
            # A blank row now just stays pending.
            findings.add(sheet, row_num, "INFO", "No response - stays pending/unresolved")
            continue

        if genuine and genuine.lower() not in ("yes", "no", "unsure"):
            findings.add(sheet, row_num, "WARNING", "Genuine/Distinct Visit answer is not Yes/No/Unsure", f"got={genuine!r}")

        if confirmed:
            m = SURVEY_ID_RE.match(confirmed)
            if not m:
                findings.add(sheet, row_num, "ERROR", "CONFIRMED Household ID is not a recognisable survey_id format", f"got={confirmed!r}")
                continue
            confirmed_cluster = f"{m.group(1)}_{m.group(2)}_{m.group(3)}"
            if confirmed_cluster != cluster_id:
                findings.add(sheet, row_num, "ERROR",
                             "CONFIRMED Household ID belongs to a different cluster than this interview was assigned to",
                             f"confirmed_cluster={confirmed_cluster} row_cluster={cluster_id}")
            available = cluster_availability.get(cluster_id)
            if available is not None and confirmed not in available:
                findings.add(sheet, row_num, "WARNING",
                             "CONFIRMED Household ID is not in that cluster's 'Still Available' list (already claimed, or a typo)",
                             f"confirmed={confirmed}")
            if confirmed in seen_confirmed:
                findings.add(sheet, row_num, "ERROR",
                             "Same CONFIRMED Household ID used to resolve more than one flagged interview in this workbook",
                             f"also used at row {seen_confirmed[confirmed]}")
            else:
                seen_confirmed[confirmed] = row_num
        elif genuine.lower() == "yes":
            findings.add(sheet, row_num, "WARNING", "Marked as a genuine, distinct visit but no CONFIRMED Household ID given")


def verify_idp_listing_duplicates(ws, findings, real_pools=None):
    sheet = "IDP Listing Duplicates"
    header = EXPECTED_HEADERS[sheet]
    real_pools = real_pools or {}
    seen_confirmed = {}  # (cluster, number) -> first row
    for row_num, r in sheet_rows(ws, header):
        confirmed = r["CONFIRMED Listing Number"]
        notes = (r["Notes / Explanation"] or "").strip() if r["Notes / Explanation"] else ""
        cluster_id = r["Cluster/Site ID"]
        total_available = r["Total Numbers Available in Cluster"]

        if confirmed is None and not notes:
            # FIXED 2026-09-11 (Jack): see the identical fix in
            # verify_gps_duplicates() above.
            findings.add(sheet, row_num, "INFO", "No response - stays pending/unresolved")
            continue

        if confirmed is not None:
            try:
                confirmed_n = int(confirmed)
            except (ValueError, TypeError):
                findings.add(sheet, row_num, "ERROR", "CONFIRMED Listing Number is not a whole number", f"got={confirmed!r}")
                continue
            if confirmed_n < 1:
                findings.add(sheet, row_num, "ERROR", "CONFIRMED Listing Number is below 1", f"got={confirmed_n}")
            cluster_pool = real_pools.get(cluster_id)
            if cluster_pool is not None:
                if confirmed_n not in cluster_pool:
                    findings.add(sheet, row_num, "ERROR",
                                 "CONFIRMED Listing Number isn't in this cluster's actual HH Listing tool submission",
                                 f"confirmed={confirmed_n} cluster={cluster_id}")
            elif isinstance(total_available, (int, float)) and confirmed_n > total_available:
                # No real listing data for this cluster at all - fall back to
                # the count-based check (weak, but better than nothing).
                findings.add(sheet, row_num, "WARNING",
                             "CONFIRMED Listing Number exceeds the total numbers available in this cluster "
                             "(no real HH Listing tool data for this cluster to check against directly)",
                             f"confirmed={confirmed_n} total_available={total_available}")
            if confirmed_n == r["Listing Number Recorded"]:
                findings.add(sheet, row_num, "INFO",
                             "CONFIRMED Listing Number matches the originally-recorded (disputed) number - confirm this is intentional")
            key = (cluster_id, confirmed_n)
            if key in seen_confirmed:
                findings.add(sheet, row_num, "ERROR",
                             "Same CONFIRMED Listing Number used twice in the same cluster in this workbook",
                             f"also used at row {seen_confirmed[key]}")
            else:
                seen_confirmed[key] = row_num


def verify_missing_hh_listings(ws, findings, today):
    sheet = "Missing HH Listings"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        submitted = (r["Household Listing Now Submitted? (Yes/No)"] or "").strip() if r["Household Listing Now Submitted? (Yes/No)"] else ""
        date_submitted = r["Date Submitted (if Yes)"]
        notes = (r["Notes / Explanation"] or "").strip() if r["Notes / Explanation"] else ""

        if not submitted and not notes:
            findings.add(sheet, row_num, "INFO", "No response yet")
            continue
        if submitted and submitted.lower() not in ("yes", "no"):
            findings.add(sheet, row_num, "WARNING", "Answer is not Yes/No", f"got={submitted!r}")
        if submitted.lower() == "yes":
            if date_submitted is None:
                findings.add(sheet, row_num, "ERROR", "Marked submitted but no Date Submitted given")
            else:
                parsed = parse_date_flexible(date_submitted, today)
                if parsed is None:
                    findings.add(sheet, row_num, "ERROR", "Date Submitted is unparseable or in the future", f"got={date_submitted!r}")
        elif submitted.lower() == "no" and not notes:
            findings.add(sheet, row_num, "WARNING", "Marked not yet submitted with no explanation - worth a follow-up")


def verify_other_issues(ws, findings, today):
    """ADDED 2026-09-11. Modeled on verify_missing_hh_listings() above, not
    verify_confirmed_deletions() - both date_outlier and crs_unmatched need
    a real judgment call on the correction itself (is the date plausible?
    is the claimed cluster right?), so this is deliberately findings-only,
    same as GPS/IDP/Missing-HH - no apply_writeback path. Each row is
    exactly one of two different problems (Issue Type column) with its own
    disjoint response-column pair; the other pair should be blank."""
    sheet = "Other Issues"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        issue_type = (r["Issue Type"] or "").strip()
        corrected_date = r["Corrected Interview Date (if known)"]
        genuine = (r["Genuine Interview on That Date? (Yes/No/Unsure)"] or "").strip() if r["Genuine Interview on That Date? (Yes/No/Unsure)"] else ""
        correct_cluster = (r["Correct Cluster/Site ID (if known)"] or "").strip() if r["Correct Cluster/Site ID (if known)"] else ""
        identify = (r["Can Your Team Identify This Household? (Yes/No)"] or "").strip() if r["Can Your Team Identify This Household? (Yes/No)"] else ""
        notes = (r["Notes / Explanation"] or "").strip() if r["Notes / Explanation"] else ""

        if issue_type not in ("Date Outlier", "CRS Unmatched"):
            findings.add(sheet, row_num, "ERROR", "Issue Type is not one of the recognised values", f"got={issue_type!r}")
            continue

        if issue_type == "Date Outlier":
            if correct_cluster or identify:
                findings.add(sheet, row_num, "WARNING",
                              "This is a Date Outlier row, but the CRS Unmatched columns (Correct Cluster/Site ID / Can Your Team Identify) were filled in instead of the Date Outlier ones",
                              f"correct_cluster={correct_cluster!r} identify={identify!r}")
            if not corrected_date and not genuine and not notes:
                findings.add(sheet, row_num, "INFO", "No response - stays pending/unresolved")
                continue
            if genuine and genuine.lower() not in ("yes", "no", "unsure"):
                findings.add(sheet, row_num, "WARNING", "Genuine Interview answer is not Yes/No/Unsure", f"got={genuine!r}")
            if genuine.lower() == "yes":
                if corrected_date is None:
                    findings.add(sheet, row_num, "ERROR", "Marked as a genuine interview but no Corrected Interview Date given")
                else:
                    parsed = parse_date_flexible(corrected_date, today)
                    if parsed is None:
                        findings.add(sheet, row_num, "ERROR", "Corrected Interview Date is unparseable or in the future", f"got={corrected_date!r}")
        else:  # CRS Unmatched
            if corrected_date or genuine:
                findings.add(sheet, row_num, "WARNING",
                              "This is a CRS Unmatched row, but the Date Outlier columns (Corrected Interview Date / Genuine Interview) were filled in instead of the CRS Unmatched ones",
                              f"corrected_date={corrected_date!r} genuine={genuine!r}")
            if not correct_cluster and not identify and not notes:
                findings.add(sheet, row_num, "INFO", "No response - stays pending/unresolved")
                continue
            if identify and identify.lower() not in ("yes", "no"):
                findings.add(sheet, row_num, "WARNING", "Can Your Team Identify This Household answer is not Yes/No", f"got={identify!r}")
            if identify.lower() == "yes" and not correct_cluster:
                findings.add(sheet, row_num, "ERROR", "Marked as identifiable but no Correct Cluster/Site ID given")


def verify_confirmed_deletions(ws, findings, apply_writeback=True):
    """Write-back added 2026-09-06: a clean (no-ERROR) row's Contest answer
    now drives issue_tracker.apply_resolution() directly - No/blank confirms
    the deletion (confirmed_by="partner"), Yes-with-explanation moves it to
    contested (pending Jack's review, matching the tracker's existing
    contested-status meaning). This was previously findings-only (see this
    file's 2026-09-01 header) - the whole point of building the tracker was
    to close that gap, so this is the one function in this file that's no
    longer purely read-only. apply_writeback=False (tests) skips the actual
    tracker mutation while keeping every other check identical."""
    sheet = "Confirmed Deletions"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        contest_raw = (r["Contest This? (Yes/No)"] or "").strip() if r["Contest This? (Yes/No)"] else ""
        explain = (r["If Yes, Explain"] or "").strip() if r["If Yes, Explain"] else ""
        interview_id = r["Interview ID"]

        if contest_raw == NO_APPEAL_CONTEST_NOTE:
            # Validated-methodology-threshold row (duration/fcs_zero) - never
            # open to contest, already confirmed at registration. Nothing to
            # verify or write back regardless of what the partner did with it.
            findings.add(sheet, row_num, "INFO", "Not open to contest (validated methodology threshold) - no action taken")
            continue

        contest = contest_raw
        valid = True
        if contest and contest.lower() not in ("yes", "no"):
            findings.add(sheet, row_num, "WARNING", "Contest answer is not Yes/No", f"got={contest!r}")
            valid = False
        if contest.lower() == "yes" and not explain:
            findings.add(sheet, row_num, "ERROR", "Contested but no explanation given")
            valid = False
        if contest.lower() in ("no", "") and explain:
            findings.add(sheet, row_num, "INFO", "Explanation given without contesting - check it's not actually a Yes")

        if not valid or not apply_writeback:
            continue

        issue_id = issue_tracker.build_issue_id("confirmed_deletion", uuid=interview_id)
        # Never overwrite a row already at a TERMINAL_STATUS (2026-09-06 -
        # same bug class found and fixed in register_deletion_log_issues.R
        # tonight: an automated pass must never clobber a decision a human
        # already made, even by re-processing the SAME response file twice).
        # A previously-contested row that Jack has since reviewed and
        # resolved is exactly this case - re-running verification against
        # the same returned workbook must not re-decide it.
        existing = [row for row in issue_tracker.read_tracker() if row["issue_id"] == issue_id]
        if existing and existing[0]["status"] in issue_tracker.TERMINAL_STATUSES:
            findings.add(sheet, row_num, "INFO",
                         "Already resolved in the tracker - not re-decided by this verification pass",
                         f"issue_id={issue_id} current_status={existing[0]['status']}")
            continue

        if contest.lower() == "yes":
            ok = issue_tracker.apply_resolution(issue_id, "contested", resolution=explain)
        else:  # "no" or blank - accept the deletion
            ok = issue_tracker.apply_resolution(issue_id, "confirmed", confirmed_by="partner",
                                                 resolution="partner did not contest" if not contest else "partner confirmed: No")
        if not ok:
            findings.add(sheet, row_num, "WARNING", "Could not record this row's decision in the tracker - issue_id not found",
                         f"issue_id={issue_id}")


def load_cluster_availability(ws):
    header = ["Cluster ID", "Type", "State", "LGA", "Ward", "Total Points/Slots", "Covered / Claimed", "Still Available"]
    out = {}
    for _, r in sheet_rows(ws, header):
        still = r["Still Available"] or ""
        out[r["Cluster ID"]] = {s.strip() for s in still.split(",") if s.strip()}
    return out


def find_latest_workbook(partner_dir, partner):
    """Most recent <partner>_data_recovery_workbook_<date>.xlsx by the date
    IN the filename (2026-09-06, replacing the hardcoded 2026-08-30 - see
    run_full_batch.R's own header for why more than one dated file can now
    legitimately exist in the same folder, e.g. IMC's consolidated master
    sitting alongside a later from-scratch batch run)."""
    pattern = re.compile(rf"^{re.escape(partner)}_data_recovery_workbook_(\d{{4}}-\d{{2}}-\d{{2}})\.xlsx$")
    candidates = []
    if os.path.isdir(partner_dir):
        for fname in os.listdir(partner_dir):
            m = pattern.match(fname)
            if m:
                candidates.append((m.group(1), fname))
    if not candidates:
        return None
    candidates.sort()  # ISO-format dates sort correctly as strings
    return os.path.join(partner_dir, candidates[-1][1])


def main():
    if len(sys.argv) < 3:
        print("Usage: python verify_data_recovery_response.py <Partner> <path_to_returned_xlsx> [original_workbook_filename]")
        print("  [original_workbook_filename] overrides auto-detection - use this if more than one dated")
        print("  workbook exists for this partner and the wrong one would otherwise be picked (e.g. the")
        print("  partner responded against an older round than the most recent file on disk).")
        sys.exit(1)
    partner, returned_path = sys.argv[1], sys.argv[2]
    partner_dir = os.path.join(RECOVERY_DIR, partner)

    if len(sys.argv) >= 4:
        orig_path = os.path.join(partner_dir, sys.argv[3])
    else:
        orig_path = find_latest_workbook(partner_dir, partner)
    if orig_path is None or not os.path.exists(orig_path):
        print(f"ERROR: original outgoing workbook not found in {partner_dir} - can't cross-check row alignment.")
        sys.exit(1)

    print(f"Loading original (sent) workbook: {orig_path}")
    wb_orig, orig_repaired = load_repaired_workbook(orig_path)
    print(f"Loading returned workbook: {returned_path}")
    wb_ret, ret_repaired = load_repaired_workbook(returned_path)
    print(f"  (drawing-reference repair applied: original={orig_repaired}, returned={ret_repaired})")

    findings = Findings()
    check_headers_and_alignment(wb_orig, wb_ret, findings)

    # only run row-level checks for sheets whose header/alignment already passed
    broken_sheets = {f["sheet"] for f in findings.rows if f["severity"] == "ERROR" and f["row"] in (1, None)}

    if "Cluster Availability" in wb_ret.sheetnames:
        cluster_availability = load_cluster_availability(wb_ret["Cluster Availability"])
    else:
        cluster_availability = {}
        findings.add("Cluster Availability", None, "WARNING", "Sheet missing - can't cross-check 'still available' households")

    today = datetime.date.today()
    if "GPS Duplicates & Distant Pts" not in broken_sheets and "GPS Duplicates & Distant Pts" in wb_ret.sheetnames:
        verify_gps_duplicates(wb_ret["GPS Duplicates & Distant Pts"], cluster_availability, findings)
    if "IDP Listing Duplicates" not in broken_sheets and "IDP Listing Duplicates" in wb_ret.sheetnames:
        verify_idp_listing_duplicates(wb_ret["IDP Listing Duplicates"], findings, load_idp_real_pools())
    if "Missing HH Listings" not in broken_sheets and "Missing HH Listings" in wb_ret.sheetnames:
        verify_missing_hh_listings(wb_ret["Missing HH Listings"], findings, today)
    if "Confirmed Deletions" not in broken_sheets and "Confirmed Deletions" in wb_ret.sheetnames:
        verify_confirmed_deletions(wb_ret["Confirmed Deletions"], findings)
    if "Other Issues" not in broken_sheets and "Other Issues" in wb_ret.sheetnames:
        verify_other_issues(wb_ret["Other Issues"], findings, today)

    out_dir = os.path.dirname(os.path.abspath(returned_path))
    out_path = os.path.join(out_dir, f"{partner}_verification_findings_{today.isoformat()}.csv")
    findings.write_csv(out_path)

    n_error = sum(1 for f in findings.rows if f["severity"] == "ERROR")
    n_warning = sum(1 for f in findings.rows if f["severity"] == "WARNING")
    n_info = sum(1 for f in findings.rows if f["severity"] == "INFO")
    print(f"\n{partner}: {len(findings.rows)} finding(s) - {n_error} ERROR, {n_warning} WARNING, {n_info} INFO.")
    print(f"Wrote {out_path}")
    if n_error > 0:
        print("ERRORs must be resolved (usually means contacting the partner back) before any row is integrated.")


if __name__ == "__main__":
    main()
