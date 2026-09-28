#!/usr/bin/env python3
"""Per-stratum collection facts + a partner-level one-pager, for the representativity review.

ONE COMMAND (from anywhere; stdlib only, no R, no pandas, ~5 s):

    python -B "_working_files/scripts/stratum_collection_facts.py"

READ-ONLY on every input; writes only into _working_files/:
    stratum_collection_facts_<as-of>.csv    one row per stratum (covered + excluded + Marte's not-covered row)
    partner_collection_summary_<as-of>.csv  one row per partner + TOTAL (same numbers as the .md table)
    partner_collection_summary_<as-of>.md   the one-page summary: inputs+hashes, definitions, table, checks
A same-named earlier output is moved to _working_files/_archive_stratum_facts/ (stamped with its own mtime)
before the new one is written, so a before/after-the-export comparison is always possible.

Inputs (all local copies inside this repo, never read live across repos - the only cross-repo touch is a
METADATA-ONLY staleness check, mtime/stamp comparison, same spirit as cleaning/real/sanity_checks.R):
    data/real_submissions.csv                                   (interviews; rebuilt by prep_real_submissions.R)
    input_data/sampling_frame/..._strata_level_..._v<highest>_FULL.csv   (targets, coverage status, frame partner)
    input_data/accessibility/accessibility_strata_level.csv     (REVISED target, "representativity" basis)
    input_data/partner_coverage/partner_lga_assignment.csv      (current LGA owner(s) - what the dashboard credits)
    input_data/partner_coverage/partner_registry.csv            (zero-LGA partners: ACF, IMC)

Definitions replicate dashboard_app/global.R exactly (compute_progress_by_stratum / is_achieved /
is_confirmed_deletion) so these figures tie out to the dashboard on the same submissions file:
    completed_raw     interview_outcome == "completed", matched to the stratum, no quality filter
    confirmed_deleted completed AND deletion_status in (confirmed, contested)
    achieved          completed AND NOT confirmed_deleted AND matched_cluster_id present (uncapped)
    credited          min(achieved, max(target, 0)) per stratum, on each target basis (original / revised)
    pending_deletion  completed AND deletion_status set AND not confirmed/contested (a subset of achieved)
    interview date    submission_date (== the start_datetime date on every row today)
    last 7 / 14 days  as-of date minus 6 / 13 .. as-of date, inclusive (7 / 14 calendar days incl. as-of day)
    enumerators       distinct (org_id, enum_id) among completed interviews in the last 7 days
    duplicate share   completed rows with is_duplicate TRUE / completed_raw (raw key-based flag, NOT deletions)
    GPS-outlier match completed rows with match_quality == "matched_gps_outlier" / completed_raw
Status (dashboard rule, per basis): Dropped = excluded frame status OR revised target missing; Complete =
target<=0 or remaining<=0; In progress = achieved>0; else Not started. Marte's not-covered row = "Not covered".
"""
import argparse
import csv
import datetime as dt
import hashlib
import re
import shutil
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SUBS = REPO / "data" / "real_submissions.csv"
FRAME_DIR = REPO / "input_data" / "sampling_frame"
ACCESS_CSV = REPO / "input_data" / "accessibility" / "accessibility_strata_level.csv"
ACCESS_STAMP = REPO / "input_data" / "accessibility" / "_accessibility_layer_full_version.txt"
ASSIGN_CSV = REPO / "input_data" / "partner_coverage" / "partner_lga_assignment.csv"
REGISTRY_CSV = REPO / "input_data" / "partner_coverage" / "partner_registry.csv"
FRAME_STAMP = FRAME_DIR / "_frame_version.txt"
LIVE_FRAME_STAMP = REPO.parent / "1_sampling" / "output" / "data" / "data_collection" / "_frame_version.txt"
LIVE_WORKBOOK = REPO.parent / "1_sampling" / "resampling" / "output" / "NGA_MSNA_2026_accessibility_impact_workbook.xlsx"
OUT_DIR = REPO / "_working_files"
REVISED_COL = "Target sample (representativity, incl. 5% operational margin)"

# org_id -> the label the sampling frame uses in partners_covering (display only)
LABEL = {
    "acf": "ACF", "care": "CARE", "coopi": "COOPI", "crs": "CRS", "drc": "DRC", "fact": "FACT",
    "fhi360": "FHI 360", "imc": "IMC", "intersos": "INTERSOS", "irc": "IRC", "lhi": "LHI", "jrs": "JRS",
    "malteser": "Malteser", "mdm": "MDM", "nrc": "NRC", "plan": "PLAN", "sci": "Save the Children",
    "si": "Solidarités", "street_child": "Street Child of Nigeria", "zoa": "ZOA",
}
NA = ("", "NA", "NaN", None)


def read_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def mtime(path):
    return dt.datetime.fromtimestamp(Path(path).stat().st_mtime, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def to_float(v):
    if v in NA:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def fnum(x):
    if x is None or x == "":
        return ""
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else f"{x:.2f}"
    return str(x)


def pct(n, d):
    return "" if not d else f"{100.0 * n / d:.1f}"


def read_stamp(path):
    out = {}
    if Path(path).exists():
        for line in open(path, encoding="utf-8", errors="replace"):
            if ": " in line:
                k, v = line.rstrip("\n").split(": ", 1)
                out[k.strip()] = v.strip()
    return out


def latest_frame_file(prefix, suffix):
    pat = re.compile(rf"^{re.escape(prefix)}_v(\d+)_{suffix}\.csv$")
    hits = [(int(m.group(1)), p) for p in FRAME_DIR.iterdir() if (m := pat.match(p.name))]
    if not hits:
        sys.exit(f"no {prefix}_v<N>_{suffix}.csv in {FRAME_DIR}")
    return max(hits)[1]


def parse_date(v):
    if v in NA:
        return None
    try:
        return dt.date.fromisoformat(v[:10])
    except ValueError:
        return None


def stratum_status(cov, target, achieved, revised_missing):
    if cov == "not_covered":
        return "Not covered"
    if cov == "excluded" or revised_missing:
        return "Dropped"
    if target is None or target <= 0 or max(target - achieved, 0) <= 0:
        return "Complete"
    return "In progress" if achieved > 0 else "Not started"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--as-of", help="YYYY-MM-DD; default = today (UTC)")
    ap.add_argument("--tag", help="suffix for the three output names (e.g. t0217), so a same-day rerun does not replace an earlier file")
    args = ap.parse_args()
    as_of = dt.date.fromisoformat(args.as_of) if args.as_of else dt.datetime.now(dt.timezone.utc).date()
    d7, d14 = as_of - dt.timedelta(days=6), as_of - dt.timedelta(days=13)

    frame_full = latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL")
    frame_work = latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "WORKING")
    stage2_work = latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING")
    frame = read_csv(frame_full)
    assert len({r["strata_id"] for r in frame}) == len(frame), "duplicate strata_id in the strata frame"
    frame_by_id = {r["strata_id"]: r for r in frame}
    work_ids = {r["strata_id"] for r in read_csv(frame_work)}
    revised = {r["Strata ID"]: to_float(r[REVISED_COL]) for r in read_csv(ACCESS_CSV)}
    owners = defaultdict(set)
    for r in read_csv(ASSIGN_CSV):
        owners[r["adm2_pcode"]].add(r["org_id"])
    registry = read_csv(REGISTRY_CSV)

    # ---- aggregate the interviews per stratum and per collecting org -----------------------------
    agg = defaultdict(lambda: {"completed": 0, "achieved": 0, "confirmed": 0, "pending": 0, "unresolved_cluster": 0,
                               "first": None, "last": None, "l7": 0, "l14": 0, "enum7": set(), "dup": 0, "gps": 0,
                               "no_date": 0, "orgs": Counter()})
    by_org = defaultdict(lambda: {"completed": 0, "l7": 0, "l14": 0, "enum7": set(), "last": None})
    n_rows = n_completed = n_future = 0
    newest = None
    for r in read_csv(SUBS):
        n_rows += 1
        if r["interview_outcome"] != "completed":
            continue
        n_completed += 1
        s = agg[r["matched_strata_id"]]
        s["completed"] += 1
        conf = r["deletion_status"] in ("confirmed", "contested")
        if conf:
            s["confirmed"] += 1
        elif r["deletion_status"] not in NA:
            s["pending"] += 1
        if not conf:
            if r["matched_cluster_id"] in NA:
                s["unresolved_cluster"] += 1
            else:
                s["achieved"] += 1
        if r["is_duplicate"] == "TRUE":
            s["dup"] += 1
        if r["match_quality"] == "matched_gps_outlier":
            s["gps"] += 1
        org = r["org_id"]
        s["orgs"][org] += 1
        o = by_org[org]
        o["completed"] += 1
        d = parse_date(r["submission_date"])
        if d is None:
            s["no_date"] += 1
            continue
        if d > as_of:
            n_future += 1
        newest = d if newest is None or d > newest else newest
        s["first"] = d if s["first"] is None or d < s["first"] else s["first"]
        s["last"] = d if s["last"] is None or d > s["last"] else s["last"]
        o["last"] = d if o["last"] is None or d > o["last"] else o["last"]
        enum = (org, r["enum_id"])
        if d7 <= d <= as_of:
            s["l7"] += 1
            s["enum7"].add(enum)
            o["l7"] += 1
            o["enum7"].add(enum)
        if d14 <= d <= as_of:
            s["l14"] += 1
            o["l14"] += 1

    # ---- one row per stratum ---------------------------------------------------------------------
    rows = []
    for sid, f in frame_by_id.items():
        cov, reason = f["coverage_status"], f["exclusion_reason"]
        a = agg.get(sid)
        if cov == "not_covered" and not (a or "insecurity" in reason):
            continue  # ~245 declined-coverage strata with no interview: not part of this review
        a = a or agg[sid]
        target = to_float(f["target_sample"])
        rev = revised.get(sid)
        rev_missing = cov == "covered" and rev is None
        own_ids = sorted(owners.get(f["adm2_pcode"], ())) if cov == "covered" else []
        frame_partner = "" if f["partners_covering"] in NA else f["partners_covering"]
        if own_ids:
            partner = " + ".join(LABEL.get(o, o) for o in own_ids)
            frame_set = {x.strip() for x in frame_partner.split(",")}
            check = "ok" if frame_set == {LABEL.get(o, o) for o in own_ids} else f"MISMATCH frame says: {frame_partner or '(none)'}"
        else:
            partner = frame_partner.replace(", ", " + ")
            check = "no active owner (frame status " + cov + ")" if cov != "covered" else "MISSING from partner_lga_assignment"
        ach = a["achieved"]
        cred_o = min(ach, max(target, 0)) if target is not None else None
        cred_r = min(ach, max(rev, 0)) if rev is not None else None
        days_since = (as_of - a["last"]).days if a["last"] else None
        rows.append({
            "strata_id": sid, "state": f["adm1_name"], "adm2_pcode": f["adm2_pcode"], "LGA": f["adm2_name"],
            "pop_type": f["pop_type"],
            "frame_status": cov if reason == "none" else f"{cov}: {reason}",
            "partner": partner, "partner_org_ids": "+".join(own_ids), "owner_check": check,
            "target_original": target, "target_revised": rev,
            "completed_raw": a["completed"], "achieved_uncapped": ach,
            "credited_original": cred_o, "credited_revised": cred_r,
            "remaining_original": None if target is None else max(target - ach, 0),
            "remaining_revised": None if rev is None else max(rev - ach, 0),
            "confirmed_contested_deleted": a["confirmed"], "pending_deletion": a["pending"],
            "first_interview_date": a["first"], "last_interview_date": a["last"], "days_since_last_interview": days_since,
            "completed_last_7d": a["l7"], "completed_last_14d": a["l14"], "distinct_enumerators_last_7d": len(a["enum7"]),
            "duplicate_flagged_n": a["dup"], "share_duplicate_flagged_pct": pct(a["dup"], a["completed"]),
            "gps_outlier_match_n": a["gps"], "share_gps_outlier_match_pct": pct(a["gps"], a["completed"]),
            "collecting_orgs": "; ".join(f"{o}:{n}" for o, n in a["orgs"].most_common()),
            "status_original_basis": stratum_status(cov, target, ach, rev_missing),
            "status_revised_basis": stratum_status(cov, rev, ach, rev_missing),
            "zero_interviews": a["completed"] == 0, "interviews_without_date": a["no_date"],
        })
    rows.sort(key=lambda r: (r["state"], r["LGA"], r["pop_type"]))
    cols = list(rows[0].keys())

    # ---- partner-level table (owner view + the org's own team) -----------------------------------
    org_ids = sorted({o for r in rows for o in r["partner_org_ids"].split("+") if o} | {r["org_id"] for r in registry}
                     | set(by_org))
    ptable = []
    for oid in org_ids:
        mine = [r for r in rows if oid in r["partner_org_ids"].split("+") and r["frame_status"] == "covered"]
        cnt = Counter(r["status_original_basis"] for r in mine)
        zero = sum(1 for r in mine if r["completed_raw"] == 0)
        o = by_org.get(oid, {"completed": 0, "l7": 0, "l14": 0, "enum7": set(), "last": None})
        ptable.append({
            "partner": LABEL.get(oid, oid), "org_id": oid, "strata_owned": len(mine),
            "shared_strata": sum(1 for r in mine if "+" in r["partner_org_ids"]),
            "complete": cnt["Complete"], "in_progress": cnt["In progress"], "not_started": cnt["Not started"],
            "dropped": cnt["Dropped"], "zero_interview_strata": zero, "zero_interview_share_pct": pct(zero, len(mine)),
            "target_original": sum(r["target_original"] or 0 for r in mine),
            "credited_original": sum(r["credited_original"] or 0 for r in mine),
            "remaining_original": sum(r["remaining_original"] or 0 for r in mine),
            "completed_last_7d_in_owned_strata": sum(r["completed_last_7d"] for r in mine),
            "team_completed_total": o["completed"], "team_completed_last_7d": o["l7"], "team_completed_last_14d": o["l14"],
            "team_distinct_enumerators_last_7d": len(o["enum7"]),
            "team_last_interview_date": o["last"],
        })
    ptable = [p for p in ptable if p["strata_owned"] or p["team_completed_total"]]
    cov_rows = [r for r in rows if r["frame_status"] == "covered"]
    ccnt = Counter(r["status_original_basis"] for r in cov_rows)
    czero = sum(1 for r in cov_rows if r["completed_raw"] == 0)
    total = {
        "partner": "TOTAL (distinct strata)", "org_id": "", "strata_owned": len(cov_rows),
        "shared_strata": sum(1 for r in cov_rows if "+" in r["partner_org_ids"]),
        "complete": ccnt["Complete"], "in_progress": ccnt["In progress"], "not_started": ccnt["Not started"],
        "dropped": ccnt["Dropped"], "zero_interview_strata": czero, "zero_interview_share_pct": pct(czero, len(cov_rows)),
        "target_original": sum(r["target_original"] or 0 for r in cov_rows),
        "credited_original": sum(r["credited_original"] or 0 for r in cov_rows),
        "remaining_original": sum(r["remaining_original"] or 0 for r in cov_rows),
        "completed_last_7d_in_owned_strata": sum(r["completed_last_7d"] for r in cov_rows),
        "team_completed_total": sum(p["team_completed_total"] for p in ptable),
        "team_completed_last_7d": sum(p["team_completed_last_7d"] for p in ptable),
        "team_completed_last_14d": sum(p["team_completed_last_14d"] for p in ptable),
        "team_distinct_enumerators_last_7d": sum(p["team_distinct_enumerators_last_7d"] for p in ptable),
        "team_last_interview_date": newest,
    }
    ptable.append(total)

    # ---- checks and staleness warnings -----------------------------------------------------------
    universe = {r["strata_id"] for r in rows}
    outside = Counter({sid: a["completed"] for sid, a in agg.items() if sid not in universe})
    unmatched_na = sum(n for sid, n in outside.items() if sid.startswith("NA_"))
    covered_ids = {r["strata_id"] for r in rows if r["frame_status"] == "covered"}
    unresolved_in = sum(r["completed_raw"] - r["achieved_uncapped"] - r["confirmed_contested_deleted"] for r in rows)
    warn = []
    if work_ids != covered_ids:
        warn.append(f"WORKING strata frame ({len(work_ids)}) != covered strata in FULL ({len(covered_ids)}): "
                    f"{sorted(work_ids ^ covered_ids)[:6]}")
    fst, lst = read_stamp(FRAME_STAMP), read_stamp(LIVE_FRAME_STAMP)
    if fst.get("working_csv_md5") and fst["working_csv_md5"] != md5(stage2_work):
        warn.append("local stage2 WORKING md5 != its own _frame_version.txt stamp (mirror partially synced?)")
    if lst and (lst.get("working_csv_md5"), lst.get("strata_working_csv_md5")) != (fst.get("working_csv_md5"), fst.get("strata_working_csv_md5")):
        warn.append(f"FRAME STALE: 1_sampling's live stamp ({lst.get('stamped_at')}) differs from the local mirror's ({fst.get('stamped_at')}) - "
                    "targets/partners/status here are from the OLDER frame; run sync_sampling_frame_mirrors()")
    ast = read_stamp(ACCESS_STAMP)
    if ast.get("stamped_at") and fst.get("stamped_at") and ast["stamped_at"] < fst["stamped_at"]:
        warn.append(f"target_revised may be STALE: accessibility_strata_level.csv was built {ast['stamped_at']} from workbook "
                    f"{ast.get('workbook_mtime')}, older than the frame mirror ({fst['stamped_at']}); prep_accessibility_layer.R refreshes it")
    if LIVE_WORKBOOK.exists() and ast.get("workbook_mtime"):
        live_wb = dt.datetime.fromtimestamp(LIVE_WORKBOOK.stat().st_mtime, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        if live_wb > ast["workbook_mtime"]:
            warn.append(f"1_sampling's impact workbook is newer ({live_wb} UTC) than the copy target_revised was built from ({ast['workbook_mtime']})")
    mism = [r["strata_id"] for r in rows if r["owner_check"].startswith(("MISMATCH", "MISSING"))]
    if mism:
        warn.append(f"owner_check: {len(mism)} covered strata where partner_lga_assignment and the frame's partners_covering disagree: {mism[:8]}")
    if newest is None or (as_of - newest).days > 1:
        warn.append(f"DATA LOOKS OLD: newest interview date in real_submissions.csv is {newest}, as-of is {as_of}")
    if n_future:
        warn.append(f"{n_future} completed rows are dated AFTER the as-of date (excluded from the 7/14-day windows)")
    no_date = sum(a["no_date"] for a in agg.values())

    # ---- write -----------------------------------------------------------------------------------
    stamp = as_of.isoformat() + (f"_{args.tag}" if args.tag else "")
    f_facts = OUT_DIR / f"stratum_collection_facts_{stamp}.csv"
    f_sumcsv = OUT_DIR / f"partner_collection_summary_{stamp}.csv"
    f_summd = OUT_DIR / f"partner_collection_summary_{stamp}.md"
    arch = OUT_DIR / "_archive_stratum_facts"
    for p in (f_facts, f_sumcsv, f_summd):
        if p.exists():
            arch.mkdir(exist_ok=True)
            tag = dt.datetime.fromtimestamp(p.stat().st_mtime).strftime("%H%M%S")
            shutil.move(str(p), str(arch / f"{p.stem}_{tag}{p.suffix}"))

    def out(v):
        return "" if v is None else fnum(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else str(v)

    with open(f_facts, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for r in rows:
            w.writerow([out(r[c]) for c in cols])
    pcols = list(ptable[0].keys())
    with open(f_sumcsv, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(pcols)
        for p in ptable:
            w.writerow([out(p[c]) for c in pcols])

    inputs = [("real_submissions.csv", SUBS), (frame_full.name, frame_full), (frame_work.name, frame_work),
              (stage2_work.name, stage2_work), ("accessibility_strata_level.csv", ACCESS_CSV),
              ("partner_lga_assignment.csv", ASSIGN_CSV)]
    hdr = ["Partner", "Strata", "Complete", "In prog.", "Not started", "Dropped", "Zero-interview strata", "Target (orig.)",
           "Credited", "Remaining", "Last 7d in owned strata", "Team total", "Team last 7d", "Team last 14d", "Enumerators 7d", "Team last date"]
    keys = ["partner", "strata_owned", "complete", "in_progress", "not_started", "dropped", None, "target_original",
            "credited_original", "remaining_original", "completed_last_7d_in_owned_strata", "team_completed_total",
            "team_completed_last_7d", "team_completed_last_14d", "team_distinct_enumerators_last_7d", "team_last_interview_date"]

    def cell(p, k):
        if k is None:
            return f"{p['zero_interview_strata']} ({p['zero_interview_share_pct']}%)" if p["strata_owned"] else "-"
        return out(p[k])

    md = [f"# Collection facts by partner - as of {as_of} (generated {dt.datetime.now(dt.timezone.utc):%Y-%m-%d %H:%M} UTC)", "",
          f"Newest interview in the data: **{newest}**. {n_completed:,} completed of {n_rows:,} rows. Per-stratum detail: "
          f"`_working_files/{f_facts.name}` ({len(rows)} strata). Regenerate: "
          "`python -B \"_working_files/scripts/stratum_collection_facts.py\"`.", ""]
    if warn:
        md += ["## WARNINGS - read before using the numbers", ""] + [f"- {w}" for w in warn] + [""]
    md += ["## By partner", "",
           "Left block = the partner's OWN strata (current owner per partner_lga_assignment, covered strata only; a jointly-covered stratum counts for each co-owner, "
           "so only the TOTAL row is distinct). Right block = the partner's own enumerators, anywhere. Status/target/credited are on the ORIGINAL target basis "
           "(the dashboard default); credited is capped per stratum.", "",
           "| " + " | ".join(hdr) + " |", "|" + "|".join(["---"] + ["---:"] * (len(hdr) - 1)) + "|"]
    for p in ptable:
        md.append("| " + " | ".join(cell(p, k) for k in keys) + " |")
    other = [r for r in rows if r["frame_status"] != "covered"]
    md += ["", f"Not in the table: {len(other)} strata with no active partner (excluded {sum(1 for r in other if r['frame_status'].startswith('excluded'))}, "
               f"not covered {sum(1 for r in other if r['frame_status'].startswith('not_covered'))}); "
               f"{sum(r['completed_raw'] for r in other)} completed interviews sit in them. "
               "Zero-interview share is over covered strata only.", "",
           "## Checks", "",
           f"- completed interviews: {n_completed:,} = {sum(r['completed_raw'] for r in rows):,} in the {len(rows)} listed strata + "
           f"{sum(outside.values()):,} elsewhere ({unmatched_na} unmatched `NA_` rows, {sum(outside.values()) - unmatched_na} matched to strata outside this list"
           + (f": {dict(outside.most_common(5))}" if sum(outside.values()) - unmatched_na else "") + ")",
           f"- completed but neither achieved nor confirmed-deleted (matched to a stratum, no cluster): {unresolved_in}",
           f"- completed interviews with no date: {no_date}",
           f"- strata: {sum(1 for r in rows if r['frame_status'] == 'covered')} covered, "
           f"{sum(1 for r in rows if r['frame_status'].startswith('excluded'))} excluded, "
           f"{sum(1 for r in rows if r['frame_status'].startswith('not_covered'))} not covered (kept: Marte / any with interviews)", "",
           "## Inputs", "", "| file | modified | md5 |", "|---|---|---|"]
    md += [f"| {n} | {mtime(p)} | {md5(p)[:12]} |" for n, p in inputs]
    md += ["", f"Frame stamp (local mirror): stamped {fst.get('stamped_at')}, stage2 WORKING md5 {fst.get('working_csv_md5', '')[:8]}, "
               f"strata WORKING md5 {fst.get('strata_working_csv_md5', '')[:8]}. Accessibility layer built {ast.get('stamped_at')} "
               f"from workbook {ast.get('workbook_mtime')}.", "",
           "## Definitions", "", "```", *("Definitions replicate" + __doc__.split("Definitions replicate")[1]).splitlines(), "```"]
    f_summd.write_text("\n".join(md) + "\n", encoding="utf-8")

    print(f"as-of {as_of} | newest interview {newest} | {n_completed:,} completed / {n_rows:,} rows")
    print(f"wrote {f_facts.relative_to(REPO)} ({len(rows)} strata)\n      {f_sumcsv.relative_to(REPO)}\n      {f_summd.relative_to(REPO)}")
    for w in warn:
        print("WARNING:", w)


if __name__ == "__main__":
    main()
