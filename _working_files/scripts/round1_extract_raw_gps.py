#!/usr/bin/env python3
"""Round 1 closeout - extract ONLY identifier + device geopoint + sampling fields from the DO's raw (non-anonymised)
export, cleaning/MSNA_Data_Cleaning/raw_data/raw_data.xlsx (29 Sep, read-only resource - never written).

Household GPS is sensitive: the extract goes to reports/partner_data_recovery/outputs/_round1_closeout/_private/,
which is gitignored and never bundled into the deployed app - NOT data/, which bundle_dashboard_mirrors() copies into
the app wholesale (the extract sat in data/ until 2 Oct and went out in one deploy that way, bundle 12636193; moved and
redeployed the same night). Nothing here prints a coordinate. Used for: placing the 20 crs_unmatched interviews (Q5),
anchoring the Non-IDP duplicate reassignment on where the interview actually happened, and comparing duplicate
siblings' locations.

    python -B _working_files/scripts/round1_extract_raw_gps.py
"""
import csv
from pathlib import Path

import openpyxl

REPO = Path(__file__).resolve().parents[2]
RAW = REPO / "cleaning/MSNA_Data_Cleaning/raw_data/raw_data.xlsx"
OUT = REPO / "reports/partner_data_recovery/outputs/_round1_closeout/_private/_round1_raw_gps.csv"
WANT = ["_uuid", "uuid", "_geopoint_latitude", "_geopoint_longitude", "_geopoint_precision", "admin1", "admin2",
        "admin3", "sample_point_id", "cluster_id", "idp_cluster_id", "idp_hh_number_from_listing", "idp_walk_position",
        "pt_sample_lat", "pt_sample_lon", "gps_dist_min", "gps_accuracy"]


def main():
    wb = openpyxl.load_workbook(RAW, read_only=True, data_only=True)
    ws = wb.worksheets[0]
    rows = ws.iter_rows(values_only=True)
    hdr = [str(h) if h is not None else "" for h in next(rows)]
    keep = [c for c in WANT if c in hdr]
    keep += [h for h in hdr if h.startswith("sample_point_NG") or h.startswith("idp_cluster_NG")]
    ix = [hdr.index(c) for c in keep]
    n = 0
    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(keep)
        for r in rows:
            r = list(r) + [None] * (len(hdr) - len(r))
            w.writerow(["" if r[i] is None else r[i] for i in ix])
            n += 1
    print(f"extracted {n} rows x {len(keep)} columns -> {OUT} (gitignored)")
    print("columns:", keep)


if __name__ == "__main__":
    main()
