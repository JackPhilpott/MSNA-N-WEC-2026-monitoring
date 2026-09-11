# ==============================================================================
# Interactive review helper - the "review, clean, and approve/reject
# feedback" step of the recovery-workbook workflow. Built 2026-09-03 per
# Jack, once real partner responses started needing an actual decision
# recorded somewhere: verify_data_recovery_response.py checks a returned
# workbook is internally consistent, but a clean/plausible row still needs
# a HUMAN to say yes, use it - this script is that step, walking through
# each row with something to decide and recording the outcome in
# recovery_issue_tracker.csv (via issue_tracker.py's apply_resolution()).
#
# Run this AFTER verify_data_recovery_response.py has produced a findings
# CSV for the same file - this script reuses its checks (imports the same
# verify_* functions and Findings machinery) so a row already flagged
# ERROR (broken/needs going back to the partner) is never presented for a
# yes/no decision here; only rows that passed structural checks and
# actually propose something (a CONFIRMED value, a Yes/No answer, a
# contest) show up.
#
# Usage:
#   python review_recovery_response.py <Partner> <path_to_returned_xlsx>
#
# For each reviewable row, prints the row's key fields plus any WARNING/
# INFO findings already on it, then prompts:
#   a = approve   (status -> confirmed, resolution = the proposed value)
#   r = reject    (status -> rejected - stays OPEN, gets re-included in a
#                  future batch/re-ask, per issue_tracker's own status
#                  lifecycle - use this when the proposed value is wrong
#                  but the underlying issue still needs resolving)
#   s = skip      (leave untouched - decide later, e.g. need more info)
#   q = quit      (stop reviewing; anything already decided this run is
#                  already saved - safe to resume later on the same file)
#
# Confirmed Deletions is handled slightly differently: an UNCONTESTED
# deletion has nothing to decide (the data officer already decided, the
# partner didn't object) and is auto-resolved as "confirmed" with no
# prompt. A CONTESTED deletion needs Jack's judgment - approve/reject here
# both record status "contested" (this issue is closed either way, not
# re-asked), with the actual outcome (upheld vs overturned) captured in
# the free-text resolution - read that field, not the status alone, to
# see which way a contested deletion went.
#
# issue_id note: this script calls issue_tracker.ensure_issue() before
# resolving, so it works even for issues generation never explicitly
# registered (that wiring - register_issues() called from full_batch_
# pipeline.R - is a separate, not-yet-done step). Re-running this script
# against the same file is safe: an already-confirmed/contested row is
# skipped automatically (nothing left to decide), matching
# get_unresolved_issue_ids()'s own "don't re-flag what's resolved" logic.
# ==============================================================================
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import issue_tracker as it
from verify_data_recovery_response import (
    EXPECTED_HEADERS,
    RECOVERY_DIR,
    Findings,
    check_headers_and_alignment,
    find_latest_workbook,
    load_cluster_availability,
    sheet_rows,
    verify_confirmed_deletions,
    verify_gps_duplicates,
    verify_idp_listing_duplicates,
    verify_missing_hh_listings,
    verify_other_issues,
)
from xlsx_repair import load_repaired_workbook


def row_finding(findings, sheet, row_num):
    return [f for f in findings.rows if f["sheet"] == sheet and f["row"] == row_num]


def row_has_error(findings, sheet, row_num):
    return any(f["severity"] == "ERROR" for f in row_finding(findings, sheet, row_num))


def print_findings(notes):
    for f in notes:
        if f["severity"] == "ERROR":
            continue  # already excluded by row_has_error() at the call site, defensive only
        detail = f" ({f['detail']})" if f.get("detail") else ""
        print(f"  [{f['severity']}] {f['issue']}{detail}")


def prompt(msg):
    while True:
        ans = input(msg).strip().lower()
        if ans in ("a", "r", "s", "q"):
            return ans
        print("  please answer a(pprove) / r(eject) / s(kip) / q(uit)")


def already_resolved(issue_type, uuid=None, cluster_id=None):
    issue_id = it.build_issue_id(issue_type, uuid=uuid, cluster_id=cluster_id)
    rows = it.read_tracker()
    for r in rows:
        if r["issue_id"] == issue_id and r["status"] in it.TERMINAL_STATUSES:
            return True
    return False


def review_gps_duplicates(ws, org_id, findings, tally):
    sheet = "GPS Duplicates & Distant Pts"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        if row_has_error(findings, sheet, row_num):
            continue
        confirmed = (r["CONFIRMED Household ID"] or "").strip() if r["CONFIRMED Household ID"] else ""
        if not confirmed:
            continue
        issue_type = "gps_duplicate"
        if already_resolved(issue_type, uuid=r["Interview ID"]):
            continue
        print(f"\n[{sheet}] row {row_num}  Interview {r['Interview ID']}  Cluster {r['Cluster ID']}")
        print(f"  Recorded Point ID: {r['Point ID Recorded']}   Distance: {r['Distance From Recorded Point (m)']}m")
        print(f"  CONFIRMED Household ID: {confirmed}   Genuine?: {r['Genuine, Distinct Visit? (Yes/No/Unsure)']}")
        if r["Notes / Explanation"]:
            print(f"  Partner note: {r['Notes / Explanation']}")
        print_findings(row_finding(findings, sheet, row_num))
        ans = prompt("  Approve this recovery? [a/r/s/q]: ")
        if ans == "q":
            return False
        if ans == "s":
            continue
        issue_id = it.ensure_issue(issue_type, org_id, r["Cluster ID"], uuid=r["Interview ID"])
        if ans == "a":
            it.apply_resolution(issue_id, "confirmed", resolution=confirmed)
            tally["approved"] += 1
        else:
            it.apply_resolution(issue_id, "rejected", resolution=f"reviewer rejected proposed household id {confirmed}")
            tally["rejected"] += 1
    return True


def review_idp_listing_duplicates(ws, org_id, findings, tally):
    sheet = "IDP Listing Duplicates"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        if row_has_error(findings, sheet, row_num):
            continue
        confirmed = r["CONFIRMED Listing Number"]
        if confirmed is None:
            continue
        if already_resolved("idp_listing_duplicate", uuid=r["Interview ID"]):
            continue
        print(f"\n[{sheet}] row {row_num}  Interview {r['Interview ID']}  Cluster {r['Cluster/Site ID']}")
        print(f"  Listing Number Recorded: {r['Listing Number Recorded']}   Total Available: {r['Total Numbers Available in Cluster']}")
        print(f"  CONFIRMED Listing Number: {confirmed}")
        if r["Notes / Explanation"]:
            print(f"  Partner note: {r['Notes / Explanation']}")
        print_findings(row_finding(findings, sheet, row_num))
        ans = prompt("  Approve this listing number? [a/r/s/q]: ")
        if ans == "q":
            return False
        if ans == "s":
            continue
        issue_id = it.ensure_issue("idp_listing_duplicate", org_id, r["Cluster/Site ID"], uuid=r["Interview ID"],
                                    listing_number=r["Listing Number Recorded"])
        if ans == "a":
            it.apply_resolution(issue_id, "confirmed", resolution=str(confirmed))
            tally["approved"] += 1
        else:
            it.apply_resolution(issue_id, "rejected", resolution=f"reviewer rejected proposed listing number {confirmed}")
            tally["rejected"] += 1
    return True


def review_missing_hh_listings(ws, org_id, findings, tally):
    sheet = "Missing HH Listings"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        if row_has_error(findings, sheet, row_num):
            continue
        submitted = (r["Household Listing Now Submitted? (Yes/No)"] or "").strip() if r["Household Listing Now Submitted? (Yes/No)"] else ""
        if submitted.lower() != "yes":
            continue  # "No" or blank - nothing to approve, still genuinely missing
        cluster_id = r["Cluster/Site ID"]
        if already_resolved("missing_hh_listing", cluster_id=cluster_id):
            continue
        print(f"\n[{sheet}] row {row_num}  Cluster/Site {cluster_id}   ({r['IOM Site Name']})")
        print(f"  Household Listing Now Submitted: Yes, dated {r['Date Submitted (if Yes)']}")
        if r["Notes / Explanation"]:
            print(f"  Partner note: {r['Notes / Explanation']}")
        print_findings(row_finding(findings, sheet, row_num))
        ans = prompt("  Confirm this listing as received? [a/r/s/q]: ")
        if ans == "q":
            return False
        if ans == "s":
            continue
        issue_id = it.ensure_issue("missing_hh_listing", org_id, cluster_id)
        if ans == "a":
            it.apply_resolution(issue_id, "confirmed", resolution=f"listing submitted {r['Date Submitted (if Yes)']}")
            tally["approved"] += 1
        else:
            it.apply_resolution(issue_id, "rejected", resolution="reviewer did not accept the submitted-listing claim")
            tally["rejected"] += 1
    return True


def review_other_issues(ws, org_id, findings, tally):
    """ADDED 2026-09-11. Modeled on review_gps_duplicates() above (the
    skip-if-blank shape) - NOT review_confirmed_deletions()'s auto-apply-
    if-uncontested shape, since a blank Other Issues row must stay
    pending, not get silently confirmed. Both issue types share the tracker's
    "confirmed_deletion" issue_type/id-space, same as every other reason -
    already_resolved() works unmodified since it keys on issue_type/uuid,
    not deletion_reason."""
    sheet = "Other Issues"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        if row_has_error(findings, sheet, row_num):
            continue
        issue_type_label = (r["Issue Type"] or "").strip()
        uuid = r["Interview ID"]
        cluster_id = r["Cluster ID"]
        notes = (r["Notes / Explanation"] or "").strip() if r["Notes / Explanation"] else ""

        if issue_type_label == "Date Outlier":
            corrected_date = r["Corrected Interview Date (if known)"]
            genuine = (r["Genuine Interview on That Date? (Yes/No/Unsure)"] or "").strip() if r["Genuine Interview on That Date? (Yes/No/Unsure)"] else ""
            if not corrected_date and not genuine and not notes:
                continue  # no response - stays pending, nothing to review
            proposed = f"Corrected date: {corrected_date}  Genuine?: {genuine}"
        elif issue_type_label == "CRS Unmatched":
            correct_cluster = (r["Correct Cluster/Site ID (if known)"] or "").strip() if r["Correct Cluster/Site ID (if known)"] else ""
            identify = (r["Can Your Team Identify This Household? (Yes/No)"] or "").strip() if r["Can Your Team Identify This Household? (Yes/No)"] else ""
            if not correct_cluster and not identify and not notes:
                continue  # no response - stays pending, nothing to review
            proposed = f"Correct cluster: {correct_cluster}  Identifiable?: {identify}"
        else:
            continue  # unrecognised Issue Type - already flagged as an ERROR by verify_other_issues(), skip here

        if already_resolved("confirmed_deletion", uuid=uuid):
            continue
        print(f"\n[{sheet}] row {row_num}  Interview {uuid}  Cluster {cluster_id}  ({issue_type_label})")
        print(f"  {proposed}")
        if notes:
            print(f"  Partner note: {notes}")
        print_findings(row_finding(findings, sheet, row_num))
        ans = prompt("  Approve this correction (confirms recovered, not deleted)? [a/r/s/q]: ")
        if ans == "q":
            return False
        if ans == "s":
            continue
        issue_id = it.ensure_issue("confirmed_deletion", org_id, cluster_id, uuid=uuid)
        if ans == "a":
            it.apply_resolution(issue_id, "confirmed", confirmed_by="partner", resolution=proposed, recovery_type="false_positive")
            tally["approved"] += 1
        else:
            it.apply_resolution(issue_id, "rejected", resolution=f"reviewer rejected proposed correction: {proposed}")
            tally["rejected"] += 1
    return True


def review_confirmed_deletions(ws, org_id, findings, tally):
    sheet = "Confirmed Deletions"
    header = EXPECTED_HEADERS[sheet]
    for row_num, r in sheet_rows(ws, header):
        if row_has_error(findings, sheet, row_num):
            continue
        uuid = r["Interview ID"]
        if already_resolved("confirmed_deletion", uuid=uuid):
            continue
        contest = (r["Contest This? (Yes/No)"] or "").strip() if r["Contest This? (Yes/No)"] else ""
        issue_id = it.ensure_issue("confirmed_deletion", org_id, r["Cluster ID"], uuid=uuid)
        if contest.lower() != "yes":
            # nothing to decide - the officer already decided, partner didn't object
            it.apply_resolution(issue_id, "confirmed", resolution="not contested, deletion stands")
            tally["auto_confirmed"] += 1
            continue
        print(f"\n[{sheet}] row {row_num}  Interview {uuid}  Cluster {r['Cluster ID']}   Reason: {r['Reason']}")
        print(f"  Contested - explanation: {r['If Yes, Explain']}")
        print_findings(row_finding(findings, sheet, row_num))
        ans = prompt("  Uphold the contest (deletion overturned)? [a=overturn / r=deletion stands / s/q]: ")
        if ans == "q":
            return False
        if ans == "s":
            continue
        if ans == "a":
            it.apply_resolution(issue_id, "contested", resolution=f"contest upheld - deletion overturned, recover interview. Reason: {r['If Yes, Explain']}")
            tally["overturned"] += 1
        else:
            it.apply_resolution(issue_id, "contested", resolution=f"contest reviewed and rejected - deletion stands. Partner reason: {r['If Yes, Explain']}")
            tally["contest_rejected"] += 1
    return True


def main():
    if len(sys.argv) < 3:
        print("Usage: python review_recovery_response.py <Partner> <path_to_returned_xlsx>")
        sys.exit(1)
    partner, returned_path = sys.argv[1], sys.argv[2]
    org_id = partner.lower()

    # FIX 2026-09-11: was a hardcoded "_2026-08-30.xlsx" filename (same bug
    # verify_data_recovery_response.py already fixed 2026-09-06 with
    # find_latest_workbook() - that fix was never ported here). Now finds
    # the most recent dated workbook on disk for this partner, same as the
    # verify script does.
    orig_path = find_latest_workbook(os.path.join(RECOVERY_DIR, partner), partner)
    if orig_path is None:
        print(f"ERROR: no dated original outgoing workbook found for {partner} in "
              f"{os.path.join(RECOVERY_DIR, partner)} - can't cross-check row alignment.")
        sys.exit(1)

    wb_orig, _ = load_repaired_workbook(orig_path)
    wb_ret, _ = load_repaired_workbook(returned_path)

    findings = Findings()
    check_headers_and_alignment(wb_orig, wb_ret, findings)
    broken_sheets = {f["sheet"] for f in findings.rows if f["severity"] == "ERROR" and f["row"] in (1, None)}

    if "Cluster Availability" in wb_ret.sheetnames:
        cluster_availability = load_cluster_availability(wb_ret["Cluster Availability"])
    else:
        cluster_availability = {}

    today = datetime.date.today()
    if "GPS Duplicates & Distant Pts" not in broken_sheets and "GPS Duplicates & Distant Pts" in wb_ret.sheetnames:
        verify_gps_duplicates(wb_ret["GPS Duplicates & Distant Pts"], cluster_availability, findings)
    if "IDP Listing Duplicates" not in broken_sheets and "IDP Listing Duplicates" in wb_ret.sheetnames:
        verify_idp_listing_duplicates(wb_ret["IDP Listing Duplicates"], findings)
    if "Missing HH Listings" not in broken_sheets and "Missing HH Listings" in wb_ret.sheetnames:
        verify_missing_hh_listings(wb_ret["Missing HH Listings"], findings, today)
    if "Confirmed Deletions" not in broken_sheets and "Confirmed Deletions" in wb_ret.sheetnames:
        verify_confirmed_deletions(wb_ret["Confirmed Deletions"], findings)
    if "Other Issues" not in broken_sheets and "Other Issues" in wb_ret.sheetnames:
        verify_other_issues(wb_ret["Other Issues"], findings, today)

    if broken_sheets:
        print(f"WARNING: these sheets failed structural checks and are skipped entirely: {sorted(broken_sheets)}")
        print("Re-run verify_data_recovery_response.py and resolve these with the partner before reviewing them here.\n")

    tally = {"approved": 0, "rejected": 0, "auto_confirmed": 0, "overturned": 0, "contest_rejected": 0}

    print(f"\n=== Reviewing {partner}'s returned workbook: {os.path.basename(returned_path)} ===")
    print("For each row: a=approve, r=reject, s=skip (decide later), q=quit (progress so far is already saved)\n")

    steps = [
        ("GPS Duplicates & Distant Pts", review_gps_duplicates),
        ("IDP Listing Duplicates", review_idp_listing_duplicates),
        ("Missing HH Listings", review_missing_hh_listings),
        ("Confirmed Deletions", review_confirmed_deletions),
        ("Other Issues", review_other_issues),
    ]
    for sheet_name, fn in steps:
        if sheet_name in broken_sheets or sheet_name not in wb_ret.sheetnames:
            continue
        keep_going = fn(wb_ret[sheet_name], org_id, findings, tally)
        if not keep_going:
            break

    print(f"\n=== Done. Approved: {tally['approved']}  Rejected: {tally['rejected']}  "
          f"Auto-confirmed (uncontested deletions): {tally['auto_confirmed']}  "
          f"Contests overturned: {tally['overturned']}  Contests upheld (deletion stands): {tally['contest_rejected']} ===")
    print(f"Recorded in {it.TRACKER_PATH}")


if __name__ == "__main__":
    main()
