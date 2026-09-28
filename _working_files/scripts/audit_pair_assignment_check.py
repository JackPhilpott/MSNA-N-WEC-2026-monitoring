#!/usr/bin/env python3
"""Whose coordinates are the spatial-duplicate audit's single lat/lon?  (stdlib only, read-only)

    python -B "_working_files/scripts/audit_pair_assignment_check.py" [YYYY-MM-DD]     # audit date, default = newest file

Background: cleaning/real/prep_real_submissions.R (section 6) copies the audit's lat/lon onto BOTH members of every
flagged pair (uuid and matched_uuid) and keeps the first occurrence per uuid. This script tests which member the
coordinates really belong to and what that does to the dashboard's "exact-GPS-reuse" groups. Findings and options:
_working_files/gps_audit_pair_assignment_2026-09-27.md
"""
import collections, csv, math, re, sys, zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AUD = REPO / "cleaning" / "MSNA_Data_Cleaning" / "output" / "checking" / "internal_audit"
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
NA = ("", "NA")


def read_small_xlsx(path):
    z = zipfile.ZipFile(path)
    ss = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
            ss.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))
    rows = []
    for r in ET.fromstring(z.read("xl/worksheets/sheet1.xml")).find("m:sheetData", NS).findall("m:row", NS):
        d = {}
        for c in r.findall("m:c", NS):
            col = re.match(r"[A-Z]+", c.get("r")).group(0)
            v = c.find("m:v", NS)
            if c.get("t") == "s" and v is not None:
                d[col] = ss[int(v.text)]
            elif c.get("t") == "inlineStr":
                d[col] = "".join(t.text or "" for t in c.iter("{%s}t" % NS["m"]))
            elif v is not None:
                d[col] = v.text
        rows.append(d)
    head = rows[0]
    return [{head[k]: v for k, v in r.items() if k in head} for r in rows[1:]]


def hav(a, b, c, d):
    p = math.pi / 180
    x = math.sin((c - a) * p / 2) ** 2 + math.cos(a * p) * math.cos(c * p) * math.sin((d - b) * p / 2) ** 2
    return 2 * 6371000 * math.asin(min(1, math.sqrt(x)))


def q(v, f):
    v = sorted(v)
    return f"median {v[len(v) // 2]:.1f} m, p90 {v[int(len(v) * f)]:.1f} m, max {v[-1]:.1f} m" if v else "none"


date = sys.argv[1] if len(sys.argv) > 1 else sorted(AUD.glob("spatial_duplicate_audit_*.xlsx"))[-1].stem[-10:]
rows = [r for r in read_small_xlsx(AUD / f"spatial_duplicate_audit_{date}.xlsx") if r.get("lat") and r.get("uuid") and r.get("matched_uuid")]
pairs = [(r["uuid"], r["matched_uuid"], float(r["lat"]), float(r["lon"]), float(r["distance_m"])) for r in rows]
own = collections.defaultdict(set)
asm = collections.defaultdict(list)
for u, m, la, lo, d in pairs:
    own[u].add((la, lo))
    asm[m].append((la, lo, d))
print(f"audit {date}: {len(pairs)} pair rows; {len(set(own) | set(asm))} distinct uuids")

# TEST A: x appears as `uuid` (own row) and as `matched_uuid` (row of partner y). If lat/lon are the uuid member's own GPS,
# the gap between x's own coordinates and the coordinates assigned to x as matched must equal that pair's distance_m.
n = ok = big = 0
for x, lst in asm.items():
    for la2, lo2, d2 in lst:
        for la1, lo1 in own.get(x, ()):
            n += 1
            ok += abs(hav(la1, lo1, la2, lo2) - d2) <= max(2, 0.05 * d2)
            big += d2 >= 5
print(f"TEST A: {n} combinations over {sum(1 for x in asm if x in own)} uuids seen in both roles; consistent {ok} ({100 * ok / max(n, 1):.0f}%); pair distance >= 5 m in {big} ({100 * big / max(n, 1):.0f}%)")

# Which rows carry ASSIGNED (counterpart) coordinates: uuids that only ever appear as matched_uuid; prep keeps the first row per uuid
first = {}
for r in rows:
    m = r["matched_uuid"]
    if m not in own and m not in first:
        first[m] = float(r["distance_m"])
allu = set(own) | set(asm)
print(f"uuids with coordinates: {len(allu)}; own-coordinate (appear as `uuid`): {len(own)}; assigned only: {len(first)} ({100 * len(first) / len(allu):.0f}%)")
print(f"pair separation, all {len(pairs)} pairs: {q([p[4] for p in pairs], .9)}")
print(f"pair separation, the {len(first)} assigned-only uuids (= how far their assigned coordinates are from the partner's own): {q(list(first.values()), .9)}")

# The dashboard's find_gps_duplicate_groups(): identical (lat, lon) among completed rows -> how many groups are pair-assignment?
csv_path = REPO / "data" / "real_submissions.csv"
if csv_path.exists():
    subs = list(csv.DictReader(open(csv_path, encoding="utf-8-sig", newline="")))
    comp = [r for r in subs if r["interview_outcome"] == "completed" and r["latitude_submitted"] not in NA]
    g = collections.defaultdict(list)
    for r in comp:
        g[(r["latitude_submitted"], r["longitude_submitted"])].append(r["submission_uuid"])
    groups = {k: v for k, v in g.items() if len(v) > 1}
    by_c = collections.defaultdict(list)
    for u, m, la, lo, d in pairs:
        by_c[(round(la, 7), round(lo, 7))].append((u, m))
    explained = two_own = 0
    for k, mem in groups.items():
        rc = by_c.get((round(float(k[0]), 7), round(float(k[1]), 7)), [])
        linked = {x for p in rc for x in p}
        explained += set(mem) <= linked
        two_own += len({u for u, m in rc} & set(mem)) >= 2
    rows_in = sum(len(v) for v in groups.values())
    assigned = sum(1 for v in groups.values() for u in v if u not in own)
    print(f"exact-GPS-reuse groups in data/real_submissions.csv: {len(groups)} covering {rows_in} rows")
    print(f"  explained entirely by pair assignment: {explained} ({100 * explained / max(len(groups), 1):.0f}%); groups with >= 2 own-coordinate members: {two_own}")
    print(f"  rows in groups that are assigned-only (not their own coordinates): {assigned} ({100 * assigned / max(rows_in, 1):.0f}%)")
