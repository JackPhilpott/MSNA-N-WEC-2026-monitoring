#!/usr/bin/env python3
"""Round 1 recovery closeout, step 4 - resolve EVERY remaining open tracker item under Jack's decisions (1-2 Oct).

Dry run by default: writes outputs/_round1_closeout/round1_resolution_preview.csv + a summary, changes nothing.
--apply: snapshot of every touched row -> final statuses written -> decisions-log line -> corrections file.
--restore <snapshot>: one-call undo.

Decisions (Jack):
  duplicate_point (Q3) - compare with the earliest LIVE sibling sharing the same claim key (live_claims.R key):
    A/B same household (hh size + head sex + head age +-2; head = respondent when resp_hoh_yn = yes) -> DELETE
    D no live sibling left (it was deleted)                                          -> CLEAR (live-claimant rule)
    C different household -> REASSIGN to the nearest FREE household; if none (or too far) -> KEEP with a "_b" suffix
  gps_duplicate (Q3, the 11) -> REASSIGN to the nearest free point to the device GPS
  listing_missing (Q4) -> household number in the cluster's real listing pool = KEEP; not in pool = nearest free number
  date_outlier (Q6) -> KEEP as an exception
  crs_unmatched (Q5) -> place by device GPS: IDP site within 150 m = assign to the site; else non-IDP point within 150 m:
    free = assign, live-claimed = KEEP with "_b"; nothing within 150 m = DELETE. Placed ones carry a review reminder.
  missing_hh_listing -> cluster now has a real listing = CLOSE (evidence); else IOM DTM site = CLOSE (backup)
Q8: every outcome is final (status confirmed), confirmed_by internal_team, and marked as backup/rule-resolved in
fallback_status / fallback_mechanism so it stays distinguishable from a partner-confirmed resolution.

"Free" = no LIVE interview (completed, not settled-deleted) holds it, not claimed by a step-2 partner correction,
and not already assigned in this run. Non-IDP distance comes from the raw device geopoint
(reports/partner_data_recovery/outputs/_round1_closeout/_private/_round1_raw_gps.csv), falling back to latitude_submitted, then the claimed point's frame location.

    python -B _working_files/scripts/round1_resolve_all.py [--apply] [--cap-m 150]
"""
import csv
import datetime
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "reports/partner_data_recovery/scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import issue_tracker as it  # noqa: E402
from round1_ingest_classify import build_listing_pools  # noqa: E402

OUT = REPO / "reports/partner_data_recovery/outputs/_round1_closeout"
LOG_DIR = REPO / "reports/partner_data_recovery/outputs/_review_decisions_log"
STEP2_CORR = OUT / "round1_data_corrections.csv"
FRAME = REPO / "input_data/sampling_frame/NGA_MSNA_2026_stage2_sampling_frame_v14_FULL.csv"
GPS = REPO / "reports/partner_data_recovery/outputs/_round1_closeout/_private/_round1_raw_gps.csv"
DTM_DIR = REPO.parent / "1_sampling/input_data/population/iom"
REMINDER = ("Population group never recorded on the device (sampling section incomplete) - placed by GPS; "
            "check that IDP/non-IDP-specific questions were answered before using this interview.")
DECIDED_BY = "Jack (Round 1 closeout, Q3-Q8 decisions 2026-10-01/02)"
# Interviews far from EVERY drawn point in their stratum (device GPS) - Jack, 2 Oct: delete the one 4.7 km away
# (not at a sampled location); keep the three at 570-750 m (likely inside the cluster area, not at a drawn building)
# with a review reminder. Rule: more than FAR_DELETE_M from every drawn point = delete; 500 m-FAR_DELETE_M = keep, flagged.
FAR_DELETE_M = 2000.0
TERMINAL = it.TERMINAL_STATUSES


def miss(x):
    return x is None or str(x).strip() in ("", "NA")


def num(x):
    try:
        return None if miss(x) else float(x)
    except ValueError:
        return None


def hav(a, b, c, d):
    p = math.pi / 180
    x = math.sin((c - a) * p / 2) ** 2 + math.cos(a * p) * math.cos(c * p) * math.sin((d - b) * p / 2) ** 2
    return 2 * 6371000 * math.asin(min(1, math.sqrt(x)))


def claim_key(r):  # mirror of scripts/shared/live_claims.R claim_key()
    if r["pop_type"] == "idp":
        if not miss(r["idp_hh_number_from_listing"]):
            return f'{r["matched_cluster_id"]}|listing_{r["idp_hh_number_from_listing"]}'
        if not miss(r["idp_walk_position"]):
            return f'{r["matched_cluster_id"]}|walk_{r["idp_walk_position"]}'
        return None
    return None if miss(r["matched_survey_id"]) else r["matched_survey_id"]


def head(r):
    if str(r["resp_hoh_yn"]).lower() == "yes":
        return r["resp_gender"], num(r["resp_age"])
    return r["hoh_gender"], num(r["hoh_age"])


def same_household(a, b):
    (ga, aa), (gb, ab) = head(a), head(b)
    if miss(ga) or miss(gb) or aa is None or ab is None or num(a["hh_size"]) is None or num(b["hh_size"]) is None:
        return None
    return num(a["hh_size"]) == num(b["hh_size"]) and ga == gb and abs(aa - ab) <= 2


def load():
    trk = it.read_tracker()
    subs = {r["submission_uuid"]: r for r in csv.DictReader(open(REPO / "data/real_submissions.csv", encoding="utf-8-sig"))}
    gps = {}
    for r in csv.DictReader(open(GPS, encoding="utf-8")):
        la, lo = num(r["_geopoint_latitude"]), num(r["_geopoint_longitude"])
        if la and lo:
            gps[r["_uuid"]] = (la, lo)
    settled = {t["uuid"] for t in trk if t["issue_type"] == "confirmed_deletion" and t["status"] in TERMINAL and miss(t["recovery_type"])}
    live = {u for u, r in subs.items() if r["interview_outcome"] == "completed" and u not in settled}
    pts, sites = {}, {}
    for r in csv.DictReader(open(FRAME, encoding="utf-8-sig")):
        if miss(r["latitude"]):
            continue
        rec = (r["survey_id"], r["cluster_id"], r["strata_id"], float(r["latitude"]), float(r["longitude"]), r["adm2_pcode"])
        if r["pop_type"] == "non_idp":
            pts[r["survey_id"]] = rec
        else:
            sites.setdefault(r["cluster_id"], (r["cluster_id"], r["cluster_id"], r["strata_id"], float(r["latitude"]),
                                               float(r["longitude"]), r["adm2_pcode"], r.get("iom_site_id", ""), r.get("iom_site_name", "")))
    corr = list(csv.DictReader(open(STEP2_CORR, encoding="utf-8"))) if STEP2_CORR.exists() else []
    return trk, subs, gps, settled, live, pts, sites, corr


def main():
    apply = "--apply" in sys.argv
    if "--restore" in sys.argv:
        return restore(sys.argv[sys.argv.index("--restore") + 1])
    cap = float(sys.argv[sys.argv.index("--cap-m") + 1]) if "--cap-m" in sys.argv else 150.0
    trk, subs, gps, settled, live, pts, sites, corr = load()
    pools = build_listing_pools()

    # Corrections partners gave in EARLIER recovery rounds were only ever written into the tracker's resolution text
    # ("recovered - confirmed real listing number 3", an idp_listing_duplicate resolution "67", a gps_duplicate
    # resolution "non_idp_..._R06") and never applied to the data - found 2 Oct as leftover duplicate keys (52 rows,
    # 41 interviews, MDM + IMC). They belong in the cleaning log and must count as taken when picking free households.
    import re
    earlier = {}
    for t in trk:
        if t["status"] != "confirmed" or miss(t["uuid"]) or not t["resolution"] or not miss(t["fallback_status"]):
            continue
        res = t["resolution"].strip()
        r0 = subs.get(t["uuid"])
        if r0 is None:
            continue
        m_ln = re.search(r"confirmed real listing number (\d+)", res) or (re.fullmatch(r"\d+", res) and t["issue_type"] == "idp_listing_duplicate" and re.fullmatch(r"(\d+)", res))
        m_pt = re.search(r"confirmed household (non_idp_\S+)", res) or re.fullmatch(r"(non_idp_\S+)", res)
        if m_ln:
            new, f, old = m_ln.group(1), "idp_hh_number_from_listing", str(r0["idp_hh_number_from_listing"]).split(".0")[0]
        elif m_pt:
            new, f, old = m_pt.group(1), "non_idp_point_id", r0["matched_survey_id"]
        else:
            continue
        if new != old:
            earlier.setdefault((t["uuid"], f), (old, new, t["org_id"], t["issue_id"]))
    print(f"earlier-round corrections recovered from tracker resolutions: {len(earlier)}")

    # who holds what (LIVE interviews only), with step-2 AND earlier-round partner corrections overlaid
    corr_pt = {u: v[1] for (u, f), v in earlier.items() if f == "non_idp_point_id"}
    corr_ln = {u: v[1] for (u, f), v in earlier.items() if f == "idp_hh_number_from_listing"}
    corr_pt.update({c["uuid"]: c["new_value"] for c in corr if c["field"] == "non_idp_point_id"})
    corr_ln.update({c["uuid"]: c["new_value"] for c in corr if c["field"] == "idp_hh_number_from_listing"})
    pt_taken, ln_taken = set(), set()
    for u in live:
        r = subs[u]
        if r["pop_type"] == "non_idp":
            for v in (corr_pt.get(u), r["matched_survey_id"], r["non_idp_point_id"]):
                if not miss(v):
                    pt_taken.add(v)
        elif r["pop_type"] == "idp" and not miss(r["matched_cluster_id"]):
            n = num(corr_ln.get(u)) if u in corr_ln else num(r["idp_hh_number_from_listing"])
            if n is not None:
                ln_taken.add((r["matched_cluster_id"], int(n)))
    def corrected(u):
        """This interview's record with every already-known partner correction applied (earlier rounds + step 2)."""
        r = dict(subs[u])
        if u in corr_pt:
            r["matched_survey_id"] = corr_pt[u]
        if u in corr_ln:
            r["idp_hh_number_from_listing"] = corr_ln[u]
        return r

    groups = defaultdict(list)  # siblings are judged at their CORRECTED key - an interview a partner already moved off a key isn't a sibling there
    for u in live:
        k = claim_key(corrected(u))
        if k:
            groups[k].append(u)
    order = lambda u: (subs[u]["uploaded_at"] or "~", subs[u]["start_datetime"] or "")

    def anchor(r):
        u = r["submission_uuid"]
        if u in gps:
            return gps[u], "device GPS"
        if num(r["latitude_submitted"]) and num(r["longitude_submitted"]):
            return (num(r["latitude_submitted"]), num(r["longitude_submitted"])), "submitted GPS"
        for v in (r["non_idp_point_id"], r["matched_survey_id"]):
            if v in pts:
                return (pts[v][3], pts[v][4]), "claimed point location"
        return None, None

    pts_by_strata = defaultdict(list)
    for p in pts.values():
        pts_by_strata[p[2]].append(p)

    def nearest_drawn_point(r, loc):
        """Nearest drawn non-IDP point of ANY kind (free or held) in the interview's own stratum - where the household
        physically was, for the 'keep' cases."""
        cand = pts_by_strata.get(r["matched_strata_id"]) or []
        if not cand or not loc:
            return None
        p = min(cand, key=lambda p: hav(loc[0], loc[1], p[3], p[4]))
        return p, hav(loc[0], loc[1], p[3], p[4])

    suffix_used = defaultdict(int)  # base identifier -> how many extra households already suffixed onto it

    def next_suffix(base):
        suffix_used[base] += 1
        return f"{base}_{'bcdefghijklmnopqrstuvwxyz'[suffix_used[base] - 1]}"

    def nearest_free_point(r, loc):
        best = None
        for scope in ("cluster", "stratum"):
            cand = [p for p in pts.values() if p[0] not in pt_taken and
                    (p[1] == r["matched_cluster_id"] if scope == "cluster" else p[2] == r["matched_strata_id"])]
            if cand:
                p = min(cand, key=lambda p: hav(loc[0], loc[1], p[3], p[4]))
                best = (p, hav(loc[0], loc[1], p[3], p[4]), scope)
                break
        return best

    rows = []

    def out(t, decision, category, recovery_type, mech, fstatus, resolution, corrections=(), reminder="", dist=""):
        rows.append(dict(issue_id=t["issue_id"], issue_type=t["issue_type"], deletion_reason=t["deletion_reason"],
                         org_id=t["org_id"], uuid=t["uuid"], cluster_id=t["cluster_id"], category=category, decision=decision,
                         recovery_type=recovery_type, fallback_mechanism=mech, fallback_status=fstatus, resolution=resolution,
                         distance_m=dist, reminder=reminder,
                         corrections=" | ".join(f"{f}: {o} -> {n}" for f, o, n in corrections), _corr=list(corrections)))

    def keep_suffix(t, r, category, why, decision="KEEP (distinct household, _b suffix)"):
        """Keep the interview, giving it a suffixed identifier (_b, _c, ...) so key-based duplicate checks don't re-flag it.
        Non-IDP: suffix the drawn point nearest to where the device actually was (<=500 m, the project's 'possible
        match' band); more than 500 m from every drawn point in the stratum = not at a sampled location -> flagged for
        Jack (FAR_DECISION below). IDP: suffix the household/walk number (the site itself is the location)."""
        corr, dist, note = [], "", ""
        if r["pop_type"] == "idp" and not miss(r["idp_hh_number_from_listing"]):
            f, o = "idp_hh_number_from_listing", str(r["idp_hh_number_from_listing"]).split(".0")[0]
            corr = [(f, o, next_suffix(f"{r['matched_cluster_id']}|{o}").split("|")[1])]
        elif r["pop_type"] == "idp" and not miss(r["idp_walk_position"]):
            f, o = "idp_walk_position", str(r["idp_walk_position"]).split(".0")[0]
            corr = [(f, o, next_suffix(f"{r['matched_cluster_id']}|walk{o}").split("|")[1].replace("walk", ""))]
        else:
            f = "non_idp_point_id"
            o = r["matched_survey_id"] if not miss(r["matched_survey_id"]) else r["non_idp_point_id"]
            loc, _ = anchor(r)
            nd = nearest_drawn_point(r, loc)
            if nd and nd[1] > FAR_DELETE_M:
                out(t, "DELETE (not at a sampled location)", category, "", "not_at_sampled_location", "rule_resolved",
                    f"Round 1 closeout (Jack, 2 Oct): device GPS is {nd[1]:.0f} m from every drawn point in the stratum - "
                    f"not at a sampled location; deleted.", dist=f"{nd[1]:.0f}")
                return
            base = nd[0][0] if nd else o
            dist = f"{nd[1]:.0f}" if nd else ""
            reminder = ""
            if nd and nd[1] > 500:
                note = (f" Device is {nd[1]:.0f} m from the nearest drawn point - likely inside the cluster area but not at a "
                        f"drawn building (Jack, 2 Oct: keep, flagged for review).")
                reminder = (f"Device GPS is {nd[1]:.0f} m from the nearest drawn point - likely inside the cluster area but not at "
                            f"a drawn building; check before use.")
            elif nd and nd[1] > 150:
                note = f" Device is {nd[1]:.0f} m from that point (150-500 m 'possible match' band)."
            corr = [(f, o, next_suffix(base))]
            if nd and nd[0][1] != r["matched_cluster_id"]:
                corr.append(("cluster_id", r["matched_cluster_id"], nd[0][1]))
        out(t, decision, category, "justified_exception", "keep_distinct_household", "rule_resolved",
            f"Round 1 closeout (Jack, Q3): distinct household (size/head differ) sharing a drawn {f}; {why}; retained, "
            f"identifier suffixed so key-based duplicate checks don't re-flag it.{note}", corr,
            reminder=locals().get("reminder", ""), dist=dist)

    for t in trk:
        if t["status"] in TERMINAL:
            continue
        u, r = t["uuid"], subs.get(t["uuid"])
        reason = t["deletion_reason"] if t["issue_type"] == "confirmed_deletion" else t["issue_type"]

        if reason == "duplicate_point":
            sibs = sorted((x for x in groups.get(claim_key(r), []) if x != u), key=order)
            if not sibs:
                out(t, "CLEAR (not a duplicate any more)", "D", "false_positive", "live_claimant_rule", "rule_resolved",
                    "Round 1 closeout (Jack, Q3-D): every other claimant of this point/number has been deleted, so this is the first live claimant, not a duplicate.")
                continue
            sib = subs[sibs[0]]
            same = same_household(r, sib)
            if same:
                out(t, "DELETE (true duplicate)", "A/B", "", "q3_same_household", "rule_resolved",
                    f"Round 1 closeout (Jack, Q3-A/B): same household as {sibs[0]} (household size and head sex/age match) - "
                    f"later interview deleted, the first kept.")
                continue
            category = "C" if same is False else "C (identity fields missing)"
            if r["pop_type"] == "idp" and not miss(r["idp_hh_number_from_listing"]):
                cl, rec = r["matched_cluster_id"], int(num(r["idp_hh_number_from_listing"]))
                free = sorted(n for n in pools.get(cl, set()) if (cl, n) not in ln_taken)
                if free:
                    n = min(free, key=lambda x: (abs(x - rec), x))
                    ln_taken.add((cl, n))
                    out(t, "REASSIGN listing number", category, "false_positive", "listing_number_nearest", "applied_candidate",
                        f"Round 1 closeout (Jack, Q3-C): different household from {sibs[0]}; reassigned to the nearest free number in the "
                        f"cluster's real HH listing ({rec} -> {n}).", [("idp_hh_number_from_listing", str(rec), str(n))])
                else:
                    keep_suffix(t, r, category, "no free number left in the cluster's real listing" if cl in pools else "cluster has no real HH listing")
            elif r["pop_type"] == "idp":
                keep_suffix(t, r, category, "walk-based site with no listing to reassign within")
            else:
                loc, src = anchor(r)
                best = nearest_free_point(r, loc) if loc else None
                if best and best[1] <= cap:
                    p, d, scope = best
                    pt_taken.add(p[0])
                    out(t, "REASSIGN point", category, "false_positive", "gis_nearest_household", "applied_candidate",
                        f"Round 1 closeout (Jack, Q3-C): different household from {sibs[0]}; reassigned to the nearest free point "
                        f"({d:.0f} m from the {src}{', widened to the stratum' if scope == 'stratum' else ''}).",
                        [("non_idp_point_id", r["matched_survey_id"], p[0])] + ([("cluster_id", r["matched_cluster_id"], p[1])] if p[1] != r["matched_cluster_id"] else []),
                        dist=f"{d:.0f}")
                else:
                    why = (f"nearest free point is {best[1]:.0f} m away (over the {cap:.0f} m limit)" if best else
                           "no free point left in the cluster or stratum" if loc else "no location to search from")
                    keep_suffix(t, r, category, why)

        elif reason == "gps_duplicate":
            loc, src = anchor(r)
            best = nearest_free_point(r, loc) if loc else None
            if best and best[1] <= cap:
                p, d, scope = best
                pt_taken.add(p[0])
                out(t, "REASSIGN point", "GPS", "false_positive", "gis_nearest_household", "applied_candidate",
                    f"Round 1 closeout (Jack, Q3): device far from the claimed point; reassigned to the nearest free point ({d:.0f} m from the {src}).",
                    [("non_idp_point_id", r["non_idp_point_id"], p[0])], dist=f"{d:.0f}")
            else:
                keep_suffix(t, r, "GPS", "device far from the claimed point and no free point within the distance limit; "
                            "recorded at the drawn point nearest to where the device actually was",
                            decision="KEEP at nearest drawn point (_b suffix)")

        elif reason == "listing_missing":
            cl = r["matched_cluster_id"]
            n = num(r["idp_hh_number_from_listing"])
            if cl not in pools:
                out(t, "KEEP", "Q4", "justified_exception", "q4_listing_check", "rule_resolved",
                    "Round 1 closeout (Jack, Q4): cluster still has no real HH listing to check against; retained (same treatment as missing_hh_listing).")
            elif n is None:
                out(t, "KEEP", "Q4", "justified_exception", "q4_listing_check", "rule_resolved",
                    "Round 1 closeout (Jack, Q4): no household number recorded to check against the now-submitted listing; retained.")
            elif int(n) in pools[cl]:
                out(t, "KEEP (verified)", "Q4", "false_positive", "q4_listing_check", "rule_resolved",
                    f"Round 1 closeout (Jack, Q4): household number {int(n)} is in the cluster's now-submitted HH listing - verified.")
            else:
                free = sorted(x for x in pools[cl] if (cl, x) not in ln_taken)
                if free:
                    m = min(free, key=lambda x: (abs(x - n), x))
                    ln_taken.add((cl, m))
                    out(t, "REASSIGN listing number", "Q4", "false_positive", "q4_listing_check", "applied_candidate",
                        f"Round 1 closeout (Jack, Q4): number {int(n)} is not in the cluster's real listing; reassigned to the nearest free number {m}.",
                        [("idp_hh_number_from_listing", str(int(n)), str(m))])
                else:
                    keep_suffix(t, r, "Q4", "number not in the real listing and no free number left")

        elif reason == "date_outlier":
            out(t, "KEEP (exception)", "Q6", "justified_exception", "q6_date_exception", "rule_resolved",
                "Round 1 closeout (Jack, Q6): kept as an exception - the recorded date is wrong (device clock), the interview is real.")

        elif reason == "crs_unmatched":
            loc = gps.get(u)
            if not loc:
                out(t, "DELETE", "Q5", "", "q5_gps_placement", "rule_resolved", "Round 1 closeout (Jack, Q5): no device GPS to place it; deleted.")
                continue
            st = min(sites.values(), key=lambda s: hav(loc[0], loc[1], s[3], s[4]))
            d_st = hav(loc[0], loc[1], st[3], st[4])
            pt = min(pts.values(), key=lambda p: hav(loc[0], loc[1], p[3], p[4]))
            d_pt = hav(loc[0], loc[1], pt[3], pt[4])
            if d_st <= 150 and d_st <= d_pt:
                out(t, "PLACE at IDP site", "Q5", "justified_exception", "q5_gps_placement", "applied_candidate",
                    f"Round 1 closeout (Jack, Q5): placed by device GPS at IDP site {st[0]} ({d_st:.0f} m).",
                    [("pop_type", "", "idp"), ("cluster_id", "", st[0]), ("sample_point_id", "", st[0])], REMINDER, f"{d_st:.0f}")
            elif d_pt <= 150:
                if pt[0] not in pt_taken:
                    pt_taken.add(pt[0])
                    out(t, "PLACE at non-IDP point", "Q5", "justified_exception", "q5_gps_placement", "applied_candidate",
                        f"Round 1 closeout (Jack, Q5): placed by device GPS at free non-IDP point {pt[0]} ({d_pt:.0f} m).",
                        [("pop_type", "", "non_idp"), ("cluster_id", "", pt[1]), ("non_idp_point_id", "", pt[0])], REMINDER, f"{d_pt:.0f}")
                else:
                    out(t, "PLACE at non-IDP point (_b, point already live-claimed)", "Q5", "justified_exception", "q5_gps_placement", "rule_resolved",
                        f"Round 1 closeout (Jack, Q5): placed by device GPS next to non-IDP point {pt[0]} ({d_pt:.0f} m), which a different "
                        f"household's interview already holds; suffixed _b.",
                        [("pop_type", "", "non_idp"), ("cluster_id", "", pt[1]), ("non_idp_point_id", "", next_suffix(pt[0]))], REMINDER, f"{d_pt:.0f}")
            else:
                out(t, "DELETE", "Q5", "", "q5_gps_placement", "rule_resolved",
                    f"Round 1 closeout (Jack, Q5): device GPS is {min(d_st, d_pt):.0f} m from any drawn point or IDP site - cannot be placed; deleted.",
                    dist=f"{min(d_st, d_pt):.0f}")

        elif t["issue_type"] == "missing_hh_listing":
            if t["cluster_id"] in pools:
                out(t, "CLOSE (listing now submitted)", "MHL", "", "listing_received_evidence", "rule_resolved",
                    f"Round 1 closeout: the cluster now has a real HH listing in the export ({len(pools[t['cluster_id']])} drawn numbers).")
            else:
                s = sites.get(t["cluster_id"])
                site_id = s[6] if s else ""
                out(t, "CLOSE (IOM DTM site as listing reference)" if site_id else "CLOSE (no listing, no DTM match; retained)",
                    "MHL", "", "iom_dtm_listing", "applied_candidate" if site_id else "rule_resolved",
                    f"Round 1 closeout (Jack, Q8): no household listing was ever submitted; IOM DTM site {site_id} used as the listing reference. "
                    f"Cluster-level gap only - no interview excluded." if site_id else
                    "Round 1 closeout (Jack, Q8): no household listing and no IOM DTM site match; cluster-level gap only - interviews retained.")
        else:
            out(t, "UNHANDLED", "?", "", "", "", f"no rule for {t['issue_type']}/{t['deletion_reason']}")

    # ---- final-state check: after EVERY correction (earlier rounds + step 2 + this run) and every deletion, does any
    # duplicate key survive among live Round 1 interviews? (Jack's ask: the data must not re-flag on validation.)
    gone = {x["uuid"] for x in rows if x["decision"].startswith(("DELETE", "FLAG"))}
    final = {}
    for u in live - gone:
        r = corrected(u)
        final[u] = r
    for x in rows:
        if x["uuid"] in final:
            for fld, o, n in x["_corr"]:
                col = {"non_idp_point_id": "matched_survey_id", "idp_hh_number_from_listing": "idp_hh_number_from_listing",
                       "idp_walk_position": "idp_walk_position", "cluster_id": "matched_cluster_id", "pop_type": "pop_type"}.get(fld)
                if col:
                    final[x["uuid"]][col] = n
    fk = defaultdict(list)
    for u, r in final.items():
        k = claim_key(r)
        if k:
            fk[str(k).replace(".0", "")].append(u)
    survivors = {k: v for k, v in fk.items() if len(v) > 1}
    print(f"\nFINAL-STATE CHECK (before the uniqueness pass): duplicate keys surviving: {len(survivors)} "
          f"(covering {sum(len(v) for v in survivors.values())} interviews) - all on already-closed items")

    # ---- final uniqueness pass (2 Oct): what survives is interviews whose tracker items are already closed, mostly
    # earlier-round partner corrections that collide with someone else's claim. Same Q3 logic, log-only (their tracker
    # rows stay as they are): keep the first live claimant at the key; a DIFFERENT household gets the next suffix; a
    # SAME household is a hidden true duplicate -> listed for Jack (deleting it would mean reopening a closed row).
    extra_corr, hidden_true_dups = [], []
    for k, v in survivors.items():
        v = sorted(v, key=order)
        first = final[v[0]]
        for u in v[1:]:
            r = final[u]
            if same_household(r, first):
                hidden_true_dups.append((k, u, v[0]))
                continue
            if r["pop_type"] == "idp" and not miss(r["idp_hh_number_from_listing"]):
                fld, base = "idp_hh_number_from_listing", str(r["idp_hh_number_from_listing"]).split(".0")[0]
                new = next_suffix(f"{r['matched_cluster_id']}|{base}").split("|")[1]
            elif r["pop_type"] == "idp" and not miss(r["idp_walk_position"]):
                fld, base = "idp_walk_position", str(r["idp_walk_position"]).split(".0")[0]
                new = next_suffix(f"{r['matched_cluster_id']}|walk{base}").split("|")[1].replace("walk", "")
            else:
                fld, base = "non_idp_point_id", r["matched_survey_id"]
                new = next_suffix(base)
            extra_corr.append(dict(uuid=u, org_id=subs[u]["org_id"], field=fld, old_value=base, new_value=new,
                                   decision="final uniqueness pass: distinct household sharing a key after all corrections - suffixed"))
            final[u][{"idp_hh_number_from_listing": "idp_hh_number_from_listing", "idp_walk_position": "idp_walk_position",
                      "non_idp_point_id": "matched_survey_id"}[fld]] = new
    fk2 = Counter(str(claim_key(r)).replace(".0", "") for r in final.values() if claim_key(r))
    left = {k: n for k, n in fk2.items() if n > 1}
    print(f"  uniqueness pass: {len(extra_corr)} interview(s) suffixed (log-only) | hidden SAME-household duplicates for Jack: {len(hidden_true_dups)}")
    for k, u, f0 in hidden_true_dups:
        print(f"    {k}: {u} looks like the same household as {f0}")
    print(f"FINAL-STATE CHECK (after): duplicate keys surviving: {len(left)} "
          f"({'only the hidden same-household ones above' if len(left) == len(hidden_true_dups) else 'UNEXPECTED - investigate'})")

    OUT.mkdir(parents=True, exist_ok=True)
    prev = OUT / "round1_resolution_preview.csv"
    with open(prev, "w", newline="", encoding="utf-8") as f:
        cols = [k for k in rows[0] if not k.startswith("_")]
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"open items resolved: {len(rows)} | preview: {prev}\n")
    for (reason, dec), n in sorted(Counter((x["deletion_reason"] or x["issue_type"], x["decision"]) for x in rows).items()):
        print(f"  {n:5d}  {reason:20s} {dec}")
    dels = [x for x in rows if x["decision"].startswith("DELETE")]
    print(f"\nDELETIONS: {len(dels)} (these leave Achieved) | everything else stays in Achieved")
    d = [float(x["distance_m"]) for x in rows if x["decision"] == "REASSIGN point" and x["distance_m"]]
    if d:
        d.sort()
        print(f"point reassignment distances: n={len(d)} median {d[len(d)//2]:.0f} m | max {d[-1]:.0f} m (cap {cap:.0f} m)")
    print("UNHANDLED:", sum(x["decision"] == "UNHANDLED" for x in rows))
    with open(OUT / "round1_final_uniqueness_corrections.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["uuid", "org_id", "field", "old_value", "new_value", "decision"])
        w.writeheader()
        w.writerows(extra_corr)
    if not apply:
        print("\nDRY RUN - nothing written to the tracker. Re-run with --apply after Jack's go-ahead.")
        return
    write(rows, earlier, extra_corr)


def write(rows, earlier, extra_corr):
    today = datetime.date.today().isoformat()
    trk = it.read_tracker()
    idx = {r["issue_id"]: i for i, r in enumerate(trk)}
    todo = [(idx[x["issue_id"]], x) for x in rows if x["issue_id"] in idx and trk[idx[x["issue_id"]]]["status"] not in TERMINAL]
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    snap = LOG_DIR / f"{stamp}_round1_resolve_all_BEFORE.csv"
    with open(snap, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=it.COLUMNS)
        w.writeheader()
        w.writerows(trk[i] for i, _ in todo)
    for i, x in todo:
        trk[i].update(status="confirmed", confirmed_by="internal_team", recovery_type=x["recovery_type"],
                      resolution=x["resolution"] + (f" REVIEW: {x['reminder']}" if x["reminder"] else ""),
                      resolution_date=today, fallback_status=x["fallback_status"], fallback_mechanism=x["fallback_mechanism"],
                      fallback_resolution=x["decision"] + (f" | {x['corrections']}" if x["corrections"] else ""),
                      fallback_applied_date=today)
    it.write_tracker(trk)
    with open(OUT / "round1_closeout_corrections.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["uuid", "org_id", "issue_id", "field", "old_value", "new_value", "decision", "reminder"])
        for _, x in todo:
            for fld, o, n in x["_corr"]:
                w.writerow([x["uuid"], x["org_id"], x["issue_id"], fld, o, n, x["decision"], x["reminder"]])
        for (u, fld), (o, n, org, iid) in earlier.items():
            w.writerow([u, org, iid, fld, o, n, "earlier-round partner correction (recorded in the tracker, never applied to the data)", ""])
        for c in extra_corr:
            w.writerow([c["uuid"], c["org_id"], "", c["field"], c["old_value"], c["new_value"], c["decision"], ""])
    with open(LOG_DIR / f"{today}.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} | decided_by={DECIDED_BY} | n={len(todo)} | round1 resolve_all applied | "
                f"snapshot={snap.name}\n")
    print(f"\nAPPLIED {len(todo)} resolution(s). Snapshot: {snap}")


def restore(snapshot_path):
    snap = list(csv.DictReader(open(snapshot_path, encoding="utf-8")))
    trk = it.read_tracker()
    idx = {r["issue_id"]: i for i, r in enumerate(trk)}
    n = 0
    for row in snap:
        if row["issue_id"] in idx:
            trk[idx[row["issue_id"]]] = {c: row.get(c, "") for c in it.COLUMNS}
            n += 1
    it.write_tracker(trk)
    with open(LOG_DIR / f"{datetime.date.today().isoformat()}.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} | RESTORE n={n} from {Path(snapshot_path).name}\n")
    print(f"restored {n} row(s) from {snapshot_path}")


if __name__ == "__main__":
    main()
