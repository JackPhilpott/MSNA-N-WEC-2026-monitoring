#!/usr/bin/env python3
"""Reproduces the "294 of 307 strata" discrepancy flagged 2026-09-27: the strata-level WORKING
frame's own achieved_sample column vs the field-based achieved count from data/real_submissions.csv.

Per Resampling (2026-09-28): WORKING's achieved_sample is documented (frame_status.R's
compute_strata_achieved(), filter_ward_accessible=TRUE branch) to include the real-achieved-plus-
stranded-credit addback, so it SHOULD track field data closely - unlike FULL's achieved_sample
(every primary row ever drawn, a design-capacity count, confirmed unrelated to field truth via the
Shagari case the same night: FULL showed 175/138, real field count was 31/0). This script's own
comparison is against WORKING, not FULL, so the mismatch it reproduces is the genuinely open one,
still unexplained as of 2026-09-28 - queued for Resampling/Coordinator to pick up.

Definitions match dashboard_app/global.R's own is_achieved(): completed AND not settled-deleted
(deletion_status not in confirmed/contested), matched to a real cluster (matched_cluster_id not NA).

    python -B "_working_files/scripts/compare_achieved_sample_vs_field.py"
"""
import csv
import re
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FRAME_DIR = REPO / "input_data" / "sampling_frame"
SUBS = REPO / "data" / "real_submissions.csv"
NA = ("", "NA")


def latest_frame_file(prefix, suffix):
    pat = re.compile(rf"^{re.escape(prefix)}_v(\d+)_{suffix}\.csv$")
    hits = [(int(m.group(1)), p) for p in FRAME_DIR.iterdir() if (m := pat.match(p.name))]
    return max(hits)[1]


def main():
    working = latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "WORKING")
    frame = {r["strata_id"]: r for r in csv.DictReader(open(working, encoding="utf-8", newline=""))}
    achieved = Counter()
    for r in csv.DictReader(open(SUBS, encoding="utf-8-sig", newline="")):
        if r["interview_outcome"] == "completed" and r["deletion_status"] not in ("confirmed", "contested") \
                and r["matched_cluster_id"] not in NA:
            achieved[r["matched_strata_id"]] += 1

    diffs = []
    for sid, row in frame.items():
        frame_val = row.get("achieved_sample")
        try:
            frame_n = int(float(frame_val))
        except (TypeError, ValueError):
            continue
        field_n = achieved.get(sid, 0)
        if frame_n != field_n:
            diffs.append((sid, row.get("adm2_name"), row.get("pop_type"), frame_n, field_n, frame_n - field_n))

    print(f"{working.name}: {len(frame)} strata; achieved_sample != field-based achieved on {len(diffs)} of {len(frame)}")
    over = sum(1 for *_, d in diffs if d > 0)
    under = sum(1 for *_, d in diffs if d < 0)
    print(f"  frame_achieved > field: {over} | frame_achieved < field: {under}")
    diffs.sort(key=lambda x: -abs(x[-1]))
    print("  largest gaps (strata_id, LGA, pop_type, frame achieved_sample, field achieved, gap):")
    for row in diffs[:15]:
        print("   ", row)


if __name__ == "__main__":
    main()
