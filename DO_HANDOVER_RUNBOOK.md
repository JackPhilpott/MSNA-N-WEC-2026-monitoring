# MSNA N-WEC 2026: data officer's runbook (week of 5 October 2026)

**For:** the data officer running the MSNA N-WEC 2026 data pipeline while the MSNA lead (Jack Philpott) is away, 5–11 October 2026.
**What you'll do this week:**
1. Refresh the data and redeploy the monitoring dashboard, with one command.
2. Keep the sampling frame and partner folders (workbooks and maps) in step with the new data. This runs automatically, straight after step 1.
3. Submit the Round 1 analysis and cleaned data to HQ. The weights and representativity come from the Round 1 weighting package (section 6).

**What you won't do this week:** resampling (new draws or top-ups), accessibility changes, partner reallocations, the recovery-workbook pipeline. Log any request of this kind in the parking lot (section 8) for Jack's return.

> **BEFORE YOUR FIRST RUN: wait for Jack's confirmation that the shared folder has been re-linked to OneDrive, and that the dashboard is spare-aware (v16).**
> On 4 October the `IMPACT NGA - 02. MSNA` library stopped syncing on Jack's laptop, so that evening's refreshed data has not reached the shared folder yet. Jack re-links it on 5 October. A run started before then would begin from an older copy of the data and split it from ours. Run nothing, not even the dry run, until Jack confirms.

---

## 1. One-time setup on your laptop

1. **Shared folder.** Make sure OneDrive syncs the whole `IMPACT NGA - 02. MSNA` library, and that `4. Data/MSNA N-WEC 2026/` and `3. External coordination/NGA MSNA 2026 Package/` are set to *Always keep on this device*.
2. **R 4.6, Rtools and packages.**
   - Install R 4.6 from https://cran.r-project.org/bin/windows/base/ if it isn't installed.
   - Install **Rtools** from https://cran.r-project.org/bin/windows/Rtools/ (the version listed for your R). It's needed because 13 of the packages are compiled on your computer. Setup checks for it first and stops with this instruction if it's missing.
   - Then double-click `2_monitoring/setup_this_computer.bat` once. It needs internet and takes about **20–30 minutes** the first time.
   - It installs the dashboard's R packages, at the exact versions the project uses, into a library on your own computer (`%LOCALAPPDATA%\R\renv-library`), never in the shared folder.
   - It installs `openpyxl` for Python, then runs the pre-flight check (item 5).
   - It is safe to run again: it only adds what is missing.
   - **If you ran setup before 5 October:** after the re-link, install Rtools and run it again. The earlier version could stop with a false "R PACKAGE INSTALL FAILED", or fail on packages that need Rtools.
   - Tested on 5 Oct on a clean package cache: 119 packages downloaded and installed in about 18 minutes, `cleaningtools` included, and the pre-flight passed its package and Python checks.
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
5. **Check everything:** double-click `2_monitoring/setup_this_computer.bat` again. Its last step is the launcher's pre-flight, judged as for a real run, and it ends with "SETUP COMPLETE" or a list of what to fix. It changes no data. From a terminal in `2_monitoring/`, the same check is `Rscript run_refresh_and_deploy.R --preflight-only`.

---

## 2. Daily routine: one command

1. **Put the day's files in place.** The launcher reads them only from these two places in the workspace, not from any other library or folder:
   - the new anonymised export, `NGA2605_MSNA_anonymised_<date>.xlsx`, in `2_monitoring/cleaning/MSNA_Data_Cleaning/output/anonymised_data/`;
   - the KoBo audit logs, `audit.zip`, in `2_monitoring/cleaning/MSNA_Data_Cleaning/audit/`.

   On 4 Oct the export was saved to another library by mistake and `audit.zip` was missing from its folder; the pre-flight now stops if either is missing.
2. **Wait for OneDrive** to finish syncing (green ticks), so the export is complete on your laptop.
3. **Double-click `2_monitoring/run_refresh_and_deploy.bat`.**
   - On your first day, double-click `run_refresh_and_deploy_DRYRUN.bat` first. It does everything except publish: nothing goes to the live dashboard or the partner folders.
   - A full run takes about **30–40 minutes**: phase 1 about 15, phase 2 about 10–15, the validity suite about 5.
   - The window shows progress and stays open at the end with a one-line result. Don't close it while it runs.

The launcher runs these phases in order:

| Phase | What it does | If it fails |
|---|---|---|
| 0. Pre-flight | Checks R, packages, Python, deploy credentials, that a new anonymised export is present, and that OneDrive has made no conflict copies | Nothing runs. The message says what to fix |
| 1. Data refresh and dashboard deploy | Reads the newest anonymised export; rebuilds submissions, deletions and checks; bundles the app; deploys to https://impact-nga-jp.shinyapps.io/dashboard_app/ | Nothing is uploaded and the last good dashboard stays live. Phase 2 does not run |
| 2. Frame and partner update | Refreshes the WORKING frame, rebuilds partner workbooks and maps in a staging folder, checks them, then publishes them to the partner folders | Partners keep their last good files. A frame problem restores the frame automatically. Phase 1's deploy is never undone |
| 3. Validity suite | Runs the 84+ standing checks on the result | Reported in the run summary |

At the end you get a plain-English summary and a log folder: `2_monitoring/runs_log/<date_time>/`. It holds `RUN_REPORT.md` (the summary) and one full log per phase. Dry runs end in `_dryrun`. These folders stay on your laptop and are not shared. **Read the summary every day.**

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

**The launcher's result.** The window's last line and the top of `RUN_REPORT.md` give one of these:

| Result (exit code) | What it means | What to do |
|---|---|---|
| FINISHED OK (0) | Everything ran and passed | Nothing |
| STOPPED AT THE PRE-FLIGHT CHECKS (10) | Nothing ran, nothing changed | Fix the items marked FAIL (table below), then run again |
| THE DASHBOARD STEP FAILED (20) | Nothing was uploaded; the live dashboard is unchanged | Read "End of the log" in the report. A network drop during the upload: run again. Anything else: park it with the report |
| PHASE 2 DID NOT COMPLETE (30) | The dashboard was updated; partners keep yesterday's files | See "When Phase 2 blocks" above |
| THE VALIDITY SUITE FOUND A FAIL (40) | Everything ran; a check failed | Park it with the check name and detail |
| THE LAUNCHER HIT AN ERROR (50) | The launcher itself stopped | Park it with `RUN_REPORT.md` and `launcher.log` |

**Pre-flight FAILs and their fixes:**

| FAIL | Fix |
|---|---|
| R packages missing / renv not active | Run `setup_this_computer.bat` |
| shinyapps.io account not set up | Do the one-time token step (section 1, item 4) |
| Newest anonymised export missing, too small or unreadable | Check the export is in `anonymised_data/` and that OneDrive has finished downloading it |
| KoBo audit logs (`audit.zip`) missing | Put the latest `audit.zip` from the cleaning pipeline in `cleaning/MSNA_Data_Cleaning/audit/`. Don't work around it: the interview-duration check needs it |
| OneDrive conflict copies | A file named like `<name>-<COMPUTERNAME>.<ext>` sits next to `<name>.<ext>`. If it is clear which one is right, keep it and move the other into an `_archive` folder. If not, park it |
| Another run is still marked as running | If no other run is going, delete `2_monitoring/runs_log/RUNNING.lock` and start again |

WARNs (e.g. "export is N days old") don't stop the run; they're listed in the report.

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

**Frame hand-offs.** The hand-off zips are labelled v15 (pre-spares, 4 Oct night) and v16 (post-spares, 5 Oct morning). Inside the workspace the frame files keep the `_v14_` name until a later planned version bump. The daily run is unaffected.

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
- **"10 partner-LGA row(s) could not be matched to the sampling frame"** (Guyuk, Mayo-Belwa, Geidam, Tarmua, Gudu, Tureta, Dan Musa, Sabuwa, Safana, Dandi), in the dashboard's warnings banner. These LGAs have no to-do households left, so the coverage workbook can't be matched to them. They are still assigned to FACT through the frame (the same run says "Frame-derived union added 10 row(s)"), so nothing shows as "Not partner-assigned". A different or longer list is not covered by this note: log it.

---

## 10. Contacts

- MSNA lead (away 5–11 Oct): Jack Philpott. Urgent only.
- Backup contact at IMPACT: Lina Camperos (Jack's line manager).
