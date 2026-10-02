#!/usr/bin/env python3
"""Round 1 recovery closeout, step 2 APPLY - writes the clean partner responses from the 5 returned
workbooks into the tracker, and records every data correction for the final cleaning log.

Input: reports/partner_data_recovery/outputs/_round1_closeout/round1_returned_workbooks_classified.csv
(round1_ingest_classify.py). Only rows classified "apply" are written, plus NRC's Date Outlier rows on the
Other Issues sheet, which Jack's Q6 decision (2026-10-01: "keep as exceptions") resolves.

Tracker outcomes (only confirmed_deletion rows can ever exclude an interview from Achieved, and only when
settled with recovery_type NA - build_confirmed_deletions_overlay.R):
  recover_corrected_point / recover_corrected_listing -> confirmed, partner, recovery_type false_positive
      (recovered: stays in Achieved; the corrected value goes to the cleaning log as change_response)
  close_listing_received -> confirmed, partner (cluster-level, never affects Achieved)
  Date Outlier (Q6) -> confirmed, internal_team, recovery_type justified_exception
  correct_listing_log_only -> no tracker change (unflagged first claimant), cleaning-log correction only

Safety (same pattern as resolve_live_claimant_duplicates.R): only rows still OPEN are touched, a snapshot of
every touched row is written BEFORE any change, one decisions-log line is appended, and
  python -B round1_apply_partner_responses.py --restore <snapshot csv>
puts exactly those rows back.

    python -B _working_files/scripts/round1_apply_partner_responses.py            # dry run (default)
    python -B _working_files/scripts/round1_apply_partner_responses.py --apply
"""
import csv
import datetime
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "reports/partner_data_recovery/scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import issue_tracker as it  # noqa: E402
from round1_ingest_classify import read_sheet, RET_DIR, WORKBOOKS  # noqa: E402

CLASSIFIED = REPO / "reports/partner_data_recovery/outputs/_round1_closeout/round1_returned_workbooks_classified.csv"
CORRECTIONS = REPO / "reports/partner_data_recovery/outputs/_round1_closeout/round1_data_corrections.csv"
LOG_DIR = REPO / "reports/partner_data_recovery/outputs/_review_decisions_log"
TERMINAL = it.TERMINAL_STATUSES
DECIDED_BY = "Jack (Round 1 closeout step 2, 2026-10-01: apply clean partner responses; Q6 date outliers kept)"


def other_issue_rows():
    """NRC's Other Issues rows, keyed by Interview ID, with every response field."""
    out = {}
    for fname, (org, _) in WORKBOOKS.items():
        _, rows = read_sheet(RET_DIR / fname, "Other Issues")
        for r in rows:
            out[str(r.get("Interview ID") or "").strip()] = (org, fname, r)
    return out


def plan_changes(today):
    rows = list(csv.DictReader(open(CLASSIFIED, encoding="utf-8")))
    tracker_changes, corrections = [], []
    for r in rows:
        a = r["proposed_action"]
        if r["classification"] != "apply" and a != "other_issue_review":
            continue
        if a == "recover_corrected_point":
            old, new = [x.strip() for x in r["detail"].split("->")]
            tracker_changes.append((r["issue_id"], dict(status="confirmed", confirmed_by="partner", recovery_type="false_positive",
                resolution=f"Round 1 closeout: partner-confirmed point {old} -> {new} (validated: real frame point, same cluster, unclaimed)")))
            corrections.append(dict(uuid=r["key"], org_id=r["org_id"], field="non_idp_point_id", old_value=old, new_value=new,
                                    source=r["file"], basis="partner-confirmed corrected point (duplicate_point recovered)"))
        elif a == "recover_corrected_listing":
            old, new = [x.strip() for x in r["detail"].split("->")]
            tracker_changes.append((r["issue_id"], dict(status="confirmed", confirmed_by="partner", recovery_type="false_positive",
                resolution=f"Round 1 closeout: partner-confirmed IDP listing number {old} -> {new} (validated: in the cluster's real HH listing, unique after all corrections)")))
            corrections.append(dict(uuid=r["key"], org_id=r["org_id"], field="idp_hh_number_from_listing", old_value=old, new_value=new,
                                    source=r["file"], basis="partner-confirmed listing number (duplicate recovered)"))
        elif a == "correct_listing_log_only":
            body = r["detail"].split("(")[0].replace("unflagged first claimant", "").strip()
            old, new = [x.strip() for x in body.split("->")]
            corrections.append(dict(uuid=r["key"], org_id=r["org_id"], field="idp_hh_number_from_listing", old_value=old, new_value=new,
                                    source=r["file"], basis="partner-confirmed listing number for the unflagged first claimant of a shared number (no tracker issue)"))
        elif a == "close_listing_received":
            tracker_changes.append((r["issue_id"], dict(status="confirmed", confirmed_by="partner",
                resolution="Round 1 closeout: partner confirmed the HH listing was submitted; verified - the cluster has a real listing in the HH listing export (29 Sep)")))
    # Q6: NRC's Date Outlier rows - keep as exceptions, record the partner's corrected date
    oi = other_issue_rows()
    for r in rows:
        if r["proposed_action"] != "other_issue_review":
            continue
        org, fname, raw = oi.get(r["key"], (r["org_id"], r["file"], {}))
        if str(raw.get("Issue Type") or "").strip() != "Date Outlier":
            continue
        cdate = raw.get("Corrected Interview Date (if known)")
        cdate = cdate.date().isoformat() if hasattr(cdate, "date") else str(cdate or "").strip()
        note = str(raw.get("Notes / Explanation") or "").strip()
        tracker_changes.append((r["issue_id"], dict(status="confirmed", confirmed_by="internal_team", recovery_type="justified_exception",
            resolution=f"Round 1 closeout (Jack, Q6): kept as an exception - the recorded date is wrong, the interview is real. "
                       f"Partner-supplied corrected date: {cdate or 'not given'}." + (f" Partner note: {note[:200]}" if note else ""))))
        if cdate:
            corrections.append(dict(uuid=r["key"], org_id=org, field="submission_date", old_value="(device-clock date)", new_value=cdate,
                                    source=fname, basis="partner-supplied corrected interview date (date_outlier kept, Q6)"))
    return tracker_changes, corrections


def main():
    apply = "--apply" in sys.argv
    if "--restore" in sys.argv:
        return restore(sys.argv[sys.argv.index("--restore") + 1])
    today = datetime.date.today().isoformat()
    changes, corrections = plan_changes(today)
    tracker = it.read_tracker()
    idx = {row["issue_id"]: i for i, row in enumerate(tracker)}
    ok, skipped = [], []
    for iid, fields in changes:
        i = idx.get(iid)
        if i is None:
            skipped.append((iid, "not in tracker"))
        elif tracker[i]["status"] in TERMINAL:
            skipped.append((iid, f"already {tracker[i]['status']}"))
        else:
            ok.append((i, iid, fields))
    print(f"tracker changes planned: {len(changes)} | will apply: {len(ok)} | skipped: {len(skipped)}")
    for s_ in skipped[:10]:
        print("  skipped:", s_)
    print(f"data corrections for the cleaning log: {len(corrections)}")
    if not apply:
        print("\nDRY RUN - nothing written. Re-run with --apply.")
        return
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    snap = LOG_DIR / f"{stamp}_round1_partner_responses_BEFORE.csv"
    with open(snap, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=it.COLUMNS)
        w.writeheader()
        w.writerows(tracker[i] for i, _, _ in ok)
    for i, _, fields in ok:
        tracker[i].update(fields)
        tracker[i]["resolution_date"] = today
    it.write_tracker(tracker)
    with open(CORRECTIONS, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["uuid", "org_id", "field", "old_value", "new_value", "source", "basis"])
        w.writeheader()
        w.writerows(corrections)
    with open(LOG_DIR / f"{today}.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} | decided_by={DECIDED_BY} | n={len(ok)} | round1 partner responses applied | "
                f"snapshot={snap.name} | issue_ids={';'.join(iid for _, iid, _ in ok)}\n")
    print(f"\nAPPLIED {len(ok)} tracker change(s). Snapshot: {snap}\nCorrections: {CORRECTIONS}")


def restore(snapshot_path):
    snap = list(csv.DictReader(open(snapshot_path, encoding="utf-8")))
    tracker = it.read_tracker()
    idx = {row["issue_id"]: i for i, row in enumerate(tracker)}
    n = 0
    for row in snap:
        i = idx.get(row["issue_id"])
        if i is not None:
            tracker[i] = {c: row.get(c, "") for c in it.COLUMNS}
            n += 1
    it.write_tracker(tracker)
    with open(LOG_DIR / f"{datetime.date.today().isoformat()}.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} | RESTORE n={n} from {Path(snapshot_path).name}\n")
    print(f"restored {n} row(s) from {snapshot_path}")


if __name__ == "__main__":
    main()
