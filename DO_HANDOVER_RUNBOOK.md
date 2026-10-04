# MSNA N-WEC 2026: data officer's runbook (week of 5 October 2026)

**For:** the data officer running the MSNA N-WEC 2026 data pipeline while the MSNA lead (Jack Philpott) is away, 5–11 October 2026.
**What you'll do this week:**
1. Refresh the data and redeploy the monitoring dashboard, with one command.
2. Keep the sampling frame and partner folders (workbooks and maps) in step with the new data. This runs automatically, straight after step 1.
3. Submit the Round 1 analysis and cleaned data to HQ. The weights and representativity come from the Round 1 weighting package (section 6).

**What you won't do this week:** resampling (new draws or top-ups), accessibility changes, partner reallocations, the recovery-workbook pipeline. Log any request of this kind in the parking lot (section 8) for Jack's return.

> **[PENDING]** Sections marked [PENDING] are being completed on 4 October by the sessions building the launcher and the frame/partner update; they will be filled in before hand-over.

---

## 1. One-time setup on your laptop

1. **Shared folder.** Make sure OneDrive syncs the whole `IMPACT NGA - 02. MSNA` library, and that `4. Data/MSNA N-WEC 2026/` and `3. External coordination/NGA MSNA 2026 Package/` are set to *Always keep on this device*.
2. **R 4.6 and packages.** Run `2_monitoring/setup_this_computer.bat` once. It installs the dashboard's R packages into a library on your own computer, never in the shared folder. [PENDING: exact steps, confirmed once the clean-install test passes]
   - **One package, `cleaningtools`, downloads from GitHub,** so your network must reach github.com during setup. If setup stops on it, the message tells you why:
     - **the network blocks github.com:** try another network, e.g. a phone hotspot;
     - **GitHub's anonymous download limit was reached:** wait an hour and run it again.
3. **Python 3.10 or later**, with the packages in `1_sampling/scripts/daily_update/requirements_python.txt` (openpyxl). Install them with `python -m pip install -r requirements_python.txt`.
   - The frame and partner update also needs R's `dplyr` and `readr`: run `Rscript 1_sampling/scripts/daily_update/install_r_packages.R`.
   - Check this laptop can run the update: `python "<workspace>\1_sampling\scripts\daily_update\run_frame_and_partner_update.py" --check-env`. `<workspace>` is the `MSNA N-WEC 2026` folder.
4. **shinyapps.io access.** Jack creates a personal deploy token for you; it is revoked after the week. In R, run this **once**:
   ```r
   rsconnect::setAccountInfo(name = "impact-nga-jp", token = "<token>", secret = "<secret>")
   ```
   The token is then stored in your own Windows profile. **Never** put it in a file in the shared folder, in an email, or in git.
5. **Check everything:** [PENDING: the pre-flight command]. It lists anything missing and changes nothing.

---

## 2. Daily routine: one command

[PENDING: exact command, double-click file, expected runtime]

The launcher runs these phases in order:

| Phase | What it does | If it fails |
|---|---|---|
| 0. Pre-flight | Checks R, packages, Python, deploy credentials, that a new anonymised export is present, and that OneDrive has made no conflict copies | Nothing runs. The message says what to fix |
| 1. Data refresh and dashboard deploy | Reads the newest anonymised export; rebuilds submissions, deletions and checks; bundles the app; deploys to https://impact-nga-jp.shinyapps.io/dashboard_app/ | Nothing is uploaded and the last good dashboard stays live. Phase 2 does not run |
| 2. Frame and partner update | Refreshes the WORKING frame, rebuilds partner workbooks and maps in a staging folder, checks them, then publishes them to the partner folders | Partners keep their last good files. A frame problem restores the frame automatically. Phase 1's deploy is never undone |
| 3. Validity suite | Runs the 84+ standing checks on the result | Reported in the run summary |

At the end you get a plain-English summary and a log folder: [PENDING: location]. **Read the summary every day.**

**The dashboard shows all data collected** (Jack, 4 Oct). Round 1 is an internal milestone, marked by a dotted line on 30 Sep in the summary timeline. New submissions simply add to the totals.

---

## 3. Reading the run summary

- **All phases OK:** nothing to do.
- **Phase 1 stopped:** the dashboard was not updated. The summary names the failing step. Fix only what the message describes, e.g. a missing export, a OneDrive conflict copy, or a credential. If it is anything else, log it (section 8) and leave the dashboard as it is.
- **Phase 2 blocked:** partner files were not updated today, and partners keep yesterday's. **Do not edit frame files or partner folders by hand.** Log it with the summary attached.
- **Validity suite.**
  - **WARN:** expected and listed in section 9. Only note a WARN that is not on that list.
  - **FAIL:** log it with the check name and detail.

- **Phase 2 status** is in `1_sampling/output/daily_update_runs/LATEST_SUMMARY.json`:
  - `OK`: published.
  - `NO_CHANGE`: nothing new since the last run.
  - `BLOCKED`: a check said no; partners keep yesterday's files.
  - `ERROR`: the run could not finish; partners keep yesterday's files.
- **When Phase 2 blocks,** look up the failed check in the "When it blocks: what to do" table in [1_sampling/scripts/daily_update/README_daily_update.md](../1_sampling/scripts/daily_update/README_daily_update.md). The most common action-for-you case is a partner workbook left open in Excel: close it and re-run. Everything else on that table goes into the parking lot, with the run folder.

[PENDING: troubleshooting table for Phase 0/1 from the launcher]

---

## 4. What the automatic rules guarantee

Partners only ever see a complete, checked set of files. If anything is doubtful, nothing is published and partners keep yesterday's files: one day stale, never wrong. The frame and partner update runs in **strict** mode. Full detail: [README_daily_update.md](../1_sampling/scripts/daily_update/README_daily_update.md).
- **The sampling design cannot change.** The FULL frame and strata frame must be byte-identical to yesterday's.
- **Every change to the to-do list is explained.**
  - A household leaves the WORKING frame only because it is now achieved.
  - It comes back only if a confirmed deletion undid that.
  - Any other change blocks the run and restores the frame automatically from the archive taken at the start.
- **No achieved household stays on a to-do list.**
- **Built in a staging folder first.** Partner workbooks and maps are rebuilt there and must pass:
  - the builder's own reconciliation;
  - the MAP CHECK: every to-do point is on the partner's map;
  - the validity gate: workbooks equal the dashboard, stratum by stratum, and every partner is present.
- **Published all-or-nothing.** Only changed files are copied, each backed up first and checksum-verified after copying. If one copy fails, all are undone. If a partner file is open somewhere, nothing is copied.
- **Retired files are archived, never deleted.** A file the build no longer produces is moved to `_archived_not_produced_<date>` beside it, and only if nobody edited it.

---

## 5. Folder map

| Folder | What it is | Touch it? |
|---|---|---|
| `2_monitoring/` | Data pipeline and dashboard (start here) | Run the launcher only |
| `2_monitoring/cleaning/MSNA_Data_Cleaning/output/anonymised_data/` | Anonymised exports; the newest is what the pipeline reads | Add new exports here |
| `2_monitoring/reports/round1_weighting_package_2026-10-02/` | **Round 1 weights and representativity for your analysis** | Read only |
| `2_monitoring/reports/partner_data_recovery/outputs/_round1_closeout/` | Round 1 deletion and correction log | Read only |
| `1_sampling/output/data/data_collection/` | Sampling frame (FULL, WORKING, strata, cluster status) | Updated by the launcher only |
| `3. External coordination/NGA MSNA 2026 Package/` | Partner folders (workbooks, maps, field guides) | Updated by the launcher only |
| `validity_checks/` | Standing check suite (`CHECK_CATALOG.md` explains each check) | Run only |

---

## 6. Round 1 weighting package (for the analysis)

The package is `2_monitoring/reports/round1_weighting_package_2026-10-02/`; start with its `README_Round1_weighting.md`.
- **Coverage:** Round 1 is analysed for the **North-East and North-West states only**: Adamawa, Borno, Yobe, Katsina, Sokoto, Zamfara, Kaduna. Kebbi and every North-Central state are excluded.
- **Contents:**
  - one weight per household (`01_weights/`), keyed on `uuid`, with every individual in the loop sheets carrying their household's weight;
  - the 1 Oct anonymised dataset with the weights attached (`02_dataset/`);
  - representativity labels for strata, LGAs and states (`03_representativity/`);
  - a cluster table for your own weight checks (`01_weights/R1_cluster_table_NE_NW.csv`, README section 5.1).
- **Analysis design:** strata = `r1_strata_id`, weights = `r1_weight`, no cluster term. The same weights serve every level: stratum, LGA, State, overall.
- **Deletions are already out of the weights.** Weighted rows exclude the 2,599 removals in the Round 1 deletion log.
- **[PENDING DECISION, Jack]** Your cleaned dataset (`IMPACT_NGA_Dataset_MSNA-UNHCR-2026-Round1_October-2026.xlsx`) has 277 fewer weighted households in coverage than the package:
  - 198 duplicated or low-quality interviews you removed;
  - 79 interviews submitted on 1 Oct, which your pipeline treats as Round 2.

  A re-calibrated set of weights matching your cleaned data is prepared for Jack's decision. Until he decides, **do not finalise weighted tables.**
- **Full methodology:** `1_sampling/ROUND1_METHODOLOGY_AND_VALIDATION_GUIDE.md`; whole process: `1_sampling/MSNA_N-WEC_2026_METHODOLOGY.md`.

---

## 7. Boundaries for the week

| You may | Park for Jack (section 8) |
|---|---|
| Run the launcher, once or more a day | Any request to draw, add or move clusters, or to top up a stratum |
| Add new anonymised exports | Accessibility changes (a ward or LGA becoming accessible or inaccessible) |
| Share the dashboard link and today's partner workbooks | Partner coverage changes or reallocations |
| Produce the Round 1 analysis and submit to HQ | Disputes about deletions or partner achieved counts |
| Answer partners from the dashboard and their workbook | Anything the launcher blocked that its message does not explain |

---

## 8. Parking lot

Log every item you park in `2_monitoring/reports/do_week_parking_lot.md`, one line each: date, who asked, what, and the run summary if relevant. Jack works through it on his return.

---

## 9. Known, harmless messages

- **Validity suite WARNs, always present:**
  1. 18 zero-population strata have no representativity target, by design.
  2. The feasibility sheet lists 22 excluded strata, by design.
  3. The latest draw folder is a merge-staging folder.
  4. One coverage-decision row (Shagari) is housekeeping.
- **File dates.** OneDrive sometimes leaves an old modification date on a file that was rewritten. Judge freshness by content, never by date; the checks already do.
- **"Deployed dashboard is one refresh behind" WARN** straight after a frame update: cleared by the next deploy.

---

## 10. Contacts

- MSNA lead (away 5–11 Oct): Jack Philpott. Urgent only.
- [PENDING: backup contact at IMPACT]
