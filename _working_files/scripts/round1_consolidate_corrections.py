#!/usr/bin/env python3
"""Round 1 closeout - consolidate every Round 1 data correction into ONE final value per (interview, field), with its
full justification chain. Single source of truth for both:
  - the Round 1 deletion & correction log for the data officer (round1_build_deletion_log.py), and
  - the dashboard's corrections overlay (prep_real_submissions.R reads data/ROUND1_CORRECTIONS.csv),
so the log and the dashboard can never disagree about where an interview sits.

Sources, chained in this order per (uuid, field):
  1. earlier-round partner corrections (recorded in tracker resolutions in earlier rounds, never applied to the data)
  2. step-2 partner corrections (the 5 returned Round 1 workbooks, round1_data_corrections.csv). Its 3 date rows are
     not corrections: the partner wrote "Not certain of the exact date" -> left to the date_outlier no_action rows.
  3. closeout rule decisions (round1_resolve_all.py, applied 2 Oct ~01:10)
  4. the final uniqueness pass (log-only suffixes)

Two conflict types found 2 Oct: round1_resolve_all.py judged open items on the RAW record, not the corrected one.
  a. 5 IDP interviews: a partner had already confirmed the real listed household in an earlier round, and the closeout
     still reassigned from the raw number. The partner-confirmed number wins (checked free in the final state below);
     the closeout's reassignment is dropped and, with --fix-tracker, its tracker row's resolution text corrected.
  b. 6 non-IDP interviews carrying BOTH a duplicate_point and a gps_duplicate item: both decisions moved the interview
     to the same nearest drawn point, suffixed _b then _c. The first suffix (_b) is kept; the second row is dropped.
Then validated on the final state of every live Round 1 interview: no claim key shared; every new non-IDP point (suffix
stripped) is a drawn frame point in the interview's final cluster; every reassigned IDP listing number is in the
cluster's real listing.

    python -B _working_files/scripts/round1_consolidate_corrections.py [--fix-tracker]
"""
import csv
import datetime
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "reports/partner_data_recovery/scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import issue_tracker as it  # noqa: E402
from round1_ingest_classify import build_listing_pools  # noqa: E402
from round1_resolve_all import FRAME, claim_key, hav, miss, num, same_household  # noqa: E402

CL = REPO / "reports/partner_data_recovery/outputs/_round1_closeout"
LOG_DIR = REPO / "reports/partner_data_recovery/outputs/_review_decisions_log"
STEP2_SNAPSHOT = LOG_DIR / "2026-10-02_001323_round1_partner_responses_BEFORE.csv"
OUT_CSV = CL / "round1_final_corrections.csv"
DATA_OUT = REPO / "data/ROUND1_CORRECTIONS.csv"
SUFFIX = re.compile(r"_[b-z]$")
ORDER = {"earlier": 1, "step2": 2, "closeout": 3, "unique": 4}
ORG = {"nrc": "NRC", "coopi": "COOPI", "imc": "IMC", "plan": "PLAN", "malteser": "Malteser", "fact": "FACT", "mdm": "MdM",
       "acf": "ACF", "crs": "CRS", "care": "CARE", "si": "SI", "lhi": "LHI", "intersos": "INTERSOS", "zoa": "ZOA",
       "street_child": "Street Child", "iom": "IOM"}


def org(o):
    return ORG.get(o, o.upper().replace("_", " "))


def norm(v):
    """Integer-looking values as written in the export ('8.0') compare equal to '8'."""
    s = "" if v is None else str(v).strip()
    return s[:-2] if re.fullmatch(r"\d+\.0", s) else s


def what(field, value):
    return {"idp_hh_number_from_listing": f"listed household {value}", "idp_walk_position": f"walk position {value}",
            "non_idp_point_id": f"sample point {value}", "cluster_id": f"cluster {value}"}.get(field, f"{field} {value}")


def main():
    fix_tracker = "--fix-tracker" in sys.argv
    trk = it.read_tracker()
    by_id = {t["issue_id"]: t for t in trk}
    subs = {r["submission_uuid"]: r for r in csv.DictReader(open(REPO / "data/real_submissions.csv", encoding="utf-8-sig"))}
    members = {r["submission_uuid"] for r in csv.DictReader(open(REPO / "data/ROUND1_MEMBERSHIP.csv", encoding="utf-8-sig"))}
    settled = {t["uuid"] for t in trk if t["issue_type"] == "confirmed_deletion" and t["status"] in it.TERMINAL_STATUSES
               and miss(t["recovery_type"])}
    live = {u for u in members if subs.get(u, {}).get("interview_outcome") == "completed" and u not in settled}

    # step-2 rows carry no issue_id: recover it from the step-2 apply snapshot (the tracker rows that apply touched)
    step2_ids = defaultdict(list)
    for r in csv.DictReader(open(STEP2_SNAPSHOT, encoding="utf-8")):
        step2_ids[r["uuid"]].append(r["issue_id"])

    steps = defaultdict(list)
    for c in csv.DictReader(open(CL / "round1_data_corrections.csv", encoding="utf-8")):
        if c["field"] == "submission_date":
            continue
        u = c["uuid"]
        text = (f"{org(c['org_id'])} confirmed in its Round 1 recovery workbook ({c['source']}) that this interview was "
                f"{what(c['field'], c['new_value'])}; the answer was checked against the data (a real "
                f"{'listed household' if c['field'] == 'idp_hh_number_from_listing' else 'drawn point'} in the same cluster, "
                f"not held by any other interview) before it was accepted.")
        steps[(u, c["field"])].append(dict(src="step2", old=norm(c["old_value"]), new=norm(c["new_value"]), org_id=c["org_id"],
                                           issue_ids=step2_ids.get(u, []), decision="partner correction (Round 1 workbook)",
                                           text=text, reminder="", decided_by="partner"))
    for i, c in enumerate(csv.DictReader(open(CL / "round1_closeout_corrections.csv", encoding="utf-8"))):
        u, d = c["uuid"], c["decision"]
        t = by_id.get(c["issue_id"], {})
        if d.startswith("earlier-round"):
            src = "earlier"
            text = (f"{org(c['org_id'])} confirmed in an earlier recovery round that this interview was "
                    f"{what(c['field'], c['new_value'])} (MSNA tracker item {t.get('issue_type', '')}, resolved "
                    f"{t.get('resolution_date', '') or 'before Round 1 closeout'}); that confirmation had not yet been applied to the data.")
            decided = "partner"
        elif d.startswith("final uniqueness pass"):
            src = "unique"
            text = (f"After every other correction, a different household (household size or head's sex/age differ) still "
                    f"shared {what(c['field'], c['old_value'])} with an earlier interview; retained, and the identifier "
                    f"suffixed so key-based duplicate checks do not re-flag it (Jack, Round 1 closeout Q3).")
            decided = "internal_team"
        else:
            src = "closeout"
            text = re.sub(r"\s*REVIEW:.*$", "", t.get("resolution", "") or d)
            decided = "internal_team"
        steps[(u, c["field"])].append(dict(src=src, seq=i, old=norm(c["old_value"]), new=norm(c["new_value"]), org_id=c["org_id"],
                                           issue_ids=[c["issue_id"]] if c["issue_id"] else [], decision=d, text=text,
                                           reminder=c["reminder"], decided_by=decided))

    final, dropped = {}, []
    for key, ss in steps.items():
        ss = sorted(ss, key=lambda s: (ORDER[s["src"]], s.get("seq", -1)))
        kept = [ss[0]]
        for s in ss[1:]:
            prev = kept[-1]
            if s["old"] == prev["new"]:
                kept.append(s)
            elif s["old"] == kept[0]["old"] and s["new"] == prev["new"]:
                prev["issue_ids"] = prev["issue_ids"] + [x for x in s["issue_ids"] if x not in prev["issue_ids"]]
            elif s["old"] == kept[0]["old"] and prev["src"] in ("earlier", "step2") and s["src"] == "closeout":
                dropped.append(dict(key=key, kind="a", kept=prev, drop=s))
            elif s["old"] == kept[0]["old"] and prev["src"] == "closeout" and s["src"] == "closeout":
                dropped.append(dict(key=key, kind="b", kept=prev, drop=s))
                prev["issue_ids"] = prev["issue_ids"] + [x for x in s["issue_ids"] if x not in prev["issue_ids"]]
            else:
                raise SystemExit(f"unexplained correction chain for {key}: {[(x['src'], x['old'], x['new']) for x in ss]}")
        if kept[-1]["new"] == kept[0]["old"]:
            raise SystemExit(f"correction chain returns to its starting value for {key}")
        final[key] = kept
    col = {"non_idp_point_id": "matched_survey_id", "idp_hh_number_from_listing": "idp_hh_number_from_listing",
           "idp_walk_position": "idp_walk_position", "cluster_id": "matched_cluster_id", "pop_type": "pop_type"}
    pools = build_listing_pools()

    def final_state():
        st = {u: dict(subs[u]) for u in live}
        for (u, f), kept in final.items():
            if u in st and f in col:
                st[u][col[f]] = kept[-1]["new"]
        ks = defaultdict(list)
        for u, r in st.items():
            k = claim_key(r)
            if k:
                ks[re.sub(r"_(\d+)\.0$", r"_\1", k)].append(u)
        return st, ks

    # conflict a, second pass: the partner-confirmed number only wins where it is free. Where another live interview (a
    # different household) already holds it, Q3-C applies to the partner-confirmed number, and the closeout's
    # reassignment to a free listed household stands - chained after the partner's step, so the log tells both.
    state, keys = final_state()
    for d in [d for d in dropped if d["kind"] == "a"]:
        (u, f), partner, closeout = d["key"], d["kept"], d["drop"]
        k = re.sub(r"_(\d+)\.0$", r"_\1", claim_key(state[u]) or "")
        if len(keys.get(k, [])) > 1:
            cl = state[u]["matched_cluster_id"]
            not_listed = cl in pools and int(partner["new"]) not in pools[cl]
            closeout = dict(closeout, old=partner["new"],
                            text=(f"{what(f, partner['new'])} is already held by a different household's interview"
                                  f"{' and is not among the drawn households of the cluster' + chr(39) + 's household listing' if not_listed else ''}, "
                                  f"so (Jack, Round 1 closeout Q3-C) this interview was reassigned to the nearest free listed household, "
                                  f"{closeout['new']}."))
            final[d["key"]] = [partner, closeout]
            d["kind"] = "a-collide"
    print(f"(uuid, field) pairs: {len(final)} | conflicting rows: {Counter(d['kind'] for d in dropped)}")
    for d in dropped:
        k = final[d["key"]]
        print(f"  [{d['kind']}] {d['key'][0][:8]} {d['key'][1]}: final chain {' -> '.join([k[0]['old']] + [s['new'] for s in k])} "
              f"({'+'.join(s['src'] for s in k)})")

    # ---- final state of every live Round 1 interview -------------------------------------------------------------
    state, keys = final_state()
    shared = {k: v for k, v in keys.items() if len(v) > 1}
    print(f"\nFINAL STATE: {len(state)} live Round 1 interviews | claim keys shared by 2+: {len(shared)}")
    for k, v in shared.items():
        print(f"  {k}: {len(v)} interviews | same household as the first: {[same_household(state[v[0]], state[x]) for x in v[1:]]}")

    # ---- validation of every changed value: hard problems stop the run; soft ones become review reminders ------------
    pts, clusters = {}, set()
    for r in csv.DictReader(open(FRAME, encoding="utf-8-sig")):
        clusters.add(r["cluster_id"])
        if r["pop_type"] == "non_idp":
            pts[r["survey_id"]] = r["cluster_id"]
    problems, soft = [], {}
    for (u, f), kept in final.items():
        new = kept[-1]["new"]
        cl = state.get(u, subs.get(u, {})).get("matched_cluster_id", "")
        if f == "non_idp_point_id":
            base = SUFFIX.sub("", new)
            if base not in pts:
                problems.append(f"{u[:8]} point {new}: {base} is not a drawn non-IDP point")
            elif u in state and pts[base] != cl:
                problems.append(f"{u[:8]} point {new} is in {pts[base]} but the interview's final cluster is {cl}")
        elif f == "cluster_id" and new not in clusters:
            problems.append(f"{u[:8]} cluster {new} is not in the frame")
        elif f == "idp_hh_number_from_listing" and not SUFFIX.search(new) and cl in pools and int(new) not in pools[cl]:
            if kept[-1]["src"] in ("earlier", "step2"):
                soft[(u, f)] = (f"Partner-confirmed household number {new} is not among the drawn (primary/reserve) households of "
                                f"this cluster's latest household listing submission; check it against the listing actually used "
                                f"in the field before linking this interview to the listing.")
            else:
                problems.append(f"{u[:8]} listing number {new} ({kept[-1]['src']}) is not in {cl}'s real listing")
    print(f"\nVALIDATION: hard problems {len(problems)} | partner numbers outside the latest listing (reminder added): {len(soft)}")
    for p in problems:
        print("  ", p)
    if problems or shared:
        raise SystemExit("validation failed - nothing written")

    # ---- outputs ----------------------------------------------------------------------------------------------------
    rows = []
    for (u, f), kept in sorted(final.items()):
        last = kept[-1]
        ids = []
        for s in kept:
            ids += [x for x in s["issue_ids"] if x not in ids]
        rows.append(dict(uuid=u, org_id=last["org_id"], field=f, old_value=kept[0]["old"], new_value=last["new"],
                         n_steps=len(kept), sources="+".join(s["src"] for s in kept), issue_ids=";".join(ids),
                         decided_by=last["decided_by"], decision=last["decision"],
                         justification=" Then: ".join(s["text"] for s in kept),
                         reminder=next((s["reminder"] for s in kept if s["reminder"]), "") or soft.get((u, f), ""),
                         in_round1_live=u in state))
    rows += distance_rows(rows)
    with open(OUT_CSV, "w", newline="", encoding="utf-8") as fo:
        w = csv.DictWriter(fo, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    prep_fields = set(col) | {"dist_btn_sample_collected"}
    with open(DATA_OUT, "w", newline="", encoding="utf-8") as fo:
        w = csv.writer(fo)
        w.writerow(["submission_uuid", "field", "new_value"])
        for r in rows:
            if r["field"] in prep_fields:
                w.writerow([r["uuid"], r["field"], r["new_value"]])
    print(f"\nwrote {OUT_CSV.name}: {len(rows)} rows | {DATA_OUT.relative_to(REPO)}: "
          f"{sum(r['field'] in prep_fields for r in rows)} rows | by field: {dict(Counter(r['field'] for r in rows))}")
    print("by sources:", dict(Counter(r["sources"] for r in rows)))

    if fix_tracker:
        fix(trk, dropped, final)


def distance_rows(rows):
    """dist_btn_sample_collected for every interview whose sample point actually MOVED (a different drawn point or an
    IDP site, not just a suffix on the same point) - the master log's own sampling recoveries set it too. New value =
    device GPS (the DO's raw export, 29 Sep) to the new point's frame coordinates; old value = device GPS to the point
    the form used (pt_sample_lat/lon); both by the form's own formula (haversine, metres, 1 decimal). No device GPS ->
    no row: the form's value stays (said in the log's readme)."""
    gps, pt_form = {}, {}
    for r in csv.DictReader(open(REPO / "reports/partner_data_recovery/outputs/_round1_closeout/_private/_round1_raw_gps.csv", encoding="utf-8")):
        la, lo = num(r["_geopoint_latitude"]), num(r["_geopoint_longitude"])
        if la and lo:
            gps[r["_uuid"]] = (la, lo)
            pla, plo = num(r["pt_sample_lat"]), num(r["pt_sample_lon"])
            if pla and plo:
                pt_form[r["_uuid"]] = (pla, plo)
    coords = {}
    for r in csv.DictReader(open(FRAME, encoding="utf-8-sig")):
        if not miss(r["latitude"]):
            coords.setdefault(r["survey_id"] if r["pop_type"] == "non_idp" else r["cluster_id"], (float(r["latitude"]), float(r["longitude"])))
    by_u = defaultdict(dict)
    for r in rows:
        by_u[r["uuid"]][r["field"]] = r
    out, no_gps = [], 0
    for u, f in by_u.items():
        r = f.get("non_idp_point_id") or f.get("sample_point_id")
        if r is None:
            continue
        old_base, new_base = SUFFIX.sub("", r["old_value"]), SUFFIX.sub("", r["new_value"])
        if new_base == old_base or new_base not in coords:
            continue
        if u not in gps:
            no_gps += 1
            continue
        d_new = round(hav(*gps[u], *coords[new_base]), 1)
        d_old = round(hav(*gps[u], *pt_form[u]), 1) if (u in pt_form and old_base) else ""
        # a partner's answer that puts the interview far from where the device actually was is kept (accepted in
        # step 2 / an earlier round) but must not pass silently - reminder on the point row itself
        if r["decided_by"] == "partner" and d_new > 500 and not r["reminder"]:
            r["reminder"] = (f"Device GPS is {d_new:.0f} m from the partner-confirmed point"
                             + (f" (the originally recorded point was {d_old:.0f} m away)" if d_old != "" else "")
                             + " - check the partner's answer before using this interview's point.")
        out.append(dict(r, field="dist_btn_sample_collected", old_value=str(d_old), new_value=str(d_new), n_steps=1,
                        decision="recomputed for the new sample point", decided_by="internal_team", reminder="",
                        justification=(f"Recomputed for the new sample point {new_base}: {d_new} m from the device GPS to the "
                                       f"point's frame coordinates (the form's own distance formula).")))
    print(f"distance rows: {len(out)} (moved interviews without device GPS in the 29 Sep raw export, left as recorded: {no_gps})")
    return out


def fix(trk, dropped, final):
    """Correct the tracker text of the rows whose closeout decision was superseded (conflict a) or merged (conflict b),
    so the tracker, the log and the dashboard all tell the same story. Snapshot first; statuses/recovery types unchanged."""
    idx = {t["issue_id"]: i for i, t in enumerate(trk)}
    today = datetime.date.today().isoformat()
    edits = {}
    for d in dropped:
        (u, f), chain = d["key"], final[d["key"]]
        for iid in d["drop"]["issue_ids"]:
            t = dict(trk[idx[iid]])
            if d["kind"] == "a":
                t["resolution"] = (f"Round 1 closeout (Jack, Q3/Q4): the partner had already confirmed in an earlier recovery round "
                                   f"that this interview was {what(f, chain[-1]['new'])} - that confirmed number is used (free in the "
                                   f"cluster after every Round 1 correction), so it is not a duplicate at the originally recorded "
                                   f"number {d['drop']['old']}. Corrected {today}: the first closeout pass had reassigned it from "
                                   f"the raw number ({d['drop']['old']} -> {d['drop']['new']}).")
                t["fallback_mechanism"] = "partner_correction_earlier_round"
                t["fallback_status"] = "rule_resolved"
            elif d["kind"] == "a-collide":
                t["resolution"] = (f"Round 1 closeout (Jack, Q3-C): the partner had confirmed {what(f, chain[0]['new'])} in an earlier "
                                   f"recovery round, but {chain[-1]['text'][0].lower() + chain[-1]['text'][1:]}")
            t["fallback_resolution"] = re.sub(r"\|.*$", f"| {f}: {chain[0]['old']} -> {chain[-1]['new']}", t["fallback_resolution"]) \
                if "|" in t["fallback_resolution"] else t["fallback_resolution"]
            if t != trk[idx[iid]]:
                edits[iid] = t
    if not edits:
        print("tracker: nothing to fix")
        return
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    snap = LOG_DIR / f"{stamp}_round1_consolidate_fix_BEFORE.csv"
    with open(snap, "w", newline="", encoding="utf-8") as fo:
        w = csv.DictWriter(fo, fieldnames=it.COLUMNS)
        w.writeheader()
        w.writerows(trk[idx[i]] for i in edits)
    for iid, t in edits.items():
        trk[idx[iid]] = t
    it.write_tracker(trk)
    with open(LOG_DIR / f"{today}.log", "a", encoding="utf-8") as fo:
        fo.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} | decided_by=internal_team (Round 1 closeout consistency fix) | "
                 f"n={len(edits)} | resolution text of superseded closeout decisions corrected | snapshot={snap.name}\n")
    print(f"tracker: {len(edits)} row(s) corrected | snapshot {snap.name}")


if __name__ == "__main__":
    main()
