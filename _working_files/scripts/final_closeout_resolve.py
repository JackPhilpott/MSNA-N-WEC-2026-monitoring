#!/usr/bin/env python3
"""Final closeout (16 Oct 2026, data collection closed 15 Oct) - settle every tracker row still OPEN on the final
dataset, under Jack's 2 Oct Round 1 closeout rules (decision #67: "apply them mechanically ... give him a short
exception list of any cases the rules can't settle. No silent calls"). Runs AFTER the final refresh (1a).

Dry run by default: writes final_resolution_preview.csv (+ prints counts), changes nothing.
--apply: snapshot of every touched row -> statuses written -> decisions-log line. --restore <snapshot>: one-call undo.
After --apply, re-run the refresh (1a) so the overlays/deletion columns follow, then final_build_deletion_log.py.

duplicate_point - judged exactly as round1_resolve_all.py does (its own claim_key()/same_household()), against the
earliest LIVE other claimant of the same claim key:
  A/B same household (hh size + head sex + head age +-2), the flagged one the LATER  -> deletion confirmed
  D   no other live claimant                                                         -> cleared (false_positive)
  C   a DIFFERENT household sharing the identifier -> only with --c-mode keep (Jack's call, 16 Oct): kept, identifier
      left unchanged (justified_exception). Without it, C rows are listed for Jack and left open.
  X   anything the rules can't settle (flag on the EARLIER interview, identity fields missing, no claim key,
      interview not live/not in the data) -> listed for Jack, left open. Never decided here.
missing_hh_listing (rule Q8) - cluster now has a real household listing -> closed on that evidence; else IOM DTM site
  -> closed with the site as the listing reference; else closed as a cluster-level gap (interviews retained).
Anything else still open -> listed, left open.

    python -B _working_files/scripts/final_closeout_resolve.py [--c-mode keep] [--apply] [--out <dir>]
    python -B _working_files/scripts/final_closeout_resolve.py --restore <snapshot.csv>
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
from round1_resolve_all import claim_key, same_household, miss, head as head_of  # noqa: E402

LOG_DIR = REPO / "reports/partner_data_recovery/outputs/_review_decisions_log"
FRAME_DIR = REPO / "input_data/sampling_frame"
DECIDED_BY = ("Jack (final closeout 16 Oct 2026: #67 Round 1 rules Q3-A/B/D and Q8 on the final dataset; #70 rule-C "
              "flags all kept with identifiers unchanged)")
TERMINAL = it.TERMINAL_STATUSES


def latest_frame():
    vs = sorted(FRAME_DIR.glob("NGA_MSNA_2026_stage2_sampling_frame_v*_FULL.csv"),
                key=lambda p: int(re.search(r"_v(\d+)_FULL", p.name).group(1)))
    return vs[-1]


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    if "--restore" in sys.argv:
        return restore(sys.argv[sys.argv.index("--restore") + 1])
    apply = "--apply" in sys.argv
    c_keep = "--c-mode" in sys.argv and sys.argv[sys.argv.index("--c-mode") + 1] == "keep"
    out_dir = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else \
        REPO / "reports/partner_data_recovery/outputs/_final_closeout"
    out_dir.mkdir(parents=True, exist_ok=True)

    trk = it.read_tracker()
    subs = {r["submission_uuid"]: r for r in csv.DictReader(open(REPO / "data/real_submissions.csv", encoding="utf-8-sig"))}
    settled = {t["uuid"] for t in trk if t["issue_type"] == "confirmed_deletion" and t["status"] in TERMINAL and miss(t["recovery_type"])}
    live = {u for u, r in subs.items() if r["interview_outcome"] == "completed" and u not in settled}
    groups = defaultdict(list)
    for u in live:
        k = claim_key(subs[u])
        if k:
            groups[k].append(u)
    order = lambda u: (subs[u]["uploaded_at"] or "~", subs[u]["start_datetime"] or "")
    pools = build_listing_pools()
    sites = {}
    for r in csv.DictReader(open(latest_frame(), encoding="utf-8-sig")):
        if r["pop_type"] == "idp" and not miss(r.get("iom_site_id")):
            sites.setdefault(r["cluster_id"], r["iom_site_id"])

    rows = []
    c_detail = []  # rule-C cases, for Jack's own review (#70, 16 Oct: he decides keep vs re-assign himself)

    def out(t, cat, decision, recovery_type, mech, fstatus, resolution, settle=True):
        rows.append(dict(issue_id=t["issue_id"], issue_type=t["issue_type"], deletion_reason=t["deletion_reason"], org_id=t["org_id"],
                         uuid=t["uuid"], cluster_id=t["cluster_id"], category=cat, decision=decision, settle="yes" if settle else "no",
                         recovery_type=recovery_type, fallback_mechanism=mech, fallback_status=fstatus, resolution=resolution))

    def c_note(t, r, first, n_claimants):
        f = subs[first]
        differ = [k for k, a, b in (("size", r["hh_size"], f["hh_size"]),) if str(a).split(".0")[0] != str(b).split(".0")[0]]
        (ga, aa), (gb, ab) = head_of(r), head_of(f)
        if ga != gb:
            differ.append("head sex")
        if aa is not None and ab is not None and abs(aa - ab) > 2:
            differ.append("head age")
        c_detail.append(dict(issue_id=t["issue_id"], org_id=t["org_id"], uuid=t["uuid"], first_claimant=first, claim_key=claim_key(r),
                             pop_type=r["pop_type"], cluster_id=r["matched_cluster_id"],
                             # what distinguishes it within the cluster: "listing_127" / "walk_4" (IDP), "point HH09" (non-IDP)
                             identifier=(claim_key(r).split("|")[-1] if "|" in claim_key(r) else
                                         "point " + claim_key(r)[len(r["matched_cluster_id"]):].lstrip("_")),
                             claimants=n_claimants, differs_by="+".join(differ),
                             same_enumerator="yes" if r.get("enum_id") == f.get("enum_id") else "no",
                             same_day="yes" if r.get("submission_date") == f.get("submission_date") else "no",
                             submission_date=r.get("submission_date", "")))

    for t in trk:
        if t["status"] in TERMINAL:
            continue
        u, r = t["uuid"], subs.get(t["uuid"])
        if t["issue_type"] == "confirmed_deletion" and t["deletion_reason"] == "duplicate_point":
            if r is None or u not in live or not claim_key(r):
                why = ("the flagged interview is not in the final data" if r is None else
                       f"the flagged interview is not live ({r['interview_outcome']})" if u not in live else
                       "no claim key (no point id / listing / walk number)")
                out(t, "X", "LIST FOR JACK", "", "", "", why, settle=False)
                continue
            sibs = sorted((x for x in groups.get(claim_key(r), []) if x != u), key=order)
            if not sibs:
                out(t, "D", "CLEAR (not a duplicate)", "false_positive", "live_claimant_rule", "rule_resolved",
                    "Final closeout (Jack, Q3-D): every other claimant of this point/number has been deleted, so this is the "
                    "first live claimant, not a duplicate.")
                continue
            first = sibs[0]
            same = same_household(r, subs[first])
            if same is None:
                out(t, "X", "LIST FOR JACK", "", "", "", f"household size / head sex / head age missing - can't compare with {first}",
                    settle=False)
            elif same and order(u) <= order(first):
                out(t, "X", "LIST FOR JACK", "", "", "", f"same household as {first}, but the FLAGGED interview is the earlier one",
                    settle=False)
            elif same:
                out(t, "A/B", "DELETE (true duplicate)", "", "q3_same_household", "rule_resolved",
                    f"Final closeout (Jack, Q3-A/B): same household as {first} (household size and head sex/age match) - "
                    f"later interview deleted, the first kept.")
            elif c_keep:
                c_note(t, r, first, len(sibs) + 1)
                fld = ("listing number" if not miss(r["idp_hh_number_from_listing"]) else "walk position") if r["pop_type"] == "idp" \
                    else "sample point"
                out(t, "C", "KEEP (distinct household, identifier unchanged)", "justified_exception",
                    "keep_distinct_household_unchanged", "rule_resolved",
                    f"Final closeout (Jack, Q3-C, 16 Oct): a different household from {first} (household size or head sex/age "
                    f"differ) recorded at the same {fld}; not a duplicate - retained, identifier left unchanged (data "
                    f"collection closed).")
            else:
                c_note(t, r, first, len(sibs) + 1)
                out(t, "C", "LIST FOR JACK (C - awaiting his call)", "", "", "",
                    f"different household from {first} sharing the identifier - Jack to choose keep-unchanged or reassign",
                    settle=False)
        elif t["issue_type"] == "missing_hh_listing":
            if t["cluster_id"] in pools:
                out(t, "Q8", "CLOSE (listing now submitted)", "", "listing_received_evidence", "rule_resolved",
                    f"Final closeout (Jack, Q8): the cluster now has a real HH listing in the export ({len(pools[t['cluster_id']])} "
                    f"drawn numbers).")
            elif t["cluster_id"] in sites:
                out(t, "Q8", "CLOSE (IOM DTM site as listing reference)", "", "iom_dtm_listing", "applied_candidate",
                    f"Final closeout (Jack, Q8): no household listing was ever submitted; IOM DTM site {sites[t['cluster_id']]} used "
                    f"as the listing reference. Cluster-level gap only - no interview excluded.")
            else:
                out(t, "Q8", "CLOSE (no listing, no DTM match; retained)", "", "iom_dtm_listing", "rule_resolved",
                    "Final closeout (Jack, Q8): no household listing and no IOM DTM site match; cluster-level gap only - "
                    "interviews retained.")
        else:
            out(t, "X", "LIST FOR JACK", "", "", "", f"no closeout rule for {t['issue_type']}/{t['deletion_reason'] or '-'}",
                settle=False)

    prev = out_dir / "final_resolution_preview.csv"
    with open(prev, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]) if rows else ["issue_id"])
        w.writeheader()
        w.writerows(rows)
    print(f"open tracker rows: {len(rows)}  (C-mode: {'keep unchanged' if c_keep else 'list for Jack'})")
    for (cat, dec), n in sorted(Counter((x["category"], x["decision"]) for x in rows).items()):
        print(f"  {n:5d}  {cat:4s} {dec}  by org: {dict(Counter(x['org_id'] or '-' for x in rows if x['category'] == cat and x['decision'] == dec).most_common())}")
    left = [x for x in rows if x["settle"] == "no"]
    print(f"left OPEN for Jack: {len(left)} - see {prev}")
    if c_detail:
        # Jack's own review (#70): one line per shared identifier - group fields only, never uuids (they're in the file)
        cpath = out_dir / "final_rule_c_review.csv"
        with open(cpath, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(c_detail[0]))
            w.writeheader()
            w.writerows(sorted(c_detail, key=lambda x: (x["org_id"], x["claim_key"], x["submission_date"])))
        grp = defaultdict(list)
        for x in c_detail:
            grp[(x["org_id"], x["claim_key"])].append(x)
        print(f"\nRULE C - {len(c_detail)} flag(s) on {len(grp)} shared identifier(s), largest first (detail: {cpath.name}):")
        print(f"  {'partner':13s} {'pop':7s} {'cluster':24s} {'identifier':18s} {'flags':>5s} {'claimants':>9s}  differs by / same enum / same day")
        for (o, k), xs in sorted(grp.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            d = Counter(x["differs_by"] for x in xs).most_common(1)[0][0]
            print(f"  {o:13s} {xs[0]['pop_type']:7s} {xs[0]['cluster_id'][:24]:24s} {xs[0]['identifier'][:18]:18s} {len(xs):5d} "
                  f"{xs[0]['claimants']:9d}  {d} / {sum(x['same_enumerator'] == 'yes' for x in xs)} / {sum(x['same_day'] == 'yes' for x in xs)}")
    if not apply:
        print("\nDRY RUN - nothing written to the tracker. Re-run with --apply after Jack's go-ahead.")
        return
    write([x for x in rows if x["settle"] == "yes"])


def write(rows):
    today = datetime.date.today().isoformat()
    trk = it.read_tracker()
    idx = {r["issue_id"]: i for i, r in enumerate(trk)}
    todo = [(idx[x["issue_id"]], x) for x in rows if x["issue_id"] in idx and trk[idx[x["issue_id"]]]["status"] not in TERMINAL]
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    snap = LOG_DIR / f"{stamp}_final_closeout_resolve_BEFORE.csv"
    with open(snap, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=it.COLUMNS)
        w.writeheader()
        w.writerows(trk[i] for i, _ in todo)
    for i, x in todo:
        trk[i].update(status="confirmed", confirmed_by="internal_team", recovery_type=x["recovery_type"], resolution=x["resolution"],
                      resolution_date=today, fallback_status=x["fallback_status"], fallback_mechanism=x["fallback_mechanism"],
                      fallback_resolution=x["decision"], fallback_applied_date=today)
    it.write_tracker(trk)
    with open(LOG_DIR / f"{today}.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} | decided_by={DECIDED_BY} | n={len(todo)} | final closeout applied "
                f"({dict(Counter(x['category'] for _, x in todo))}) | snapshot={snap.name}\n")
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
