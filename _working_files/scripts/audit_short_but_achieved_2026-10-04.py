"""audit_short_but_achieved_2026-10-04.py - every interview the dashboard counts as Achieved although its audit
duration rounds below the 20.0-minute floor (Jack's duration rule, 2 Oct: removed when round(min, 1) < 20.0).

Why this exists: the recovery tracker keeps ONE confirmed_deletion row per interview (issue_id = issue_type + uuid).
When an interview already has a resolved row for another reason - e.g. a duplicate_point flag later recovered as a
false positive - run_independent_duration_check() cannot register a duration row for it, so a short interview can stay
Achieved. Found 4 Oct on the interviews whose durations arrived late. Read-only: prints and writes a CSV for review.

Run from 2_monitoring:  py -3 _working_files/scripts/audit_short_but_achieved_2026-10-04.py
"""
import csv
from collections import Counter

OUT = "reports/partner_data_recovery/outputs/_round1_closeout/short_but_achieved_2026-10-04.csv"  # outputs/ is gitignored: holds uuids


def read(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


settled = {r["uuid"] for r in read("data/CONFIRMED_DELETIONS_OVERLAY.csv") if r["status"] in ("confirmed", "contested")}
with open("data/ROUND1_MEMBERSHIP.csv", encoding="utf-8-sig", newline="") as f:
    r1 = {r[0] for r in csv.reader(f)}
trk = {}
for r in read("reports/partner_data_recovery/scripts/recovery_issue_tracker.csv"):
    if r["issue_type"] == "confirmed_deletion" and r["uuid"]:
        trk[r["uuid"]] = r

hits = []
for s in read("data/real_submissions.csv"):
    if s["interview_outcome"] != "completed" or s["submission_uuid"] in settled:
        continue
    try:
        m = float(s["duration_min"])
    except ValueError:
        continue
    if round(m, 1) < 20.0:
        t = trk.get(s["submission_uuid"], {})
        hits.append({"uuid": s["submission_uuid"], "round": "Round 1" if s["submission_uuid"] in r1 else "post-Round 1",
                     "org_id": s["org_id"], "state": s["admin1"], "pop_type": s["pop_type"], "strata_id": s["matched_strata_id"],
                     "matched_cluster_id": s["matched_cluster_id"], "matched_survey_id": s["matched_survey_id"],
                     "submission_date": s["submission_date"], "duration_min": m,
                     "tracker_reason": t.get("deletion_reason", "(no tracker row)"), "tracker_status": t.get("status", ""),
                     "recovery_type": t.get("recovery_type", ""), "resolution": t.get("resolution", "")[:160]})

hits.sort(key=lambda r: (r["round"], r["org_id"], r["duration_min"]))
with open(OUT, "w", encoding="utf-8", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(hits[0].keys()) if hits else ["uuid"])
    w.writeheader()
    w.writerows(hits)
print(f"Achieved but under the duration floor: {len(hits)}")
print("  by round:", dict(Counter(r["round"] for r in hits)))
print("  by tracker reason/status/recovery:", dict(Counter((r["tracker_reason"], r["tracker_status"], r["recovery_type"]) for r in hits)))
print("  by partner/state:", dict(Counter((r["org_id"], r["state"]) for r in hits)))
print("  minutes:", sorted(r["duration_min"] for r in hits))
print("written:", OUT)
