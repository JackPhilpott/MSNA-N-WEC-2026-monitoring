#!/usr/bin/env python3
"""Margin-of-error toggle (Full design vs Simplified; STAGED, flag OFF) - the accessible-population share each LGA x population type had
DURING Round 1 collection, for strata that lost accessibility after their interviews were collected.

Jack, 2 Oct 2026 (relayed by Coordinator): "include these, we always want to include any data collected wherever
possible" - a stratum with Round 1 interviews whose accessible share has since fallen to 0 (FACT's 28 Sep closure), or
that was excluded for accessibility loss, is assessed against the population accessible while it was being collected
instead of being Dropped. Share = the LARGER of the population-weighted accessible shares in the 8 Sep and 26 Sep
archived ward-portion layers (a larger denominator never overstates representativity); a stratum never recorded
accessible in either is assessed against all its households. Same computation as Coordinator's prototype
(1_sampling/resampling/scripts/one_off_analyses/build_round1_representativity_prototype_2026-10-02.py, layer_shares()).

Reads the two archived layers from 1_sampling once (read-only) and writes a static copy the dashboard reads, per the
workspace's data-handoff convention: input_data/round1/collection_period_access.csv.

    python -B _working_files/scripts/build_round1_collection_period_access.py
"""
import csv
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SAMPLING = REPO.parent / "1_sampling"
LAYERS = {
    "pct_accessible_0908": SAMPLING / "_archive/2026-09-08_pre_fact_return_ingest/accessible_area_lga_ward_portions.csv",
    "pct_accessible_0926": SAMPLING / "resampling/output/_archive_gis_pre_final_2026-09-26/accessible_area_lga_ward_portions.csv",
}
OUT = REPO / "input_data/round1/collection_period_access.csv"


def layer_shares(path):
    agg = defaultdict(lambda: [0.0, 0.0])
    for r in csv.DictReader(open(path, encoding="utf-8-sig")):
        k = (r["adm2_pcode"], "idp" if r["pop_type"] == "IDP" else "non_idp")
        p = float(r["pop_total"] or 0)
        agg[k][0] += p
        if r["accessible_status"] == "Accessible":
            agg[k][1] += p
    return {k: (100 * v[1] / v[0] if v[0] else 0.0) for k, v in agg.items()}


def main():
    shares = {col: layer_shares(path) for col, path in LAYERS.items()}
    keys = sorted(set().union(*shares.values()))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["adm2_pcode", "pop_type", *LAYERS, "pct_accessible_collection_period"])
        for k in keys:
            vals = [shares[col].get(k, 0.0) for col in LAYERS]
            w.writerow([*k, *(round(v, 6) for v in vals), round(max(vals), 6)])
    print(f"wrote {OUT.relative_to(REPO)}: {len(keys)} LGA x population type rows")


if __name__ == "__main__":
    main()
