#!/usr/bin/env python3
"""What changed between two stratum_collection_facts CSVs (stdlib only, read-only; prints and writes one .md).

    python -B "_working_files/scripts/stratum_facts_delta.py" OLD.csv NEW.csv

OLD/NEW are file names inside _working_files/ (or paths). The .md is written next to them as
stratum_facts_delta_<old stem>__to__<new stem>.md. 7/14-day columns are only like-for-like when both files
share the same as-of date (the dates are in the file names); the report says so when they do not.
"""
import csv
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

WORK = Path(__file__).resolve().parents[1]


def load(arg):
    p = Path(arg)
    p = p if p.exists() else WORK / arg
    return p, {r["strata_id"]: r for r in csv.DictReader(open(p, encoding="utf-8-sig", newline=""))}


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def asof(p):
    m = re.search(r"(\d{4}-\d{2}-\d{2})", p.name)
    return m.group(1) if m else "?"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    po, old = load(sys.argv[1])
    pn, new = load(sys.argv[2])
    ids = sorted(set(old) | set(new))
    cov = [s for s in ids if (new.get(s) or old.get(s))["frame_status"] == "covered"]
    cols = [("completed_raw", "Completed (raw)"), ("achieved_uncapped", "Achieved (uncapped)"),
            ("credited_original", "Credited (original)"), ("remaining_original", "Remaining (original)"),
            ("confirmed_contested_deleted", "Confirmed/contested deleted"), ("pending_deletion", "Pending deletion"),
            ("completed_last_7d", "Completed last 7 d"), ("completed_last_14d", "Completed last 14 d")]
    tot = lambda d, c, ids_: sum(num(d[s][c]) for s in ids_ if s in d)
    lines = [f"# Facts delta: {po.name}  ->  {pn.name}", ""]
    if asof(po) != asof(pn):
        lines += [f"NOTE: as-of dates differ ({asof(po)} vs {asof(pn)}), so the last-7/14-day columns are NOT like-for-like.", ""]
    lines += ["## National (all listed strata; covered strata in the last column)", "",
              "| measure | old | new | change | covered strata: change |", "|---|---:|---:|---:|---:|"]
    for c, label in cols:
        o, n = tot(old, c, ids), tot(new, c, ids)
        oc, nc = tot(old, c, cov), tot(new, c, cov)
        lines.append(f"| {label} | {o:,.0f} | {n:,.0f} | {n - o:+,.0f} | {nc - oc:+,.0f} |")
    zo = sum(1 for s in cov if s in old and old[s]["zero_interviews"] == "True")
    zn = sum(1 for s in cov if s in new and new[s]["zero_interviews"] == "True")
    lines += ["", f"Covered strata with zero interviews: {zo} -> {zn} ({zn - zo:+d}). Strata count: {len(old)} -> {len(new)}.", ""]

    so, sn = Counter(old[s]["status_original_basis"] for s in cov if s in old), Counter(new[s]["status_original_basis"] for s in cov if s in new)
    lines += ["## Covered strata by status (original basis)", "", "| status | old | new | change |", "|---|---:|---:|---:|"]
    for k in sorted(set(so) | set(sn)):
        lines.append(f"| {k} | {so[k]} | {sn[k]} | {sn[k] - so[k]:+d} |")
    moved = [(s, old[s]["status_original_basis"], new[s]["status_original_basis"]) for s in cov if s in old and s in new
             and old[s]["status_original_basis"] != new[s]["status_original_basis"]]
    lines += ["", f"Strata whose status changed: {len(moved)}"]
    for s, a, b in moved[:40]:
        r = new[s]
        lines.append(f"- {s} ({r['LGA']}, {r['state']}; {r['partner']}): {a} -> {b}")

    def rows_where(pred, key, n=10):
        out = [(key(s), s) for s in cov if s in old and s in new and pred(s)]
        return sorted(out, reverse=True)[:n]

    lines += ["", "## Largest increases in completed interviews (top 12)", "", "| stratum | LGA | partner | old | new | change |", "|---|---|---|---:|---:|---:|"]
    for d, s in rows_where(lambda s: True, lambda s: num(new[s]["completed_raw"]) - num(old[s]["completed_raw"]), 12):
        r = new[s]
        lines.append(f"| {s} | {r['LGA']} | {r['partner']} | {num(old[s]['completed_raw']):.0f} | {num(r['completed_raw']):.0f} | {d:+.0f} |")
    started = [s for s in cov if s in old and s in new and old[s]["zero_interviews"] == "True" and new[s]["zero_interviews"] != "True"]
    still = [s for s in cov if s in new and new[s]["zero_interviews"] == "True"]
    lines += ["", f"Strata that had zero interviews and now have some: {len(started)}"]
    lines += [f"- {s} ({new[s]['LGA']}; {new[s]['partner']}): {new[s]['completed_raw']} completed" for s in started]
    lines += ["", f"Still zero: {len(still)}"]
    lines += [f"- {s} ({new[s]['LGA']}, {new[s]['state']}; {new[s]['partner']})" for s in still]
    newly_active = [s for s in cov if s in old and s in new and num(old[s]["completed_last_7d"]) == 0 and num(new[s]["completed_last_7d"]) > 0]
    gone_quiet = [s for s in cov if s in old and s in new and num(old[s]["completed_last_7d"]) > 0 and num(new[s]["completed_last_7d"]) == 0]
    lines += ["", f"Active in the last 7 days now but not before: {len(newly_active)} | active before, none now: {len(gone_quiet)}"]

    by = defaultdict(lambda: [0.0] * 4)
    for s in cov:
        if s in old and s in new:
            k = new[s]["partner"]
            for i, c in enumerate(("completed_raw", "achieved_uncapped", "credited_original", "completed_last_7d")):
                by[k][i] += num(new[s][c]) - num(old[s][c])
    lines += ["", "## By owner (covered strata; change new - old)", "", "| partner | completed | achieved | credited (orig.) | last 7 d |", "|---|---:|---:|---:|---:|"]
    for k, v in sorted(by.items(), key=lambda kv: -kv[1][0]):
        lines.append(f"| {k} | {v[0]:+.0f} | {v[1]:+.0f} | {v[2]:+.0f} | {v[3]:+.0f} |")
    out = pn.parent / f"stratum_facts_delta_{po.stem.replace('stratum_collection_facts_', '')}__to__{pn.stem.replace('stratum_collection_facts_', '')}.md"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines[:60]))
    print(f"\n(wrote {out.name}; full text there)")


if __name__ == "__main__":
    main()
