# MSNA 2026 — Monitoring (cleaning + dashboard)

Daily-updating pipeline: pulls survey submissions from KoBo, runs cleaning
and diagnostics against the sampling frame (coverage, duplicates, outliers,
progress against target per stratum), and updates a Shiny monitoring
dashboard. Cleaning and the dashboard run together on the same daily
cadence, but live in separate subfolders so the deployable app stays lean.

## Structure

- `cleaning/` — KoBo pull + cleaning/diagnostic scripts. Writes its
  processed output to `data/`.
- `dashboard_app/` — The Shiny app itself (`app.R` or `ui.R`/`server.R`).
  Reads from `data/`. Keep this folder to only what the app needs to run —
  deployment tools (shinyapps.io, Posit Connect) bundle whatever's in here.
- `data/` — Local exchange between cleaning and the dashboard. Gitignored
  (reproducible from `cleaning/` + `input_data/`).
- `input_data/` — Static copy of the sampling frame (from
  `../1_sampling/output/`) that cleaning diagnostics run against. Gitignored;
  copy in the file(s) you need, don't reference `1_sampling/` by path.

## Setup (once code exists here)

```r
renv::init()   # captures the actual packages this pipeline uses
```

Commit `renv.lock`, not `renv/library/` (already gitignored).
