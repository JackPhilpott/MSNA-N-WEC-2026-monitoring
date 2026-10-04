"""post_refresh_duration_findings_2026-10-04.py - after the 4 Oct refresh (4 Oct export + one-time audit fallback).

Lists every interview this refresh newly removed for short duration (tracker rows with deletion_reason
duration_under_20 that were NOT in the pre-run tracker snapshot), split into:
  - ROUND 1 (in data/ROUND1_MEMBERSHIP.csv): counted as Achieved in the Round 1 submission because their audit files
    reached the audit log only after the 2 Oct closeout read it. Jack, 4 Oct: Round 1 is NOT changed retroactively
    (submitted 5 Oct as is); these are a documented known limitation of Round 1, removed from Round 2 onwards.
  - POST-ROUND 1: ordinary new deletions.
Writes reports/partner_data_recovery/outputs/_round1_closeout/POST_SUBMISSION_duration_findings_2026-10-04.csv
(documentation only - no Round 1 file is changed) and prints a summary for the sampling team.

Run from 2_monitoring:  py -3 _working_files/scripts/post_refresh_duration_findings_2026-10-04.py
"""
import csv
import os
from collections import Counter

PRE = "data/_archive/2026-10-04_pre_4oct_export_refresh/recovery_issue_tracker.csv"
NOW = "reports/partner_data_recovery/scripts/recovery_issue_tracker.csv"
OUT = "reports/partner_data_recovery/outputs/_round1_closeout/POST_SUBMISSION_duration_findings_2026-10-04.csv"


def rows(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


pre = {r["issue_id"]: r for r in rows(PRE)}
# newly removed for duration since the pre-refresh snapshot: a new duration row, OR an existing row for another reason
# that the 4 Oct fix turned into a duration deletion (it had been recovered, e.g. a duplicate flag cleared)
new = [r for r in rows(NOW) if r["deletion_reason"] == "duration_under_20" and r["status"] in ("confirmed", "contested")
       and not r["recovery_type"] and (r["issue_id"] not in pre or pre[r["issue_id"]]["deletion_reason"] != "duration_under_20"
                                       or pre[r["issue_id"]]["recovery_type"])]
with open("data/ROUND1_MEMBERSHIP.csv", encoding="utf-8-sig", newline="") as f:
    r1 = {r[0] for r in csv.reader(f)}
ours = {r["uuid"] for r in rows("cleaning/real/audit_duration_cache.csv")}
subs = {}
with open("data/real_submissions.csv", encoding="utf-8-sig", newline="") as f:
    for r in csv.DictReader(f):
        subs[r["submission_uuid"]] = r

out = []
for t in new:
    s = subs.get(t["uuid"], {})
    out.append({
        "uuid": t["uuid"], "round": "Round 1" if t["uuid"] in r1 else "post-Round 1", "org_id": t["org_id"],
        "state": s.get("admin1", ""), "lga": s.get("admin2_submitted", ""), "pop_type": s.get("pop_type", ""),
        "strata_id": t["strata_id"], "matched_cluster_id": t["cluster_id"], "matched_survey_id": s.get("matched_survey_id", ""),
        "submission_date": s.get("submission_date", ""), "duration_min": s.get("duration_min", ""),
        "tracker_status": t["status"], "confirmed_by": t["confirmed_by"], "resolution_date": t["resolution_date"],
        "how": "new duration finding" if t["issue_id"] not in pre else
               f"overrode an earlier {pre[t['issue_id']]['deletion_reason']} recovery ({pre[t['issue_id']]['recovery_type']})",
        # our own cache is never written in fallback mode, so "not in it" = the number came from the DO's cache
        "duration_source": "our own audit read" if t["uuid"] in ours else "data officer's audit-duration cache (one-time fallback)",
        "note": ("Counted as Achieved in the Round 1 submission (audit file reached the audit log after the 2 Oct closeout). "
                 "Round 1 not changed retroactively (Jack, 4 Oct); removed from Round 2 onwards.") if t["uuid"] in r1 else "",
    })
out.sort(key=lambda r: (r["round"] != "Round 1", r["org_id"], r["strata_id"], r["uuid"]))
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(out[0].keys()) if out else ["uuid"])
    w.writeheader()
    w.writerows(out)

for label in ("Round 1", "post-Round 1"):
    part = [r for r in out if r["round"] == label]
    print(f"{label}: {len(part)} newly removed for duration; status {dict(Counter(r['tracker_status'] for r in part))}")
    print("   by partner/state:", dict(Counter((r["org_id"], r["state"]) for r in part)))
    print("   by pop_type:", dict(Counter(r["pop_type"] for r in part)), "| source:", dict(Counter(r["duration_source"] for r in part)))
    print("   how:", dict(Counter(r["how"] for r in part)))
print("written:", OUT)
