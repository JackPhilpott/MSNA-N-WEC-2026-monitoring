#!/usr/bin/env python3
"""Round 1 closeout follow-up (Jack, direct, 2 Oct 2026): reinstate the five duration removals the duration rule does
not support, and define the rule.

THE DURATION RULE (defined 2 Oct 2026, Jack): an interview is removed for short duration only when its audit-trail
duration (cleaningtools' create_duration_from_audit_sum_all - the sum of time spent on questions), rounded to one
decimal place of a minute, is below 20.0 minutes - that is, when it is under 19.95 minutes (1,197,000 ms). This is
what both the data officer's own check and the MSNA team's independent check already compute (both round to one
decimal first). Five earlier removals didn't follow it:
  - 4 interviews of 19.96-19.99 minutes (20.0 at one decimal), removed by earlier processes: the 30 Aug quality
    exclusions list, and IMC's 3 Sep contested batch;
  - MdM 8610c2bf, 24.4 minutes, removed 8 Sep on the data officer's duration flag of the time, which the full audit
    trail does not support.
Each is reinstated: its tracker row gets recovery_type false_positive (status confirmed) with the reason, so the
CONFIRMED overlay stops excluding it.

A reinstated interview must not reopen a duplicate. Three of the five had their sample point / listed household taken
by a later interview of a DIFFERENT household after they were removed (a re-visit). Jack's Q3 rule applies as in the
closeout: the first upload keeps the point (here always the reinstated interview), and the later, different household
is reassigned to the nearest free household (non-IDP: a free drawn point within 150 m of its device GPS, cluster first,
then stratum; IDP: the nearest free number in the cluster's real household listing), else kept with the next suffix.
Those corrections go to outputs/_round1_closeout/round1_reinstatement_corrections.csv, which
round1_consolidate_corrections.py chains after every other Round 1 correction. A same-household clash, or one where the
reinstated interview is the LATER upload, stops the run for a decision instead.

    python -B _working_files/scripts/round1_reinstate_duration_rounding.py            # dry run
    python -B _working_files/scripts/round1_reinstate_duration_rounding.py --apply    # Jack's decision, 2 Oct
"""
import csv
import datetime
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "reports/partner_data_recovery/scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import issue_tracker as it  # noqa: E402
from round1_ingest_classify import build_listing_pools  # noqa: E402
from round1_resolve_all import FRAME, GPS, same_household  # noqa: E402

CL = REPO / "reports/partner_data_recovery/outputs/_round1_closeout"
CORR_OUT = CL / "round1_reinstatement_corrections.csv"
LOG_DIR = REPO / "reports/partner_data_recovery/outputs/_review_decisions_log"
CAP_M = 150.0
SUFFIX = re.compile(r"_[b-z]$")
RULE_MS = 1_197_000  # 19.95 minutes: the lowest duration that rounds to 20.0 at one decimal place
EXPECTED = {"9c7ddf53", "0b5181ed", "b890cf83", "406bde9b", "8610c2bf"}
DECIDED_BY = "Jack (direct, 2 Oct 2026: reinstate all five; duration rule = under 20.0 at one decimal)"


def miss(x):
    return x is None or str(x).strip() in ("", "NA")


def hav(a, b, c, d):
    p = math.pi / 180
    x = math.sin((c - a) * p / 2) ** 2 + math.cos(a * p) * math.cos(c * p) * math.sin((d - b) * p / 2) ** 2
    return 2 * 6371000 * math.asin(min(1, math.sqrt(x)))


def plan_q3(later, first, live_rows):
    """Jack's Q3-C for the LATER claimant of a shared key (a different household from the first): nearest free
    household, else the next suffix. live_rows = every live interview's real_submissions row after reinstatement."""
    gps = {}
    for r in csv.DictReader(open(GPS, encoding="utf-8")):
        try:
            gps[r["_uuid"]] = (float(r["_geopoint_latitude"]), float(r["_geopoint_longitude"]))
        except ValueError:
            pass
    u = later["submission_uuid"]
    why_first = (f"A different household's interview recorded at the same identifier was uploaded first ({first['submission_uuid']}, "
                 f"reinstated 2 Oct under the duration rule) and keeps it")
    if later["pop_type"] == "idp":
        cl, cur = later["matched_cluster_id"], later["idp_hh_number_from_listing"]
        taken = {int(r["idp_hh_number_from_listing"]) for r in live_rows if r["matched_cluster_id"] == cl
                 and re.fullmatch(r"\d+", r["idp_hh_number_from_listing"] or "")}
        free = sorted(build_listing_pools().get(cl, set()) - taken)
        if free and re.fullmatch(r"\d+", cur):
            n = min(free, key=lambda x: (abs(x - int(cur)), x))
            return [("idp_hh_number_from_listing", cur, str(n))], "REASSIGN listing number", (
                f"{why_first}; this later interview is reassigned to the nearest free number in the cluster's real household "
                f"listing ({cur} -> {n}) (Jack, Q3-C).")
        held = {r["idp_hh_number_from_listing"] for r in live_rows if r["matched_cluster_id"] == cl}
        new = next(f"{cur}_{s}" for s in "bcdefghijklmnopqrstuvwxyz" if f"{cur}_{s}" not in held)
        return [("idp_hh_number_from_listing", cur, new)], "KEEP (distinct household, suffix)", (
            f"{why_first}; no free number left in the cluster's listing, so this later interview is kept and its number "
            f"suffixed (Jack, Q3-C).")
    pts = {}
    for r in csv.DictReader(open(FRAME, encoding="utf-8-sig")):
        if r["pop_type"] == "non_idp" and not miss(r["latitude"]):
            pts[r["survey_id"]] = (r["cluster_id"], r["strata_id"], float(r["latitude"]), float(r["longitude"]))
    taken = {r["matched_survey_id"] for r in live_rows if r["pop_type"] == "non_idp" and not miss(r["matched_survey_id"])}
    cur, loc = later["non_idp_point_id"], gps.get(u)
    if loc is None:
        raise SystemExit(f"{u}: no device GPS to place it from - decide by hand")
    for scope in ("cluster", "strata"):
        cand = [(p, v) for p, v in pts.items() if p not in taken and
                (v[0] == later["matched_cluster_id"] if scope == "cluster" else v[1] == later["matched_strata_id"])]
        if cand:
            p, v = min(cand, key=lambda pv: hav(*loc, pv[1][2], pv[1][3]))
            d = hav(*loc, v[2], v[3])
            if d <= CAP_M:
                corr = [("non_idp_point_id", cur, p)] + ([("cluster_id", later["matched_cluster_id"], v[0])] if v[0] != later["matched_cluster_id"] else [])
                return corr, "REASSIGN point", (f"{why_first}; this later interview is reassigned to the nearest free point "
                                                f"({d:.0f} m from its device GPS) (Jack, Q3-C).")
            break
    base, bv = min(((p, v) for p, v in pts.items() if v[1] == later["matched_strata_id"]), key=lambda pv: hav(*loc, pv[1][2], pv[1][3]))
    held = {r["non_idp_point_id"] for r in live_rows}
    new = next(f"{base}_{s}" for s in "bcdefghijklmnopqrstuvwxyz" if f"{base}_{s}" not in held)
    corr = [("non_idp_point_id", cur, new)] + ([("cluster_id", later["matched_cluster_id"], bv[0])] if bv[0] != later["matched_cluster_id"] else [])
    return corr, "KEEP (distinct household, suffix)", (
        f"{why_first}; no free point within {CAP_M:.0f} m of this later interview's device GPS, so it is kept at the drawn point "
        f"nearest to where the device was ({hav(*loc, bv[2], bv[3]):.0f} m), its identifier suffixed (Jack, Q3-C).")


def claim_key(r):
    """scripts/shared/live_claims.R claim_key(), on real_submissions.csv as it now stands (corrections applied)."""
    if r["pop_type"] == "idp":
        if not miss(r["idp_hh_number_from_listing"]):
            return f'{r["matched_cluster_id"]}|listing_{r["idp_hh_number_from_listing"]}'
        if not miss(r["idp_walk_position"]):
            return f'{r["matched_cluster_id"]}|walk_{r["idp_walk_position"]}'
        return None
    if miss(r["matched_survey_id"]):
        return None
    return r["non_idp_point_id"] if not miss(r["non_idp_point_id"]) else r["matched_survey_id"]


def main():
    apply = "--apply" in sys.argv
    trk = it.read_tracker()
    subs = {r["submission_uuid"]: r for r in csv.DictReader(open(REPO / "data/real_submissions.csv", encoding="utf-8-sig"))}
    members = {r["submission_uuid"] for r in csv.DictReader(open(REPO / "data/ROUND1_MEMBERSHIP.csv", encoding="utf-8-sig"))}
    ms = {r["uuid"]: float(r["duration_audit_sum_all_ms"])
          for r in csv.DictReader(open(REPO / "cleaning/real/audit_duration_cache.csv", encoding="utf-8-sig"))}

    def settled(t):
        return t["issue_type"] == "confirmed_deletion" and t["status"] in it.TERMINAL_STATUSES and miss(t["recovery_type"])

    targets = [t for t in trk if settled(t) and t["uuid"] in members and t["uuid"] in ms and ms[t["uuid"]] >= RULE_MS
               and (t["deletion_reason"] == "duration_under_20" or (t["status"] == "contested" and miss(t["deletion_reason"])))]
    print(f"duration removals the rule does not support: {len(targets)}")
    for t in targets:
        print(f"  {t['uuid'][:8]} {t['org_id']:8s} {ms[t['uuid']] / 60000:7.3f} min | {t['status']} | {t['resolution'][:70]}")
    if {t["uuid"][:8] for t in targets} != EXPECTED:
        raise SystemExit("not the five interviews Jack decided on - stopping")

    # would any of the five reopen a duplicate? (live = completed Round 1, not settled-deleted, after reinstatement)
    gone = {t["uuid"] for t in trk if settled(t)} - {t["uuid"] for t in targets}
    holders = defaultdict(list)
    for u in members:
        r = subs[u]
        if r["interview_outcome"] == "completed" and u not in gone:
            k = claim_key(r)
            if k:
                holders[k].append(u)
    clashes = {t["uuid"]: holders[claim_key(subs[t["uuid"]])] for t in targets
               if claim_key(subs[t["uuid"]]) and len(holders[claim_key(subs[t["uuid"]])]) > 1}
    print(f"claim-key clashes with live interviews: {len(clashes)}")
    live_rows = [subs[u] for hs in holders.values() for u in hs]
    corr_rows = []
    for u, hs in clashes.items():
        others = [h for h in hs if h != u]
        if len(others) != 1:
            raise SystemExit(f"{u}: shares its key with {len(others)} live interviews - decide by hand")
        mine, other = subs[u], subs[others[0]]
        if (other["uploaded_at"] or "~") < (mine["uploaded_at"] or "~"):
            raise SystemExit(f"{u}: the reinstated interview is the LATER upload at {claim_key(mine)} - a decision for Jack")
        if same_household(mine, other) is not False:
            raise SystemExit(f"{u}: same household (or unknown) as {others[0]} at {claim_key(mine)} - a decision for Jack")
        corr, decision, why = plan_q3(other, mine, live_rows)
        print(f"  {u[:8]} keeps {claim_key(mine)} (first upload); later {others[0][:8]} ({other['org_id']}, different household): "
              f"{decision} | {'; '.join(f'{f}: {o} -> {n}' for f, o, n in corr)}")
        for f, o, n in corr:
            corr_rows.append(dict(uuid=others[0], org_id=other["org_id"], field=f, old_value=o, new_value=n, decision=decision,
                                  justification=why, reinstated_first_claimant=u))
    for t in targets:
        r = subs[t["uuid"]]
        print(f"  {t['uuid'][:8]} -> Achieved in {r['matched_strata_id']} (completed={r['interview_outcome'] == 'completed'}, "
              f"matched={not miss(r['matched_survey_id'])})")
    if not apply:
        print("\nDRY RUN - nothing written. Re-run with --apply.")
        return
    with open(CORR_OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["uuid", "org_id", "field", "old_value", "new_value", "decision", "justification",
                                          "reinstated_first_claimant"])
        w.writeheader()
        w.writerows(corr_rows)
    print(f"wrote {CORR_OUT.name}: {len(corr_rows)} correction(s) for the later claimants")

    today = datetime.date.today().isoformat()
    idx = {t["issue_id"]: i for i, t in enumerate(trk)}
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    snap = LOG_DIR / f"{stamp}_round1_reinstate_duration_rounding_BEFORE.csv"
    with open(snap, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=it.COLUMNS)
        w.writeheader()
        w.writerows(trk[idx[t["issue_id"]]] for t in targets)
    for t in targets:
        m = ms[t["uuid"]] / 60000
        if m >= 20:
            why = (f"Reinstated (Jack, 2 Oct 2026): the audit-trail duration is {m:.1f} minutes, above the 20-minute threshold. "
                   f"The {t['resolution_date']} removal rested on the data officer's duration flag of the time, which the full "
                   f"audit trail does not support.")
        else:
            why = (f"Reinstated (Jack, 2 Oct 2026): the audit-trail duration is {m:.2f} minutes, which is 20.0 at one decimal "
                   f"place. The duration rule removes an interview only when it is under 20.0 minutes at one decimal place "
                   f"(under 19.95 minutes) - the same rounding the data officer's own check uses. Removed earlier "
                   f"({t['resolution_date']}) by a process that compared the unrounded value.")
        trk[idx[t["issue_id"]]].update(
            status="confirmed", recovery_type="false_positive", confirmed_by="internal_team",
            deletion_reason=t["deletion_reason"] or "duration_under_20", resolution=why, resolution_date=today,
            fallback_status="rule_resolved", fallback_mechanism="duration_rule_one_decimal",
            fallback_resolution=f"REINSTATED | audit-trail duration {m:.3f} min", fallback_applied_date=today)
    it.write_tracker(trk)
    with open(LOG_DIR / f"{today}.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} | decided_by={DECIDED_BY} | n={len(targets)} | duration removals "
                f"reinstated under the defined duration rule (removed only when under 19.95 min) | snapshot={snap.name} | "
                f"issue_ids={';'.join(t['issue_id'] for t in targets)}\n")
    print(f"\nAPPLIED: {len(targets)} reinstated | snapshot {snap.name}")


if __name__ == "__main__":
    main()
