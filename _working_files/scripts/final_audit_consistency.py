#!/usr/bin/env python3
"""Final audit consistency check (Jack, 16 Oct 2026, decision #68): the final dataset and the final audit.zip must
agree - Jack expects a fully updated audit.zip alongside the final export, wants NO "duration not verifiable"
placeholder, and any Achieved interview still without an audit duration reported to him as an exception BEFORE the
final deletion log (final_build_deletion_log.py) is finalised. Read-only; run AFTER the final refresh (1a), which
builds data/real_submissions.csv from the final export and fills cleaning/real/audit_duration_cache.csv from the zip.

Checks, both directions:
  A  completed interview in the final data with NO audit.csv in audit.zip (split: Achieved / removed)
  B  audit.csv in audit.zip for a uuid that is not in the final data (an audit with no interview)
  C  audit.csv present but no duration in our cache (parse failure / not yet computed)
  D  audit.zip older than the newest interview in the data (a stale zip)
For C (an audit trail cleaningtools can't total - in practice a question with no end or start time, which makes its
sum NA), the MINIMUM duration is computed with cleaningtools' own row filter (node not blank), summing end - start over
the rows whose start AND end are both recorded: a skipped row's own time is unknown but can't be negative, so the true
duration is at least that. Jack, 16 Oct 2026 (#68): an interview whose minimum already reaches 19.95 minutes passes the
duration rule - final_build_deletion_log.py gives it a kept row stating the minimum (written to
final_audit_incomplete_lower_bounds_<date>.csv).
Exit code 1 if an Achieved interview has no audit file, a C minimum is under 19.95 minutes, or D - so a script run
can't miss it. Writes the uuid-level detail CSV (for Jack/the data officer) to --out (default
reports/partner_data_recovery/outputs/_final_closeout/).

    python -B _working_files/scripts/final_audit_consistency.py [--out <dir>]
"""
import csv
import datetime
import sys
import zipfile
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AUDIT_ZIP = REPO / "cleaning/MSNA_Data_Cleaning/audit/audit.zip"  # the data officer's export - read only
CACHE = REPO / "cleaning/real/audit_duration_cache.csv"
TRACKER = REPO / "reports/partner_data_recovery/scripts/recovery_issue_tracker.csv"
DURATION_RULE_MS = 1_197_000  # 19.95 minutes: the lowest audit-trail duration that rounds to 20.0 at one decimal place


def miss(x):
    return x is None or str(x).strip() in ("", "NA")


def lower_bound(raw):
    """cleaningtools::create_duration_from_audit_sum_all() keeps the rows whose node is not blank and sums end - start;
    one row with a blank start or end makes that sum NA. Same filter here, but summing only the complete rows: returns
    (minimum duration in ms, number of incomplete rows, number of negative rows)."""
    rows = csv.DictReader(raw.decode("utf-8-sig", errors="replace").splitlines())
    total, incomplete, negative = 0, 0, 0
    for r in rows:
        if miss(r.get("node")):
            continue
        s, e = r.get("start"), r.get("end")
        if miss(s) or miss(e):
            incomplete += 1
            continue
        d = float(e) - float(s)
        negative += d < 0
        total += d
    return total, incomplete, negative


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    out_dir = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else \
        REPO / "reports/partner_data_recovery/outputs/_final_closeout"
    out_dir.mkdir(parents=True, exist_ok=True)
    rd = lambda p: list(csv.DictReader(open(p, encoding="utf-8-sig", newline="")))
    subs = {r["submission_uuid"]: r for r in rd(REPO / "data/real_submissions.csv")}
    r1 = {r["submission_uuid"] for r in rd(REPO / "data/ROUND1_MEMBERSHIP.csv")}
    removed = {t["uuid"] for t in rd(TRACKER) if t["issue_type"] == "confirmed_deletion"
               and t["status"] in ("confirmed", "contested") and miss(t["recovery_type"])}
    dur = {r["uuid"] for r in rd(CACHE) if not miss(r["duration_audit_sum_all_ms"])}
    with zipfile.ZipFile(AUDIT_ZIP) as z:
        names = [n for n in z.namelist() if n.replace("\\", "/").lower().endswith("/audit.csv")]
        zuu = Counter(n.replace("\\", "/").rsplit("/", 2)[-2] for n in names)
        last_name = {n.replace("\\", "/").rsplit("/", 2)[-2]: n for n in names}  # the last one, as audit_duration.R keeps
        unparsed = [u for u, r in subs.items() if r["interview_outcome"] == "completed" and u in zuu and u not in dur]
        bounds = {u: lower_bound(z.read(last_name[u])) for u in unparsed}
    zip_mtime = datetime.datetime.fromtimestamp(AUDIT_ZIP.stat().st_mtime)
    newest = max((r["submission_date"] for r in subs.values() if not miss(r["submission_date"])), default="")

    rows = []
    for u, r in subs.items():
        if r["interview_outcome"] != "completed":
            continue
        state = "removed" if u in removed else "Achieved"
        if u not in zuu:
            rows.append(dict(check="A_no_audit_file", uuid=u, status=state, org_id=r["org_id"], submission_date=r["submission_date"],
                             round="Round 1" if u in r1 else "Round 2"))
        elif u not in dur:
            rows.append(dict(check="C_audit_not_parsed", uuid=u, status=state, org_id=r["org_id"], submission_date=r["submission_date"],
                             round="Round 1" if u in r1 else "Round 2"))
    for u in zuu:
        if u not in subs:
            rows.append(dict(check="B_audit_without_interview", uuid=u, status="", org_id="", submission_date="", round=""))
    dups = [u for u, n in zuu.items() if n > 1]

    stamp = datetime.date.today().isoformat()
    path = out_dir / f"final_audit_consistency_{stamp}.csv"
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=["check", "uuid", "status", "org_id", "submission_date", "round"])
        w.writeheader()
        w.writerows(sorted(rows, key=lambda x: (x["check"], x["status"], x["org_id"], x["submission_date"])))

    n_completed = sum(1 for r in subs.values() if r["interview_outcome"] == "completed")
    print(f"audit.zip: {len(zuu):,} interview audit files (modified {zip_mtime:%d %b %Y %H:%M}); final data: {n_completed:,} "
          f"completed interviews, newest interview {newest}")
    for chk in ("A_no_audit_file", "C_audit_not_parsed", "B_audit_without_interview"):
        sel = [x for x in rows if x["check"] == chk]
        print(f"  {chk}: {len(sel)}" + (f"  by status: {dict(Counter(x['status'] for x in sel))}  by org: "
                                         f"{dict(Counter(x['org_id'] for x in sel).most_common())}" if sel and chk != "B_audit_without_interview" else ""))
    stale = newest and zip_mtime.date().isoformat() < newest
    print(f"  D_zip_older_than_data: {'YES - the zip predates the newest interview' if stale else 'no'}")
    if dups:
        print(f"  note: {len(dups)} uuid(s) have more than one audit.csv in the zip (the last one is used)")
    print(f"detail: {path}")
    if bounds:
        bpath = out_dir / f"final_audit_incomplete_lower_bounds_{stamp}.csv"
        with open(bpath, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(["uuid", "org_id", "status", "incomplete_rows", "negative_rows", "lower_bound_ms", "lower_bound_minutes"])
            for u, (ms, inc, neg) in sorted(bounds.items(), key=lambda kv: kv[1][0]):
                w.writerow([u, subs[u]["org_id"], "removed" if u in removed else "Achieved", inc, neg, int(ms), f"{ms / 60000:.2f}"])
        mins = sorted(ms / 60000 for u, (ms, inc, neg) in bounds.items() if u not in removed)
        print(f"  C minimum durations (rule's own row filter, complete rows only), Achieved: "
              f"{len(mins)} from {mins[0]:.2f} to {mins[-1]:.2f} minutes" if mins else "  C: none Achieved")
        print(f"  lower bounds: {bpath}")
    no_file = [x for x in rows if x["check"] == "A_no_audit_file" and x["status"] == "Achieved"]
    could_be_short = [u for u, (ms, inc, neg) in bounds.items() if u not in removed and (ms < DURATION_RULE_MS or neg)]
    if no_file or could_be_short or stale:
        print(f"EXCEPTIONS FOR JACK: {len(no_file)} Achieved interview(s) with no audit file; {len(could_be_short)} with an "
              f"incomplete audit trail whose minimum is under 19.95 minutes (or has a negative row)"
              + ("; the zip is older than the data" if stale else "") + " - report before finalising the log")
        sys.exit(1)
    n_inc = sum(1 for u in bounds if u not in removed)
    print("OK: every Achieved interview has an audit file and the zip is not older than the data"
          + (f"; {n_inc} with an incomplete audit trail are each at least 19.95 minutes - they pass the duration rule "
             f"(Jack, 16 Oct 2026, #68), and the final log gives each a kept row stating its minimum" if n_inc else ""))


if __name__ == "__main__":
    main()
