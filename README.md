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

## Setup

```r
renv::restore()   # installs the exact package versions from renv.lock
```

`renv.lock` is committed (already tracked); `renv/library/` is gitignored.
Open `monitoring.Rproj` in RStudio and renv activates automatically
(`.Rprofile` handles this) — no manual `renv::init()` needed, that's
already been done.

## Status (2026-08-02) — v1 draft, built against mock data

A cleaning script is being built separately and will land within a day or
two. To avoid blocking on that, this v1 was built end-to-end against a
**simulated submissions dataset** so the dashboard itself could get to
~95% complete before real data exists. Everything below is real except
the submission data.

- **`input_data/`** populated: WORKING sampling frame (household- and
  strata-level, 31,051-interview fielding plan, 176 covered LGAs),
  coverage summary, and admin0/1/2 boundary shapefiles — all copied from
  `../1_sampling/output/` and `../1_sampling/input_data/boundaries/` per
  the handoff convention (see `../README.md`). Also
  `input_data/kobo_form/NGA2605_MSNA_Kobo_30072026.xlsx` — the real KoBo
  XLSForm (synced 2026-08-02), used to ground the mock schema in real
  field names rather than inventing one from scratch.
- **`cleaning/mock/`** — `generate_mock_submissions.R` produces
  `data/mock_submissions.csv`, a simulated ~40%-complete submissions
  dataset (uneven progress across LGAs, realistic daily trend, injected
  GPS/duration/duplicate/LGA-mismatch/hh-size-mismatch/refusal issues) so
  every dashboard tab has something real-looking to show. **This is a
  placeholder, not the real cleaning pipeline** — see
  `cleaning/mock/README.md` for the full column contract the dashboard
  expects; once real cleaned data exists, point the dashboard at that
  (matching the same contract) instead of rebuilding it.
  - Important finding while building this: the real KoBo tool (as of the
    30/07 sync) has **no point-number or in-app distance-verification
    field** — that existed in an earlier draft but was removed, and the
    `cluster_id` choice list is still an unpopulated placeholder. This
    means submissions can't self-report which sampled point they cover;
    matching a submission back to a specific sampling-frame row has to
    happen **post-hoc, by nearest-GPS-within-submitted-LGA×pop_type**.
    The mock data simulates that same matching logic
    (`dist_to_matched_point_m`, `match_quality`) so the dashboard's data
    quality tab reflects the kind of matching the real cleaning script
    will also need to do — worth confirming this is how the real
    cleaning script plans to do it, since the dashboard's flag logic
    assumes it.
- **`dashboard_app/`** — bslib `page_navbar` app, 6 tabs behind a shared,
  **cascading** sidebar filter: Region → State → LGA → Ward (each level's
  choices narrow to whatever's selected above, resetting to "All X" when
  a parent changes), plus population group / partner / date-range filters
  alongside. Dual audience: internal IMPACT/FACT monitoring & coordination
  (all tabs, unfiltered) and field partners (filter to their org, or use
  the dedicated Partner Report tab) — see the Home tab for the fuller
  framing.
  - **Home** — top-level project introduction (placeholder text, flagged
    for you to refine) + at-a-glance stats.
  - **Progress Overview** — KPI tiles (achieved, % of target, consent
    refusal rate, days remaining) + daily submissions trend vs. pace
    needed to finish on time + progress by region.
  - **Coverage Map** — a **toggle at the top of the map** ("Coverage by
    LGA" / "Coverage by cluster") switches the whole map between two
    views:
    - *Coverage by LGA*: the original choropleth, LGAs shaded by % of
      WORKING target achieved.
    - *Coverage by cluster*: every PSU (Non-IDP hexagon / IDP site)
      colour-coded traffic-light style — green = complete, yellow = in
      progress, red = not started — each with a popup giving the same
      geographic + achieved/target(%) info as the LGA view, just at
      cluster level. This view is also the one place that's actually
      **date-range aware** (see caveat below).
    Independent of that toggle, the layers control (top-right) lets you
    turn on **ward boundaries** (new, GRID3 source) and **satellite
    imagery** as a basemap, alongside the existing state-boundary and
    PSU-reference-outline layers.
  - **Progress by LGA** — sortable/filterable table, achieved vs. target
    per LGA × population group, status-coded (Far behind / Behind / On
    track / Complete).
  - **Data Quality** — flag-type breakdown + flagged submissions table
    (core review flags only — see "Update 2026-08-03" below for where
    enumerator performance and deeper integrity checks moved to).
  - **Partner Report** — pick a partner, see their assigned LGAs'
    progress on-screen, and download an **Excel** or **PDF** summary
    (target/achieved/% by LGA, status-coded, focus-area list of the
    LGAs furthest behind). Meant to be handed to a partner directly.
  - Every LGA-level view — *Coverage by LGA*, the *Progress by LGA*
    table, and Progress Overview's region chart — is now **date-range
    aware**, same as *Progress Overview*'s KPIs, the *Data Quality* tab,
    and *Coverage by cluster* already were. `global.R`'s
    `compute_progress_by_stratum()` takes whatever submissions subset
    it's given; `app.R`'s `filtered_stratum` reactive calls it on
    `filtered_subs()` (already scoped by date range + every other
    filter) instead of on the full, unfiltered `submissions_raw`. The
    one deliberate exception: the **Partner Report** stays cumulative-
    to-date regardless of the sidebar's date filter — a report handed to
    a partner should reflect total progress, not whatever date window
    happened to be selected when it was generated.
  - Each server module (including the report builders) is tested via
    `dashboard_app/tests/smoke_test.R` (`shiny::testServer`, no browser
    needed) — currently passing, plus direct (non-Shiny) tests of the
    Region→State→LGA→Ward cascade functions and of
    `compute_progress_by_stratum()`'s date-range awareness.
  - **Known perf note**: the Ward filter's initial choice list (~1,729
    wards nationally) makes the sidebar's first render a bit heavy —
    shiny warns about it (`selectizeInput` server-side mode would fix
    this properly). Not blocking, but worth doing if the sidebar ever
    feels sluggish on first load.
  - **Assumption to confirm**: fielding window used for the "days
    remaining" pace indicator is 2026-07-15 to a placeholder end date of
    2026-08-26 (~6 weeks) — not from a real fielding plan. Update
    `FIELDING_START`/`FIELDING_PLANNED_END` in
    `cleaning/mock/generate_mock_submissions.R` and
    `dashboard_app/global.R` once known.
  - Not yet done: real KoBo API pull, shinyapps.io/Posit Connect
    deployment config (data currently read via relative path from outside
    `dashboard_app/`, fine for local review, needs revisiting for a real
    deploy), and swapping the UI framework if bslib doesn't land well —
    flagged as an open decision, see chat. Home tab intro text is a first
    draft only.
- **`cleaning/prep/`** — one-time (not daily-rerun) prep scripts that
  produce derived static files in `input_data/`, kept separate from
  `cleaning/mock/` since they'll stay useful after the mock data is
  replaced:
  - `prep_partner_lga_assignment.R` — reshapes
    `input_data/partner_coverage/Partnerscoverage.xlsx` (real per-LGA
    partner matrix, 3 regional sheets) into
    `input_data/partner_coverage/partner_lga_assignment.csv` (long,
    `adm2_pcode` × `org_id`), matched against the sampling frame's admin
    names/pcodes (exact match + fuzzy fallback per state). 176/176
    WORKING LGAs matched bar one ("Nasarawa Eggon" — a real LGA name that
    the raw file's state/LGA split parses awkwardly; falls back to
    `org_id = "other"`, flagged if you want it fixed).
  - `prep_psu_geometries.R` — filters the DESIGN-frame selected-clusters
    geometries (`1_sampling`'s pre-partner-coverage archive — the only
    place PSU geometries exist) down to the 3,343 clusters still in the
    WORKING fielding plan, reprojects to WGS84, splits into
    `input_data/boundaries/psu/psu_hexagons_non_idp.gpkg` (2,535 hexagon
    polygons) and `psu_sites_idp.gpkg` (808 IDP site points) — real PSU
    geometries, not simulated — and attaches each cluster's modal ward
    (`adm3_name`/`adm3_pcode`, joined from the household frame) so the
    ward filter can scope the per-cluster map view too.
  - `prep_admin3_wards.R` — filters the **GRID3** ward boundary layer
    (`../1_sampling/input_data/boundaries/GRID3_NGA_Ward_Boundaries_v1/`)
    to our 11 fielding states → `input_data/boundaries/nga_wards_grid3.gpkg`.
    Deliberately GRID3, not the COD admin3 dataset also present in
    `1_sampling/input_data/` — GRID3 is the actual ward source the
    sampling frame's own `adm3_name`/`adm3_pcode` columns use
    (`admin3_source == "GRID3"` for every row); COD admin3 uses a
    different delineation/pcode scheme entirely and wouldn't match the
    frame's ward attribution.
  - Partner org list/labels (`ORG_LABELS` in `dashboard_app/global.R`)
    come from the real KoBo tool's `l_org_id` choice list (21 partners
    incl. "Other").

## Update (2026-08-03) — full sweep: new tabs, deeper analytics

Asked to do a broad pass adding whatever seemed useful for the three
audiences (partners, field coordinators, technical supervisor), erring
toward "too much, scale back later" rather than under-building. Everything
below re-tested (module smoke tests + live app boot) before considering it
done.

**New top-level tabs:**
- **Data Export** — download whatever's currently in scope (respects
  every sidebar filter) as CSV or Excel: the submission-level data, or the
  LGA × pop-group progress table. Plus a 200-row on-screen preview. For
  partners wanting their own data, or ad hoc analysis outside the
  dashboard.

**New tabs under an "Analysis" dropdown** (kept off the main navbar to
avoid clutter — these are deeper-dive, less-frequently-needed views):
- **Enumerator Performance** — leaderboard (submissions, avg./median
  duration, days active, avg./active day, busiest single day, flag rate,
  avg. sync lag), a duration-vs-flag-rate scatter (bubble size =
  submissions — spot enumerators who are both fast *and* high-flag-rate),
  a top-15 bar chart, and a per-enumerator drill-down trend.
- **Data Integrity Checks** — deeper diagnostics beyond the core review
  flags, aimed at the technical supervisor. None of these prove anything
  on their own (explicitly framed as leads, not verdicts) — but they're
  real, computed checks, not decorative:
  - **Exact-GPS-duplicate detection** — submissions sharing bit-identical
    coordinates (continuous GPS jitter essentially never coincides by
    chance) — a classic "sat in one place, submitted several records"
    fabrication signal. Computed directly from the coordinates, the same
    way a real check would work — there's no upstream flag column to just
    read.
  - **Whipple's Index** (age-heaping / digit-preference) — a standard
    demographic data-quality statistic, both nationally and per-enumerator
    (top-15 chart), plus an age-distribution histogram so the heaping is
    visible directly.
  - **Time-of-day histogram** with off-hours submissions shaded.
  - **Duration distribution histogram.**
  - **Implausible daily-count table** — enumerator-days exceeding a
    plausible max (`MAX_PLAUSIBLE_INTERVIEWS_PER_DAY = 12` in `global.R`,
    given ~40min average interviews — adjust if that assumption is wrong).
- **Sample Representativeness** — compares the achieved sample's
  demographic profile against the sampling design's *own* assumptions
  (there's no external population benchmark available, but `n_pop`/`N_hh`
  in the strata frame — the household-count assumption the targets were
  derived from — is a genuine, checkable comparison): household-size
  histogram with the design assumption overlaid, a design-vs-achieved
  avg. household size table by region × pop-group, a setting
  (rural/urban/camp) breakdown, and a respondent age-gender pyramid.

**Enhancements to existing tabs:**
- **Progress by LGA table** — two new columns: **% from reserve**
  (how much of a stratum's achieved sample came from reserve rows, i.e.
  primary non-response replacements — a field-difficulty signal) and a
  naive **ETA at current pace** / **pace vs. deadline** projection (each
  stratum's own achieved-to-date rate extrapolated against
  `FIELDING_PLANNED_END` — a rough projection, not a commitment, labelled
  as such in the tab).
- **Home** — added a "Today's snapshot" panel (latest submission date,
  day-over-day counts, total achieved, most recent upload timestamp) and
  an auto-generated "Priorities" panel (LGAs furthest behind target,
  enumerators with the highest flag rates). Both deliberately
  **national/unfiltered** regardless of the sidebar — Home is a stable
  landing page, not a working analysis view, so it shouldn't appear to go
  empty just because a partner filter is active elsewhere.
- **Data Quality** tab simplified — the per-enumerator table moved to the
  new, much richer Enumerator Performance tab rather than existing in two
  places; Data Quality now covers core review flags only.

**Mock data additions** (`cleaning/mock/generate_mock_submissions.R`),
needed to give the new analyses something real to detect — see that
file's README for the full list: off-hours submissions
(`flag_off_hours`), a subset of enumerators who round ages to the nearest
5 (`flag_age_rounder_enum`), a handful of enumerators who reuse
bit-identical GPS coordinates (no dedicated column — detected from the
coordinates directly), and upload/sync lag (`sync_lag_min`,
`uploaded_at`). These are **investigative signals, not core review
flags** — deliberately not folded into `any_quality_flag`, so existing
Data Quality tab numbers didn't shift when this was added. Also: the
generator's `TODAY` is now `Sys.Date()` (was hardcoded) so re-running it
later naturally extends the trend instead of going stale.

**No new R packages required** — `renv::status()` clean throughout.

## Update (2026-08-03) — global theme/filter overhaul, per-page polish

Full pass through a long list of usability feedback. Re-tested throughout
(full smoke-test suite + live app boot), `renv::status()` clean.

**Fixed bugs (not new features — things that were actually broken):**
- **Region filter showed no options at all.** `global.R` was comparing
  region *labels* ("North-East (NE)") against the raw region *codes*
  ("NE"/"NW"/"NC") in the data — always false. Fixed.
- **Coverage Map appeared blank until you touched a filter**, and **PSU
  hexagons/sites showed up by default in the LGA view** (only correcting
  itself once you toggled to Cluster view and back). Same root cause:
  Coverage Map isn't the first tab shown, and Shiny suspends an output's
  `render*` execution until its tab is first visited — but the
  `leafletProxy()` calls that add all the map's layers are plain
  observers, which fire at session start regardless of tab visibility.
  They were targeting a map that didn't exist in the browser yet, and
  were silently dropped. Fixed with
  `outputOptions(output, "map", suspendWhenHidden = FALSE)`, which forces
  the base map to render immediately — the standard fix for this
  well-known Shiny+leaflet+tabs interaction.

**Global — consistent colour theme:**
- `POP_TYPE_COLORS` (`global.R`): Non-IDP = blue `#2E6F9E`, IDP = orange
  `#D9822B` — a classic colourblind-safe pair, deliberately distinct from
  the (unrelated) traffic-light `STATUS_COLORS` so the two colour systems
  never get confused. Used in the Progress Overview charts and as
  text-colour badges on every "Pop. group" table column. A third
  `COMBINED_COLOR` (navy) is used wherever a "both groups together" series
  sits alongside the pair.
- **Status vocabulary unified dashboard-wide**: the Progress by LGA
  table's status field (previously its own 4-tier Far behind/Behind/On
  track/Complete scheme) now uses the *same* 3-tier Complete/In
  progress/Not started scheme (and colours) as the Coverage Map's
  per-cluster traffic-light view — one consistent vocabulary everywhere a
  stratum/cluster's status is shown (Progress by LGA, Partner Report,
  Home's priorities panel, Coverage Map).
- Taller UI throughout (per your answer to "wider vs taller") — a global
  CSS rule gives every `value_box` a minimum height and lets its text
  wrap instead of clipping (this is what was cutting off text in the
  Analysis tabs' summary boxes), and most chart heights across the
  Analysis tabs, Progress Overview, and the Coverage Map are bumped up.

**Filters — cascading and now fully mutual:**
- Region, State, LGA, Partner, and Population group all narrow each
  other's available choices now — not just the old one-directional
  Region→State→LGA→Ward cascade. Select a partner and Region/State/LGA
  narrow to just their coverage area; select "IDP" and LGA/Partner narrow
  to just the ~143 LGAs with IDP presence; and so on in every direction.
  One function, `compute_filter_choices()` in `global.R`, is the single
  source of truth every one of these pick-lists is computed from (filters
  a `filter_base` table — strata × partner assignment — by every *other*
  currently-selected filter). Ward stays downstream-only (narrowed by LGA,
  narrows nothing above it), per the scope discussed.
- **Redesigned the multi-select widgets** — dropped the "All X"
  pseudo-choice entirely (it was awkward: staying visibly "selected"
  alongside real picks, requiring a manual deselect). Every filter now
  starts with all its real choices genuinely pre-selected; deselecting one
  narrows, exactly like an ordinary multi-select. `smart_selection()`
  preserves a manual narrowing across cascading recomputes (keeps
  whatever's still valid; only resets to "select all" if nothing you'd
  picked remains valid) — so narrowing Region doesn't blow away a State
  selection that's still perfectly valid under the new Region.

**Progress Overview:**
- Fixed the secondary y-axis title getting cut off (margin adjustment).
- Daily submissions is now a **stacked** column chart — Non-IDP / IDP /
  Unmatched (the latter for LGA-mismatched submissions that couldn't be
  matched to a frame row) — instead of one undifferentiated bar.
- Progress by region is now **3 bars per region** — Non-IDP, IDP, and
  Combined — instead of one combined-only bar.
- "Interviews achieved" now reads **achieved / planned** (e.g.
  "11,821 / 30,996") instead of just the achieved count on its own.

**Coverage Map:**
- Added the **Nigeria Admin0 national outline** (always on, non-interactive
  so it can't block anything underneath).
- Added a **national Admin1 layer**: the 11 assessment states get a
  boundary outline (bold if currently selected in the sidebar, thin/faded
  if in-assessment-but-filtered-out); the other Nigerian states are shown
  as a permanent semi-transparent grey fill, so there's always full
  national context. **Design note**: I read "if state filter is Borno
  then only show Borno from the layer" as wanting the state layer
  connected to the filter, but chose a bold/thin distinction rather than
  fully hiding non-selected assessment states, since the grey/non-
  assessment treatment already needed a "not currently selected but still
  relevant" middle tier — this shows both the current selection and the
  overall assessment footprint at once. Happy to switch to fully hiding
  non-selected states if you'd rather have that.
- **Re: your question about bringing the state boundary above the LGA
  fill** — yes, safe: it's now drawn after (on top of) the LGA/cluster
  fill layers, but with `interactive = FALSE`, so it can't intercept
  hover/click events at all — the LGA popups underneath are completely
  unaffected.
- **Ward and State boundary reference layers are now scoped to the active
  filters** — selecting Borno only draws Borno's (and other in-scope
  states') wards/boundary in those layers, not the whole country's.
- **Zoom-to-extent**: the map now calls `fitBounds()` to the current
  filter scope's LGAs whenever the filter selection changes, instead of
  sitting at a fixed national view regardless of what's selected.

## Update (2026-08-03b) — picker-style filters, filterable table headers, first theme pass

Follow-up feedback on the round above. Re-tested (smoke tests + live app
boot), `renv::status()` clean (one new dependency, noted below).

- **Filter widgets replaced again** — `selectizeInput`'s tag-list display
  meant every filter defaulting to "all selected" rendered as a long wall
  of individual removable tags (176 for LGA, ~1,729 for Ward) stretching
  the sidebar absurdly long. Switched to `shinyWidgets::pickerInput`
  (new dependency), which collapses to a compact "X of Y selected"
  summary instead of listing every tag, adds a search box and
  select-all/deselect-all actions, and (for Ward specifically)
  virtual-scrolls the list instead of rendering all ~1,729 DOM nodes at
  once. Same underlying mutual cross-filtering logic — only the widget
  and its `update*Input` call changed (`updatePickerInput` in place of
  `updateSelectizeInput`).
- **Progress by LGA's Status column (and Region/State/Pop. group/Pace vs.
  deadline) are now clickable dropdown filters**, not free-text search
  boxes — DT's `filter = "top"` renders a dropdown of the actual values
  when the column is an R factor rather than a plain character/string
  column, so these are just `factor(...)` now. Applied the same treatment
  to the Partner Report table (also gained a filter row, which it didn't
  have before) and the Data Quality flagged-submissions table
  (State/Match quality).
- **Added a caption explaining "Unmatched"** on the Progress Overview
  daily-submissions chart, since the question came up: those are
  submissions where the enumerator selected the wrong LGA in the KoBo
  app, so the post-hoc GPS matching (see `cleaning/mock/README.md` for
  why matching has to happen this way at all) can't find a sampled
  cluster to link them to, and therefore can't determine their pop_type
  either. This is expected to happen at some low rate in real fieldwork
  too — it's not a mock-data-only artifact — the wrong-LGA-selection
  mistake is genuinely possible with a real KoBo dropdown, especially
  near LGA borders or between similarly-named LGAs. It's already tracked
  as `flag_lga_mismatch` on the Data Quality tab; this just makes the
  connection to what shows up in the Progress Overview chart obvious
  without having to go find that tab.
- **First pass at an overall theme** (explicitly a starting point, not a
  final look): navbar and sidebar now use a dark navy/blue-grey
  (`THEME_NAVBAR_BG`/`THEME_SIDEBAR_BG`/`THEME_SIDEBAR_FG` in `global.R`)
  with light text; the main body deliberately keeps Bootstrap's default
  white background/dark text untouched, so cards, tables, and the
  existing status/pop-type colour coding all keep reading clearly against
  it. Only the outer chrome changed — value_box theme colours
  (primary/success/warning/danger) are untouched for now.

## Update (2026-08-03c) — fixed the filter feedback loop; deployed to shinyapps.io

**Bug: filters/map/charts refreshing constantly.** The mutual cross-filter
observers (added in the update above) called `update*Input()`
unconditionally on every invalidation. `shinyWidgets::pickerInput`'s
underlying JS fires a change event on *every* `updatePickerInput()` call —
even when the choices/selected passed in are identical to what's already
there — so each of the 5 mutually-narrowing filters kept re-triggering all
the others forever. Fixed with `filter_ui_state` (`app.R`): a
`reactiveValues` store tracking what was last actually sent to each
filter, and `sync_filter_input()`, which only calls `update*Input()` when
the new choices/selected genuinely differ from what's already there. Has
a regression test (`tests/smoke_test.R`) that monkey-patches
`update*Input` to count calls and asserts they stop after reaching a
fixed point instead of growing without bound.

**Deployed to shinyapps.io.** First attempt failed — the app errored on
startup with `'../data/mock_submissions.csv' does not exist`, because
shinyapps.io only bundles the `dashboard_app/` directory itself, not the
sibling `data/`/`input_data/` folders the app actually reads from (the
local dev convention). Fixed two ways:
- `global.R`'s `DATA_DIR`/`INPUT_DIR` now fall back to `data`/`input_data`
  (relative to `dashboard_app/` itself) if the sibling `../data`/
  `../input_data` folders aren't found — i.e. when actually running
  deployed, not just locally.
- **`deploy_dashboard.R`** (project root) copies `data/` and
  `input_data/` into `dashboard_app/data`/`dashboard_app/input_data`
  (already gitignored, same rule as the top-level folders) before calling
  `rsconnect::deployApp()`. Run `source("deploy_dashboard.R")` from the
  project root to redeploy — requires the shinyapps.io account already
  linked on this machine (`impact-nga-jp`, via
  `rsconnect::setAccountInfo()`, done previously — nothing else needed to
  redeploy from here).

**Live at**: <https://impact-nga-jp.shinyapps.io/dashboard_app/> — verified
via `rsconnect::showLogs()` after redeploying: clean startup, no errors
(only benign GDAL "GeoPackage version may only be partially supported"
warnings — informational, doesn't affect functionality).

There's also a second, older app slot on the same account,
`msna_nga_monitoring`, which 404s (looks abandoned from an earlier
attempt) — left it alone since deleting it wasn't asked for; let me know
if you'd like it cleaned up too.

## Update (2026-08-03d) — fixed the filter "lock" bug; not yet redeployed

Not yet pushed to shinyapps.io per your instruction — local commit/testing
only this round, redeploy on request via `source("deploy_dashboard.R")`.

**Bug: picking one Region value made all others disappear, permanently.**
The previous round made Region/State/LGA fully bidirectional (each
narrows the others). That's fine for independent facets, but Region/
State/LGA is a strict *containment* hierarchy — every State belongs to
exactly one Region — so it created a self-reinforcing lock: picking
Region = "North-West" correctly narrowed State to NW's states, but that
narrowed State then fed back into Region's *own* choice list, shrinking
it to just "North-West" too — permanently, since North-East was no
longer even in the list to click back in. This is a documented failure
mode of "only relevant values"/fully-mutual filtering on a nested
hierarchy (Tableau's own docs describe this exact trap and prescribe the
same fix used here).

**Fix**: Region/State/LGA now narrow strictly top-down *among themselves*
again (parent narrows child, never the reverse) — Region's choices depend
only on Partner/Population group; State's depend on Region + Partner/Pop.
group; LGA depends on Region + State + Partner/Pop. group. Partner and
Population group are genuinely independent facets (not nested inside
geography), so they stay fully mutual with the whole hierarchy and with
each other, as before — that pairing is far less likely to lock (it isn't
a strict containment relationship), but not mathematically impossible,
which is why:

**Added a "Reset all filters" button** (top of the sidebar) regardless,
as a safety net for this or any other combination a user manages to
paint themselves into — restores every filter to "everything selected"
(including the date range) unconditionally.

New regression tests in `tests/smoke_test.R`: confirms narrowing Region
still correctly narrows State (forward cascade intact) while Region's
*own* choice list is never touched/shrunk as a result (no lock).

## Update (2026-08-03e) — reset button styling; redeployed

Small follow-up: "Reset all filters" button now uses Bootstrap's
`btn-secondary` class (grey background, white text) instead of the
unstyled default, so it's actually visible against the sidebar. Deployed
to <https://impact-nga-jp.shinyapps.io/dashboard_app/> via
`source("deploy_dashboard.R")` — verified live (HTTP 200, styled button
present in the served page).

To run locally: open `monitoring.Rproj` in RStudio (or from this folder,
`shiny::runApp("dashboard_app")`).

## Update (2026-08-10) — SCI field feedback investigated; boundary-source rule established

Save the Children flagged 54 sampling points (`field_verify/...SCI_Feedback_
input.xlsx`, "Comment By SCI") as being in the wrong LGA. Investigated via
`field_verify/verify_sci_boundary_flags.R` and `_crosscheck.R` (point-in-
polygon re-join against the production boundary sources, cross-checked
against the master WORKING frame). **Not a code bug or GPS error**: the
sampling pipeline attributes LGA (`adm2_name`/`adm2_pcode`) from OCHA/COD
(`nga_admin2.shp`), but ward (`adm3_name`/`adm3_pcode`) from GRID3, and
GRID3's ward layer carries its own embedded `lganame` field that disagrees
with OCHA/COD for all 54 points — matching SCI's claim exactly (Mashi,
Daura, Sandamu, Baure, Maru, Gusau instead of Mai'adua/Zango/Bungudu).
Points sit 14–1,100m (median 215m) from the LGA border — a genuine
contested-boundary disagreement between two real datasets, not noise.

**Boundary-source rule (governs all future admin-boundary work in this
project, not just this incident)**: OCHA/COD is the official humanitarian
boundary source but has no admin-3 (ward) product — GRID3 exists here
purely to fill that gap. GRID3 is not government-endorsed and leans on
social/settlement constructs rather than official lines, so it must
**never** substitute for OCHA/COD at admin-0/1/2 — only used as
supplementary data at admin-3, where OCHA/COD has nothing to offer.
Concretely: LGA-level questions always resolve to OCHA/COD
(`nga_admin2.shp` or its edge-matched variant), even where GRID3's own
`lganame` disagrees, as it does for these 54 points. **Decision: sampling
frame LGA attribution for these points is unchanged** — kept as
Mai'adua/Zango/Bungudu per OCHA/COD.

Separately, the same feedback file also carried 113 "Insecurity Ward"
flags (Zamfara/Bungudu, 6 wards) — a field-access issue, unrelated to
boundary correctness, split out and left for field ops/reallocation to
handle. The Benue/Kwande LGA appeared in the file's own summary sheet with
no corresponding points sheet — confirmed with the partner as expected
(SCI simply had no points to flag there), not a data gap.

## Update (2026-08-11) — boundary-source transparency: dashboard note + all-partner workbook change

Same incident as above, broadened to all 10+ partners once the same LGA
dispute pattern recurred beyond SCI. Two actions taken:

- **Dashboard**: `dashboard_app/R/mod_home.R`'s Home tab now carries a
  permanent "Administrative boundary sources" paragraph (LGA always OCHA/
  COD, ward GRID3-supplementary-only, near-border disagreement expected and
  not a data error) — self-serve for any partner or internal viewer without
  needing an email explanation each time this comes up.
- **Partner workbooks** (`1_sampling/scripts/build_partner_dc_packages.py`,
  a separate project/repo — actioned there via a handoff prompt, see
  `field_verify/prompt_for_1_sampling_session.md`): rather than a generic
  source note, the plain `Ward` column was split into two —
  `Ward (GRID3)` (always populated) and `Ward (OCHA/COD)` (populated only
  in the 3 NE states, the only region where OCHA/COD publishes its own
  admin-3 product at all; blank elsewhere). `LGA` itself was left unchanged
  since it's unambiguous — always OCHA/COD, no second source exists to
  disambiguate against. Same source-labelling applied to each point type's
  KML placemark description. Both the workbook and KML changes are on
  every partner's package going forward, not just SCI's, pre-empting the
  same question from other partners rather than waiting for it. Uncommitted
  in `1_sampling` as of this writing — see that project's own git history
  for when it lands.

Broader all-partner communication (email + regional example maps, beyond
the dashboard/workbook changes above) also drafted this round:
`field_verify/response_to_all_partners_draft.md` and three worked examples
(`field_verify/sci_boundary_discrepancy_example_map{,2,3}.png` — Katsina
×2, Zamfara ×1, chosen to show the pattern isn't localized to one border).

## Update (2026-08-14) — real data wired in; mock data now the fallback only

Real submissions are flowing from data collection. The data officer running
the cleaning workflow (`cleaning/MSNA_Data_Cleaning/`) isn't changing their
process for the dashboard's benefit, so this integration works entirely
from their existing daily outputs rather than asking for a different
export. Not deployed this round — local testing only, per standing
instruction (`source("deploy_dashboard.R")` when you're ready).

- **`cleaning/real/prep_real_submissions.R`** (new) — reads the data
  officer's daily `anonymised_data/*.xlsx` (most recent by date-in-filename;
  it's a full cumulative re-export each day, not a delta), repairs the
  known NG037/Zamfara tool bug (missing `${...}` wrapper drops
  `sample_point_id`/`cluster_id` for that state — reconstructed from the
  per-state columns, same fix already used by the data officer's own
  progress-monitoring package, see below), applies the same
  methodology-aware duplicate detection (non-IDP: shared
  `non_idp_point_id`; IDP: shared `idp_hh_number_from_listing` or
  `idp_walk_position` within a cluster; first submission kept), translates
  admin pcodes to names via our own WORKING sampling frame, and writes
  `data/real_submissions.csv` + `data/real_meta.rds` matching the exact
  same column contract `cleaning/mock/` already established — no
  `dashboard_app/` module needed to change to consume it.
  - **`global.R` now prefers real data when present**, falling back to
    mock only if `data/real_submissions.csv` doesn't exist (local
    dev/demo). Same `IS_MOCK_DATA` flag already drove the sidebar's "Mock
    data" warning banner, so that banner now correctly disappears once
    real data is in play, with no separate flag needed.
  - First run: 309 raw rows in (matches the data officer's own progress
    package's count for the same day), 269 cleanly matched to a sampling
    frame point, 40 flagged as GPS outliers (>500m from their matched
    point — threshold's a starting guess, adjust `GPS_OUTLIER_THRESHOLD_M`
    in the script if that's too tight/loose), 23 duplicates, 72/309 with
    at least one quality flag.
  - **Found and reused a second resource while exploring the cleaning
    output**: `cleaning/MSNA_Data_Cleaning/MSNA_2026_Progress_2026-08-14/`,
    an existing progress-monitoring workbook package (`R/
    01_msna_progress_monitoring.R`) that already implements the NG037 fix
    and the same duplicate-detection rules — origin/ownership unconfirmed
    (you weren't sure either), so treated as a found reference to validate
    against and adapt from, not a dependency this script relies on
    continuing to be maintained or re-run.
  - **One deliberate divergence from that reference script — decided,
    keeping current behaviour (2026-08-14)**: it hard-deletes any
    submission under 20 minutes (`min_duration_min`); this dashboard's
    `flag_duration_outlier` instead just *flags* short interviews rather
    than dropping them from achieved counts. Confirmed: keep flag-only —
    this dashboard's "achieved" numbers will run slightly higher than that
    package's "valid" numbers whenever a short-but-real interview exists,
    and that's accepted.
  - **GPS coordinates are not in the anonymised export** (stripped before
    anonymisation, presumably for privacy) — only the pre-computed
    `dist_btn_sample_collected` distance survives per-submission. Raw
    lat/lon is recovered for the ~59 submissions that also appear in
    `checking/internal_audit/spatial_duplicate_audit_*.xlsx` (that file
    incidentally carries coordinates for whatever it flags as spatially
    proximate); every other row's `latitude_submitted`/
    `longitude_submitted` is NA. Doesn't affect the Coverage Map, which
    plots the sampling frame's own cluster coordinates, not submitted GPS.
  - **Four LGAs assigned to more than one org — resolved, see
    "Update (2026-08-15)" below** (Isa, Sabon Birni, Tangaza, Zuru).
  - **Refugee data**: not collected this round (confirmed) — real
    `interview_outcome` only ever takes `completed`/`consent_refused`, no
    `ineligible_refugee` path. Nothing to remove from `dashboard_app/`
    itself — no module ever referenced that outcome value in the first
    place.
- **Ward filter disabled** (`app.R`) — the real tool's admin3 field uses
  boundaries the data officer's own package documents as "unofficial,
  does not nest inside the LGA layer," so real submissions carry no
  usable ward value (`admin3_submitted` is always NA from the adapter
  above). Removed the `f_ward` picker and its cascade/reset-button/
  cross-filter wiring from `app.R`; `effective_lgas()` is now just
  `input$f_lga`. `wards_sf`/`ward_to_lga`/`get_ward_choices()` are left in
  `global.R` untouched (and still covered by `tests/smoke_test.R`'s direct
  unit tests) in case a reliable ward source shows up later — the map's
  optional "Ward boundaries" reference overlay (GRID3, off by default,
  unrelated to submitted data) is also untouched.
- Full `tests/smoke_test.R` suite passes against real data, and a live
  app boot (HTTP 200) confirmed no errors reading it.

## Update (2026-08-15) — NG037 bug: evidence for the tool team; IRC/LHI coverage fixed

**NG037/Zamfara tool bug — proof pack delivered.** Data officer asked for
concrete evidence to hand the tool owner, beyond "trust me." Two-part
verification, both against the live files (not hypothetical):
- **In the tool**: `cleaning/MSNA_Data_Cleaning/kobo_tool/
  NGA2605_MSNA_Kobo_10082026.xlsx`, sheet `survey`, row 42
  (`idp_cluster_id`) and row 52 (`non_idp_point_id`) — both `coalesce()`
  chains wrap every state's reference in `${...}` except the very last
  argument (Zamfara's), which is bare and therefore never actually read.
- **In the data**: cross-checked against the `main` sheet of the
  anonymised export, filtered to the correct pop_type first (see below) —
  100% of Zamfara's non-IDP submissions have a blank `non_idp_point_id`
  (62/62) against 0% for every other fielded state (NG021 0/162, NG034
  0/46); same pattern on the IDP side (11/11). The value isn't actually
  lost — it's sitting untouched in the per-state column
  (`sample_point_NG037_non_idp` / `idp_cluster_NG037`) the broken formula
  should have picked up.
- **False alarm caught along the way, worth documenting**: a first,
  broader check (no pop_type filter) appeared to show *several* states
  with blank `non_idp_point_id` — NG021, NG032, NG034 as well as NG037.
  Not a wider bug: `non_idp_point_id` is only ever populated on non-IDP
  submissions by design, so every IDP row in every state shows blank
  there regardless (IDP submissions link via `idp_cluster_id` instead).
  Once filtered to `sample_pop_type_filter == "non_idp"` before checking
  that specific column (and the mirror check for `idp_cluster_id` filtered
  to `idp` rows), only Zamfara remains broken. Flagging this so the same
  false positive doesn't recur — always slice by pop_type first when
  checking either of these two fields.

**IRC/LHI coverage — fixed.** Isa, Sabon Birni, Tangaza, and Zuru were
carried in `input_data/partner_coverage/partner_lga_assignment.csv` under
a combined `irc_lhi` code, inherited from `Partnerscoverage.xlsx`'s own
"IRC/LHI" column. Confirmed with you: IRC and Legacy Humanitarian
Initiative (LHI) are genuinely separate organisations with their own
enumeration teams who've agreed, at a coordination level, to jointly
share the workload in these 4 LGAs without yet deciding how to split
individual sample points between themselves — so `irc_lhi` was never
going to match a real submission (confirmed against the live tool: the
enumerator's own `org_id` question, `l_org_id`, is a single-select
listing `irc` and `lhi` as two distinct real values; there is no
`irc_lhi` option to select). Any IRC or LHI submission in those 4 LGAs
would have silently fallen through to `"other"` in every filter and
report the moment either org started fielding there — hadn't happened
yet (current real data is coopi/crs/drc/intersos/malteser/sci only), so
this was a latent bug, not yet a visible one.

Fixed at the source, not by patching the CSV: `cleaning/prep/
prep_partner_lga_assignment.R` now expands any `irc_lhi`-tagged row into
one `irc` row and one `lhi` row (see its header comment for the full
rationale) before writing `partner_lga_assignment.csv` — reran it,
7 `irc` + 4 `lhi` rows now cover those LGAs correctly (previously 3 `irc`
+ 0 `lhi`). `ORG_LABELS` (`global.R`) split accordingly: `lhi` = "Legacy
Humanitarian Initiative (LHI)" added, the fictional `irc_lhi` entry
removed. `cleaning/mock/generate_mock_submissions.R`'s `ORG_CHOICES` list
updated the same way and mock data regenerated, so the mock-data fallback
path stays consistent with the same org codes.

**New: "jointly covered" transparency on the Partner Report.** Since
achieved counts for a shared LGA already reflect *every* covering org's
combined submissions (progress is computed per LGA×pop_type stratum, not
split by org — this was already true before today, and is the right
behaviour here per your explanation of how the sharing actually works
operationally), a partner viewing their own report had no way to tell a
shared LGA's number apart from one they'd achieved alone. Added:
- A new **"Shared with"** column (Partner Report table, Excel export) —
  blank for normal LGAs, lists the other covering org(s) by name for the
  4 shared ones.
- A caption under the Partner Report table explaining that shared-LGA
  Achieved figures are combined, not partner-specific.
- A "Jointly covered with another partner" note in the PDF report's focus
  panel, for the LGAs where it applies.
- `global.R`: `shared_coverage_adm2` (which LGAs are shared) and
  `coverage_orgs_by_adm2` (LGA → covering orgs) — new lookups feeding all
  of the above via `partner_progress_by_lga()`'s new `shared_with` column.

Verified: `partner_progress_by_lga("drc")` and `("irc")` both now show
Isa with the correct co-covering orgs listed; `("lhi")` shows Zuru
correctly too. Full `tests/smoke_test.R` suite re-passes; live app boot
(HTTP 200) confirmed. Not deployed — local only, per standing instruction.

## Update (2026-08-15b) — go-live review pass

Full pass through pre-go-live feedback. Re-tested throughout (full smoke
suite + live boot, HTTP 200); not deployed yet — will redeploy once you
confirm this pass looks right.

**Sampling frame check.** Compared `input_data/sampling_frame/` against
`1_sampling/output/data/data_collection/` (the location you pointed at) —
byte-identical, already up to date. The number mismatch you saw wasn't a
stale-frame problem: the Home page's intro paragraph had a **hardcoded**
`31,051` written when the page copy was first drafted, while "At a
glance" computed the *live* total from `strata_frame` (`31,506`) — the
two had simply drifted apart from each other. Fixed properly: `global.R`
now computes `TOTAL_PLANNED_INTERVIEWS` (`31,506`) and
`TOTAL_COVERED_LGAS` (`176`) once, and every place that cites either
number — intro paragraph, "At a glance", "Today's snapshot" — reads from
those same two variables, so they can't drift apart again.

**Filters:**
- Date range now starts from the true earliest submission date
  (`FIELDING_START` is computed from the data itself, not hardcoded) —
  same value used by the sidebar's date picker and the "Reset all
  filters" button.
- **Fixed the "doesn't auto-restore" behaviour** — deselecting a Region
  correctly narrowed State (as before), but re-selecting it back left
  State stuck at the narrowed set instead of automatically restoring the
  states it had removed. Root cause: `smart_selection()` always tried to
  *preserve* a filter's current selection, with no way to tell "the user
  chose this deliberately" apart from "this filter just got narrowed as
  a side effect of something else changing." Fixed with a new
  `resolve_selection()` (`app.R`) that compares a filter's current value
  against what was last sent to it by our own code
  (`filter_ui_state`): if they still match, nothing's happened to it
  directly, so a parent/sibling change auto-follows to the full newly
  available set; if they differ, the user genuinely picked something
  themselves, so the manual narrowing is preserved exactly as before.
  Applied to all 5 cross-filtering observers (Region/State/LGA/Partner/
  Pop. group). New regression test in `tests/smoke_test.R` confirms
  State's selection is fully restored after Region is narrowed then
  widened back, with the user never touching State directly.
- **Fixed the Partner filter dropdown being cut off** — bootstrap-select
  (which `shinyWidgets::pickerInput` wraps) was rendering its dropdown
  panel nested inside the sidebar, so the sidebar's own stacking context
  clipped the right-hand tick marks behind the main page content once
  the panel extended past it — worst on Partner since it's furthest down
  the filter list. Fixed with `container = "body"` (`picker_opts()`,
  `app.R`), which renders the dropdown as a direct child of `<body>`
  instead, clear of the sidebar's context entirely.

**Home page:**
- Data-source sentence is now conditional on `IS_MOCK_DATA` — reads
  correctly for whichever data source is actually loaded, instead of
  permanently describing mock data.
- Removed the `field_verify/` reference (internal-only working files, not
  useful to any other viewer) and the "first draft" disclaimer paragraph
  — going live today.
- **"At a glance" expanded**: achieved-to-date + % of target, target
  split by population group (Non-IDP / IDP), and the state/region list —
  on top of fixing the target-interviews number. Fielding window now
  shows the real first collection date through **11 Sep 2026** (updated
  end-of-collection estimate, was a placeholder 26 Aug).
- The internal-audience bullet no longer name-drops Analysis-menu tabs
  while that menu is hidden (see below) — resurfaces automatically if
  `SHOW_ANALYSIS_TAB` is flipped back on.

**Coverage Map:**
- **IDP site points now always render above non-IDP hexagons.** Both are
  vector layers sharing Leaflet's default `overlayPane`, where z-order
  follows *draw* order, not code registration order — so whichever layer
  most recently redrew (via its own `clearGroup`+re-add cycle) could end
  up on top, regardless of which observer was written first. Fixed with
  a dedicated `idpSitesPane` (zIndex 450, above the default 400) applied
  to both the "Cluster status sites" and "PSU sites (reference)" circle
  marker layers — order-independent, they're now always above hexagon
  fills.
- **Partner coverage added to every popup** — LGA polygons, cluster
  hexagons, and cluster/site points — via a new `partner_coverage_label()`
  helper (`global.R`) built on the same `coverage_orgs_by_adm2` lookup
  used for the Partner Report's "Shared with" column.
- **New page-local status filter** (Not started / In progress /
  Complete checkboxes next to the LGA/cluster toggle) — filters both map
  views, independent of the sidebar.
- Context caption now also notes: "White areas are within the assessment
  but have been excluded and/or not selected for sampling."

**Data Quality**: flagged-submissions table now has a dedicated Yes/No
column per flag type (GPS outlier, Duration outlier, HH size mismatch,
LGA mismatch, Duplicate) instead of just Match quality/HH mismatch —
DT's column-header dropdowns (`filter = "top"`) already give per-column
filtering for free once a column is a factor, so this was the more
capable fix vs. a bespoke filter widget: you can filter to just GPS
outliers, or GPS outliers + duplicates together, directly from the table
headers.

**Data Export**: confirmed the 309-vs-286 difference you flagged is not
a bug — 309 is *every* submission currently in scope (raw, including the
23 flagged duplicate copies), 286 is completed-and-non-duplicate only
(the "achieved" figure used on Home). Added a caption on the Data Export
tab explaining the distinction so it's not confusing again.

**Analysis menu**: hidden from the navbar for today's go-live
(`SHOW_ANALYSIS_TAB <- FALSE` in `global.R`) — code/modules untouched,
just not linked from the UI. Flip the flag back to bring Enumerator
Performance / Data Integrity Checks / Sample Representativeness back.

**Footer**: "v1 draft, built against mock data" text removed.

**In-depth numbers audit** (requested given the errors already found this
round): checked every hardcoded-vs-live-computed number (the `31,051` bug
was the only instance, now fixed via `TOTAL_PLANNED_INTERVIEWS`/
`TOTAL_COVERED_LGAS`), then traced every place the dashboard reports an
"achieved" count against a target. Found a real structural
inconsistency: `compute_progress_by_stratum()` (driving the LGA table,
Partner Report, Coverage Map, Progress Overview's "% of target") correctly
requires completed + non-duplicate + **matched to a sampling-frame
point**, but Home's snapshot numbers and Progress Overview's own
"Interviews achieved" KPI/trend chart only checked completed +
non-duplicate, with no matched requirement. Currently invisible (0
unmatched submissions in the data today, so the numbers coincide), but
would silently diverge — achieved-count tiles running ahead of the %
shown right next to them — the moment any submission fails to match.
Compounding it: the trend chart's "Unmatched" bucket was keyed off
`pop_type` not being `idp`/`non_idp`, which worked for the mock data's
simulated older tool (blank pop_type on an unmatched row) but not the
real tool, where `pop_type` is a required field always answered
regardless of match success — so a real unmatched submission would have
been silently absorbed into the Non-IDP/IDP bars and the "Cumulative
achieved" line instead of flagged.

Fixed at the root: `global.R` gained `is_achieved(df)` — the one
definition of "counts toward target" (completed, non-duplicate, matched)
— used by `compute_progress_by_stratum()` and now also by Home's three
achieved counts and `mod_representativeness.R`'s achieved-sample
comparisons. Progress Overview's KPI tile now reads `achieved_n` from
`filtered_stratum()` directly instead of recomputing its own looser
count; its trend chart's Unmatched bucket now checks
`is.na(matched_survey_id)` first, and the cumulative "Achieved" line
excludes that bucket (still shown as its own bar for visibility, just no
longer folded into a number it doesn't belong in). Verified this
doesn't change any number today (0 unmatched currently) — it's a
forward-looking correctness fix, not a visible-today one. Checked and
deliberately left alone: Enumerator Performance and Data Integrity
Checks correctly count *all* non-duplicate submissions regardless of
match status (an enumerator's activity/quality shouldn't be undercounted
just because a submission failed post-hoc matching) — those aren't
target-achievement numbers, so they were never subject to this bug.

## Update (2026-08-15c) — Ward filter re-enabled

Investigated ward reintroduction and found the 2026-08-14 assumption was
wrong: the real tool's `admin3` field isn't unusable — it's a genuine
per-submission ward selection, just driven by an external KoBo media
file (`MSNA_2026_admin3.csv`, a `select_one_from_file` question) that
isn't visible in the XLSForm workbook or its `choices` sheet, which is
why it looked empty on first pass. You pulled that file from the KoBo
project's Media Files and it's now at `input_data/MSNA_2026_admin3.csv`.

Checked it thoroughly before wiring anything in: all 45 distinct ward
codes appearing in the real export are covered by the file (100%), and
— more importantly — the ward *names* it carries match our own
GRID3-based `adm3_name` 1:1 for every ward checked (55/55), even though
the two use completely different pcode schemes (the tool's codes are a
mix of formats like `"43407"` and `"ADSDSA01"`; our frame's are GRID3's
own 5-digit scheme). Matching by name rather than pcode, this is a safe,
verified join — not a guess.

**`cleaning/real/prep_real_submissions.R`** now joins `admin3` through
this file's `label` column and populates `admin3_submitted` for real
(was hardcoded NA). **`app.R`**'s Ward filter (picker, cross-filter
observer, `effective_lgas()` narrowing, reset-button wiring) is fully
restored — it had been removed entirely on 2026-08-14, not just hidden,
so this re-adds it against the current filter architecture, including
the new touched-state auto-restore behaviour from earlier in this round
(the Ward filter didn't exist yet when that was built, so it needed
wiring in specifically for Ward too, not just inherited for free).

**Worth flagging**: the `cleaning/real/` folder (this script, plus the
`NG037_tool_bug_evidence.md` write-up) had disappeared from disk
entirely between sessions today — never committed to git (nothing in
this repo has been committed beyond the initial scaffold), so there was
no history to recover from. Rebuilt both from this conversation's own
record verbatim, with the ward translation added on top — flagged to you
in case it points at a sync issue worth checking (OneDrive?), but no
actual work was lost.

Also fixed a test that assumed mock-data-only behaviour:
`tests/smoke_test.R`'s GPS-duplicate-detection check asserted the
currently-loaded data always has at least one exact-coordinate
duplicate — true for mock (deliberately injected) but not guaranteed for
real data, and did in fact flip to zero between two adapter re-runs
today as the underlying `spatial_duplicate_audit` file's GPS-recovery
coverage changed. Test now checks `find_gps_duplicate_groups()` against
mock data specifically for the pass/fail assertion, and reports the
real-data count informationally alongside it.

Full smoke suite passes (including new coverage of the restored Ward
filter); live boot confirmed (HTTP 200, Ward filter present in the
served page). Not deployed — local only, per standing instruction.

## Update (2026-08-15d) — fixed a real "filters keep resetting" bug in the new auto-restore logic

Reported right after the round above: filters were visibly resetting on
their own. Root cause was a genuine design flaw in the auto-restore
feature added earlier the same day (2026-08-15b), not a leftover from
the original 2026-08-03c fix.

**The bug**: `resolve_selection()` decided whether a filter had been
manually narrowed by comparing its current value against
`filter_ui_state[[key]]$selected` — but that field gets overwritten to
match whatever was just computed *every time* `sync_filter_input()`
sends an update, regardless of whether that computation came from
preserving a manual narrowing or from auto-following to everything. So
the very first time a manual narrowing was correctly detected and sent,
the system immediately forgot it was ever manual — the comparison
baseline had just been resynced to match. On the *next* recompute
triggered by any unrelated sibling filter, the current value now
matched that baseline again, read as "untouched," and snapped straight
back to selecting everything. The touch signal survived exactly one
comparison cycle before being erased by the act of reconciling it —
that's what "constantly resetting" was.

**Fixed** with a persistent `filter_touched` flag (`app.R`) per filter,
completely independent of `filter_ui_state`: a dedicated
`observeEvent()` per filter watches only that filter's own input and
sets the flag TRUE the first time its value doesn't match what we last
told the client to have (i.e. a genuine client-side change, not our own
`update*Input()` echoing back) — and once TRUE, it stays TRUE regardless
of how many times the choices/selected get reconciled afterward, until
"Reset all filters" clears every flag back to FALSE.

Also fixed, found while chasing this: `sync_filter_input()`'s own
"should I bother sending an update" check had the same class of
staleness problem, comparing against the cached record instead of the
live client value — harmless on its own, but capable of sending
redundant identical-value updates that (per the original, much older
"constant refreshing" bug) still fire a change event and re-invalidate
the graph for no real reason. Now compares against
`isolate(input[[input_id]])` directly.

New regression test (`tests/smoke_test.R`) simulates exactly the
reported pattern — manually narrow Partner, then fire several unrelated
Pop. group toggles in a row — and asserts the narrowing survives and the
update-call count stabilizes rather than climbing. Full suite passes;
live boot confirmed (HTTP 200).

## Update (2026-08-15e) — comprehensive post-fix review

Requested after the filter-reset fix above: a full pass across the whole
workflow and dashboard for functionality/inconsistencies, not just the
one bug. Checked (all clean unless noted):

- **Package/dependency consistency** (`renv::status()`): the dashboard's
  own packages (shiny, DT, leaflet, plotly, etc.) are all properly
  recorded/installed/consistent. `renv::status()` does flag a long list
  of cleaning-side packages (`cleaningtools`, `impactR4PHU`, `devtools`,
  etc.) as inconsistent — these belong to `cleaning/MSNA_Data_Cleaning/`'s
  own scripts, unrelated to the dashboard, pre-existing (not touched this
  session), and outside this project's scope to fix.
- **Empty/edge-case filter results**: every module (`mod_map`,
  `mod_table`, `mod_quality`, `mod_progress`, `mod_export`,
  `mod_partner_report`) tested directly against zero-row filtered data —
  all degrade gracefully (KPIs show "0" or "-", tables/charts render
  empty, nothing errors).
- **A real, reproducible Coverage Map edge case found and fixed**:
  narrowing to Zuru (a real LGA with a non-IDP target but no IDP stratum
  at all, and zero real submissions yet — an asymmetric one-pop-type-
  empty case) crashed when reproduced through the full 10-module app in
  a single `testServer` session. Traced conclusively to a
  `testServer`+`leafletProxy` test-harness limitation, not an app bug:
  the underlying data computation is correct (verified with no NAs or
  malformed geometry), a raw `leaflet()`+`addPolygons()` call on that
  exact data succeeds, and `mod_map_server` in complete isolation with
  the same real data succeeds fully including switching to cluster view
  — the crash only appeared when co-mounting all 10 modules together
  under simultaneous reactive load, which a real browser's websocket
  connection doesn't force into the same synchronous path. Live
  browser-boot checks against the full (larger) unfiltered dataset never
  hit this either. `tests/smoke_test.R` now covers this exact data shape
  via the isolated (reliable) form instead of the flaky full-app one.
- **Stale text/comments**: `mod_home.R`'s file header still called the
  intro "placeholder... meant to be refined later" after it had already
  been refined multiple times this round — updated. `app.R`'s header
  still described the app as "v1, built against mock data" — updated to
  reflect the real-data-first, mock-fallback reality.
- **Mock-data fallback path**: verified end-to-end by temporarily moving
  `data/real_submissions.csv`/`real_meta.rds` aside, re-running the full
  smoke suite (correctly fell back to mock, `IS_MOCK_DATA` banner
  present, all modules render against the ~12.7k-row mock set) and a
  live boot (banner confirmed present in the served page), then
  restoring the real files.
- **Deploy script** (`deploy_dashboard.R`): reviewed against the current
  file layout — every `input_data/`/`data/` path it bundles still
  exists and matches what `global.R` actually reads. Not run (no deploy
  requested).
- No dangling references to removed things found (`field_verify`,
  `irc_lhi`, old hardcoded fielding dates, the old `31,051` figure) —
  all previously fixed and none have crept back in.

Full smoke suite passes; live boot confirmed (HTTP 200). Nothing
deployed — local only.

## Update (2026-08-15f) — deployed; fixed a real shinyapps.io/terra incompatibility along the way

Deployed all of the above to <https://impact-nga-jp.shinyapps.io/dashboard_app/>.
First attempt failed — not from anything in our own code, but from an
external package/platform incompatibility:

**The problem.** `leaflet` (the Coverage Map's own mapping library) hard-
depends on `raster (>= 3.6.3)`, which depends on `terra`. The `terra`
version installed on this machine (1.9-34, very recent) needs GDAL ≥3.8
for its multidimensional-array support, but shinyapps.io's current build
image only ships GDAL 3.4 — so `terra` failed to compile during the
build step (`GDALMDArray::AsClassicDataset` — the GDAL function terra
calls — changed its signature between those versions). This is a known,
[externally documented issue](https://forum.posit.co/t/deployment-fails-on-shinyapps-io-because-of-terra/214331)
affecting other shinyapps.io users too, not something specific to this
project.

**Fix.** Pinned `terra` to `1.8-93` — the last version published before
the GDAL 3.8 requirement, confirmed by the community thread as working
on shinyapps.io's current image. Installed it locally (`remotes::
install_version("terra", version = "1.8-93")`, built from source via
Rtools — took a couple of retries due to this project's OneDrive-synced
folder intermittently locking files mid-compile, a known quirk of this
environment, not a terra/install problem) so the deploy's dependency
snapshot requests that version instead of 1.9-34. Confirmed via a
generated manifest before redeploying that `terra 1.8-93` was actually
being requested, and that `leaflet`/`raster`/`sf` all still load
correctly against it.

**Redeployed successfully.** Verified via `rsconnect::showLogs()` (clean
startup, only the pre-existing benign "GeoPackage version may only be
partially supported" GDAL notices) and a live HTTP check against the
deployed URL (200 OK, Ward filter present, correct `31,506` target
figure, mock-data banner correctly absent). No changes to any of our own
`dashboard_app/` code were needed for this — purely a dependency-version
fix.

Live at: <https://impact-nga-jp.shinyapps.io/dashboard_app/>

## Update (2026-08-16) — respondent PII removed from Data Export; redeployed

Flagged after go-live: the Data Export tab's "Filtered submissions"
CSV/Excel/preview passed `filtered_subs()` straight through with every
column, since (unlike every other tab, which always names the specific
columns it needs) it never selected a subset — so it silently carried
`resp_gender`, `resp_age`, `resp_hoh_yn`, `hoh_gender`, `hoh_age`,
`hh_size`, and (flagged separately, arguably the most identifying of all
since it pinpoints the household outright) raw submitted GPS
(`latitude_submitted`/`longitude_submitted`). Combined with a row's own
date/enumerator/LGA/ward, fields like these can narrow a small
settlement's population down to very few candidates — a real
respondent-protection issue, not a cosmetic one.

**General rule established, not just this one fix**: nothing that could
make a specific respondent/household more identifiable belongs in a
*row-level* view or export — the same fields are completely fine in
*aggregate* form (a histogram, a %, a group mean), where no single row
is recoverable from the output. This is why Sample Representativeness's
histograms/pyramid/group means and Data Integrity's Whipple's Index
(both under the currently-hidden Analysis menu) were deliberately left
untouched — they only ever compute across many rows at once, never
expose one row's own combination of values, and were already safe
before this change.

Implemented as a single, durable, extensible mechanism rather than a
one-off patch: `ROW_LEVEL_PII_COLUMNS` (`global.R`) is now the one place
this list lives, and `strip_row_level_pii()` is the one function that
applies it — used by `mod_export.R`'s preview, CSV, and Excel outputs
(the only place in the dashboard that does a raw row-level dump).
Extending the rule to any future similarly-identifying field is a
one-line addition to that list, not a per-module hunt. Added a
permanent regression test (`tests/smoke_test.R`) that exercises the
export module's own `exportable_subs()` reactive directly and asserts
none of the listed columns survive, catching any future regression in
the real code path rather than a reimplementation of it.

Verified: `filtered_subs()` itself (used internally by every other
computation — duplicate/match-quality counts, etc.) is untouched, still
carries every column; only the export-facing copy is stripped, and row
*count* is unaffected (still every submission in scope, just fewer
columns). Full smoke suite passes, live boot confirmed (HTTP 200).
Redeployed to <https://impact-nga-jp.shinyapps.io/dashboard_app/>.

## Update (2026-08-16b) — full filter-performance diagnosis: found and fixed the real bottleneck

Reported: filters causing "big delays and lags" in general functionality.
Asked for a proper diagnosis, not a guess, with time to test thoroughly —
not deployed yet (per your instruction; this is purely a responsiveness
fix, no behaviour change to what filters do or how they connect).

**Method.** Rather than guess, instrumented and directly measured the
actual reactive graph via `shiny::testServer()` — timing/counting real
function calls (`compute_filter_choices()`, `compute_progress_by_stratum()`,
`leafletProxy()`, DT/plotly construction) triggered by realistic single
filter clicks, rather than reasoning about what's *probably* slow. Three
hypotheses were tested and ruled out before finding the real cause:

1. **Filter-choice computation itself** (`compute_filter_choices()`):
   ~1ms/call. Not the bottleneck.
2. **Cascade "rounds"** — the mutual cross-filter design (Region/State/
   LGA one-directional, Partner/Pop.group fully mutual with everything)
   was suspected of needing multiple reactive flush rounds to settle,
   each re-triggering every downstream computation. Measured directly:
   a single filter change (Partner, Region, or Pop.group — including the
   two most densely-connected filters) triggers each *other* filter's
   choice recompute exactly **once**, not repeatedly. Not the
   bottleneck.
3. **`compute_progress_by_stratum()` / DT tables / plotly charts**:
   12-20ms, 17ms, ~1ms respectively — checked even at mock-data scale
   (12,697 rows, ~40× today's real volume) to make sure this wouldn't
   become a problem as real data grows. All trivial.

**The actual cause**: the **Coverage Map**. Its layer redraws
(`leafletProxy()` — real polygon/point geometry: ~2,535 hexagons + ~808
IDP sites + boundaries) are plain `observe()` blocks, not `render*()`
outputs — so unlike every other tab, which correctly only computes while
its own tab is the visible one (Shiny's default `suspendWhenHidden =
TRUE`), the map's layer-update observers have no visibility awareness at
all and were firing on **every single filter change, from any tab,
regardless of whether the Coverage Map was even being looked at**.
Measured directly: a single filter change triggered 4 `leafletProxy()`
calls taking **~1 second server-side alone** — before network transfer
of that geometry and the browser's own Leaflet re-render are even
counted, which, given the in-memory payload sizes involved (hexagons
~2.7MB, wards ~5.6MB), are very likely larger costs still. This
unconditional redraw is what a user filtering from, say, the Progress
Overview or Data Quality tab was actually waiting on every time,
completely invisibly (they'd never see the map that was redrawing).

**Why this existed**: `output$map`'s `suspendWhenHidden = FALSE` (set
earlier to fix a real "blank map on first visit" bug — Shiny suspends
`render*()` outputs on hidden tabs, so the base widget didn't exist yet
client-side when the layer observers first tried to draw onto it) was
necessary for the *base widget*, but had the side effect of never
limiting the separate, plain-observer-based *layer redraws* to only
when relevant — those were never suspend-controlled at all, by either
the old bug or its fix.

**Fix** (`app.R`, `R/mod_map.R`): `page_navbar()` now has `id =
"main_nav"`, giving the server a `map_tab_active` reactive
(`identical(input$main_nav, "Coverage Map")`) passed into
`mod_map_server()`. Each of the 7 filter-driven `leafletProxy()`
observers now starts with `req(map_tab_active())` — reading it *first*
means it's the *only* dependency the observer has while hidden (Shiny
re-establishes an observer's dependencies fresh on every run, based only
on what it actually read before completing or stopping), so filter
changes elsewhere cost nothing until the user actually visits the tab.
The moment `map_tab_active()` flips true, the observer re-runs, `req()`
passes, and it reads the (already-current, cached) reactive — which
becomes a tracked dependency again for as long as the tab stays
visible. Net effect: zero redraw cost while hidden, exactly one fresh
redraw the instant the tab becomes visible (verified this doesn't miss
filter changes that happened while hidden — the redraw reflects
whatever's current, not stale), and completely normal live updates
while it stays visible. The `map_view` toggle (LGA/cluster radio) and
the base-widget `suspendWhenHidden = FALSE` fix are both untouched —
this only changes *when* the expensive per-filter layer redraw happens,
not the "blank map" mechanism or anything about how filters connect to
each other.

**Bonus side effect**: since the map tab is no longer the very first
tab, this also means a user who never visits Coverage Map at all no
longer pays for ~3,300 geometries' worth of redraw at every single
filter interaction for a tab they never look at — not just "less often,"
but never, for that whole session.

**Verified**: new permanent regression test
(`tests/smoke_test.R`) simulates exactly this — filter change while on
Home (0 `leafletProxy()` calls), switch to Coverage Map (redraw fires),
filter change while on Coverage Map (redraw fires normally, no
regression). Existing map tests (including the Zuru asymmetric-empty-LGA
edge case) still pass via a default `map_tab_active = reactive(TRUE)`
fallback for callers that don't pass one (module-level isolated tests).
Full smoke suite passes; live boot confirmed (HTTP 200). **Mutual
cross-filtering is completely unchanged** — Region/State/LGA/Ward/
Partner/Pop. group still narrow each other exactly as before; this fix
only touches when the map redraws, nothing about filter logic itself.

Not deployed — this is a local, tested improvement per your instruction
to take the time needed rather than ship immediately; redeploy whenever
you're ready.

## Update (2026-08-16c) — real cross-filter bug: toggling a filter off/on didn't fully restore

Reported: removing NW from the Region filter then re-adding it left
Planned Surveys at ~27k (should be the full ~31.5k) and LGAs at 156 of
156 (should be 176) — but "Reset all filters" correctly returned to the
full 31.5k / 176 LGAs. Asked for a full diagnostic, a fix across the
whole filter cascade (not just Region — State/LGA were suspected too),
then a redeploy.

**Diagnosis had three layers, each ruled in/out by direct instrumented
testing, not guesswork:**

1. **Stale sibling reads.** The per-filter cross-filter observers read
   sibling filters via `input$f_x`, which only reflects the client's
   *previous* round-trip value inside a single reactive flush — combined
   with `sync_filter_input()`'s "only send if it actually changed" guard,
   a filter recomputed mid-cascade with a stale sibling value could end
   up sending a wrong-but-self-consistent result, which then never got
   corrected because the (still-wrong) value matched what was already on
   record as sent. Fixed by introducing `filter_ui_state`, a
   `reactiveValues` store that both our own sends *and* genuine user
   edits update synchronously — no network round-trip needed to read a
   sibling's true current value. **Insufficient alone** — LGA still came
   back at 156, not 176.
2. **A real cycle, not a chain.** Region → State → LGA is one-directional
   and resolves fine in registration order, but Pop. group and Partner
   are *mutually* dependent on each other (each narrows the other) — and
   LGA depends on Partner, while Partner is registered after LGA. No
   single fixed registration order resolves a cycle in one pass.
   Confirmed directly: recomputing LGA with a fresh Partner value gives
   176; with the previous (stale) Partner value it gives 156 — exactly
   the reported bug. **Attempted fix**: loop the 5-dimension recompute up
   to 5 times per observer invocation until stable. This **converged to
   a self-consistent but wrong answer** (state=8, partner=8 instead of
   11/20) — proven with a standalone convergence test — because two
   *untouched*, mutually-dependent dimensions can keep constraining each
   other with stale values indefinitely; a stable fixed point isn't
   necessarily the *correct* one. Rejected.
3. **Final fix — untouched dimensions never constrain siblings.** Each
   filter now has a persistent `filter_touched` flag (true once a user
   manually deviates from "select all," cleared only by "Reset all
   filters"). When computing any filter's available choices, only
   *touched* siblings are passed in as constraints (`only_if_touched()`);
   untouched ones pass `NULL` — i.e. no constraint at all. This provably
   resolves in a single pass with no iteration and no circularity: a
   touched value is always fresh (it only ever changes via a direct,
   synchronously-captured user click), so there's nothing stale left to
   feed back into the cycle.

**Fix applies to the whole cascade**, not just Region — Region, State,
LGA, Pop. group, and Partner are now computed together in one unified
observer (replacing 5 separate ones) using this rule; Ward (which only
ever depends on LGA, never mutually) is unchanged.

**Verified**: full smoke suite passes cleanly, including a new dedicated
regression test that reproduces your exact report — remove NW from
Region, confirm LGAs/target narrow (176→82 LGAs, 31,506→15,558 in the
mock data, closely matching the ~15.5k you saw), re-add NW, confirm both
fully restore to 176 LGAs / 31,506. Also caught and fixed a **test-only**
false failure along the way: an existing "constant resetting" regression
test was reading a call-log value that goes legitimately stale once a
touched filter correctly stops being re-sent (the whole point of an
earlier fix) — traced with a dedicated diagnostic confirming the app's
actual internal state (`filter_ui_state`) was correct throughout while
only the test's bookkeeping was outdated; the test now clears that
bookkeeping at the right point instead of asserting against a stale
value. Live boot confirmed (HTTP 200, clean start). Mutual cross-filtering
behavior itself — every filter narrowing every other — is unchanged;
this only fixes what happens when a touched filter is toggled back
toward "select all."

Redeployed to shinyapps.io.

## Update (2026-08-17) — real data refresh: picked up two missed daily exports

Noticed the dashboard's real data was stale: `data/real_meta.rds` showed
it was still built from the **2026-08-14** anonymised export (309 rows),
even though the data officer's pipeline (`cleaning/MSNA_Data_Cleaning/`)
had since produced full re-exports for both **2026-08-15** and
**2026-08-16** that were never picked up — the 2026-08-15 run of
`prep_real_submissions.R` happened before that day's file existed, and
nothing re-ran it since. `prep_real_submissions.R` already auto-selects
the most recent dated file in `output/anonymised_data/`, so this was a
"just re-run it" fix, not a code change — re-ran it from the
`2_monitoring/` project root:

```r
source("cleaning/real/prep_real_submissions.R")
```

Now using `NGA2605_MSNA_anonymised_2026-08-16.xlsx`: **903 rows** (up
from 309) — 900 completed / 3 consent-refused, 0 unmatched, ward names
100% translated (no regression from the newer KoBo tool version already
in use), 121 NG037 repairs applied, 107 duplicates flagged, 265/903
(29%) carry some quality flag. GPS enrichment picked up the matching
2026-08-16 spatial-duplicate audit automatically (same date-matching
logic). Achieved count: 793 of 31,506 (3%).

**Verified**: full smoke suite passes against the refreshed real data
(global.R prefers real data over mock whenever `data/real_submissions.csv`
exists, so every test above already exercised it) and a live local boot
check succeeded (HTTP 200). No app code changed — this is a data-only
refresh using the existing pipeline exactly as designed.

Also checked `input_data/` for anything else the data officer might have
updated (sampling frame, partner coverage, KoBo tool, admin3 ward list) —
nothing newer than what's already in use; the anonymised submissions
export was the only stale piece.

**Deploy gotcha hit and fixed along the way**: the first redeploy attempt
called `rsconnect::deployApp()` directly (reusing a network-retry
workaround written earlier in the session) and skipped
`deploy_dashboard.R`'s own copy step — the one that copies the top-level
`data/`/`input_data/` into `dashboard_app/data/`/`dashboard_app/input_data/`
before bundling, since shinyapps.io only bundles the `dashboard_app/`
folder itself. That silently re-uploaded `dashboard_app/data/`'s stale
309-row copy (untouched since the previous deploy) instead of the
just-refreshed 903-row file sitting one level up — deploy completed and
went live without error, so nothing surfaced this until manually checked
against the live site. Refreshing that copy first before deploying is
correct process (`deploy_dashboard.R` already does this) — the retry
workaround should always be layered on top of the copy step, never used
standalone. Redeployed correctly the second time: confirmed
`dashboard_app/data/real_meta.rds` showed 903 rows / the 2026-08-16
source *before* upload, and the shinyapps.io deployment record
(`dashboard_app/rsconnect/.../dashboard_app.dcf`) now shows the matching
bundle ID.

Redeployed to shinyapps.io — verified: local pre-upload data confirmed
fresh (903 rows), deployment record's bundle ID matches, live app
returns HTTP 200, and the new container's startup log is clean.

## Update (2026-08-17b) — FACT partner data quality digest (Excel, daily)

Added a new downloadable Excel report ("Download partner digest (Excel)",
Data Quality tab) meant to be shared with FACT — the main field
partner/coordination body — so they can see which partners have data
quality issues to follow up on, without having to build that view
themselves from the raw flagged-submissions table. Explicitly requested
as a **recurring, daily** output, not a one-off, so it's built to the
same standard as the rest of the pipeline: fully commented (see the
header above `build_fact_quality_digest_excel()` in `R/mod_quality.R`),
covered by a permanent regression test, and requires zero extra daily
steps beyond what's already routine — it reads `submissions_raw`
directly, so it's automatically current with whatever the day's
`prep_real_submissions.R` refresh last produced (see the 2026-08-17
entry above); there is no separate script or schedule to maintain for
the digest itself, just click the button after each day's data refresh.

**Three sheets**:
1. **Summary** — headline totals (submissions, flagged, overall flag
   rate) plus the "hasn't started yet" partner list (same one given
   verbally earlier today), so FACT gets both angles — quality issues on
   data received, and partners with nothing recorded yet — in one place.
2. **By partner** — one row per partner with ≥1 submission, sorted
   worst-flag-rate-first so priority follow-ups are obvious without
   FACT needing to sort it themselves: submissions, completed, consent
   refusals, achieved (the dashboard's one definition — completed,
   unique, matched to the sampling frame, same as everywhere else),
   flagged count/rate, and a breakdown by flag type (GPS outlier,
   duration outlier, HH size mismatch, duplicate, off-hours).
3. **Flagged submissions** — full row-level detail across every partner
   (date, state, LGA, enumerator, duration, GPS distance, match quality,
   Yes/No per flag type) for when FACT needs to know *which* submissions,
   not just how many.

**Design decisions worth knowing about**:
- **Cumulative to date, not sidebar-filtered** — same convention as the
  existing Partner Report exports (`mod_partner_report.R`): a report
  handed off for follow-up should reflect everything so far, regardless
  of whatever date range happened to be selected in the sidebar when it
  was generated.
- **PII-stripped** — the detail sheet runs through the same
  `strip_row_level_pii()` used by the Data Export tab, so it never
  carries respondent-identifying fields (age/gender/household
  size/exact GPS), only what's needed to locate and follow up on a
  submission (date, LGA, enumerator ID, flag type).
- **"Other / unassigned" excluded from the "hasn't started" list** — that
  code isn't a real organisation; it's `global.R`'s `coalesce()` fallback
  for the one LGA with no confirmed partner match in
  `partner_lga_assignment.csv` (see `filter_base`). Including it would
  have pointed FACT at a partner that doesn't exist.

**Verified**: new permanent regression test in `tests/smoke_test.R`
checks sheet structure, that per-partner totals reconcile exactly with
`submissions_raw` (achieved/flagged sums), the sort order, PII exclusion,
and the "other" exclusion — so a future data refresh or column rename
elsewhere can't silently break this without the test suite catching it.
Full smoke suite passes; live boot confirmed (HTTP 200). Not yet
deployed — first draft, held back for your review before it goes live
(you mentioned wanting to come back and adjust it), so shinyapps.io
still has the 2026-08-17 real-data-refresh deploy as its current version.

## Update (2026-08-17c) — "weak internet" review: three fixes to cut what the dashboard sends over the wire

Reported: partners on weak internet connections see real lag interacting
with the dashboard. Asked for a full diagnosis of what's actually heavy
(not a guess) with suggested fixes to review before implementing, framed
around being proactive now since submissions will grow ~35× (903 ->
31,506) over the rest of data collection. Findings were reviewed and all
three approved for implementation the same day.

**Method**: measured actual transmitted payload sizes directly (GeoJSON
byte counts, installed JS library sizes) rather than guessing. Full
findings, including what was checked and found NOT to be a problem
(DT tables are already server-side paginated; per-enumerator/LGA/partner
charts are pre-aggregated and don't scale with submission count; DT's
PDF-export extension is present on disk but never actually invoked) are
in that conversation, not repeated here — this entry covers what changed.

**1. Coverage Map reference layers were computed and sent to every
visitor regardless of whether they were ever looked at.** Ward
boundaries, PSU hexagon/site reference outlines are off by default
(behind the layers control), and the LGA-fill vs. cluster-status views
are mutually exclusive via a toggle — but `mod_map.R` computed and
transmitted *all* of it unconditionally the moment the Coverage Map tab
opened; `hideGroup()` only hides already-transmitted data with CSS.
Fixed two ways in `R/mod_map.R`:
- The "LGA progress" vs. "Cluster status"/"Cluster status sites" fill
  observers now also `req(input$map_view == ...)`, so only whichever
  view is actually selected gets computed.
- Ward boundaries / PSU hexagons / PSU sites now `req()` on a new
  `layer_shown` flag, set the first time that specific layer is actually
  switched on. Leaflet's R package doesn't expose the layers control's
  checkboxes as a Shiny input on its own, so `renderLeaflet`'s widget now
  carries a small `htmlwidgets::onRender()` JS snippet listening for
  Leaflet's native `overlayadd` event and forwarding the toggled layer's
  name into a real input (`Shiny.setInputValue(session$ns("layer_toggled"), ...)`)
  the server can `req()` against — same "only pay for what's used" idea
  as the existing `map_tab_active()` gating, one level further in.

**2. No boundary layer had any coordinate-precision reduction.** All
five boundary/geometry layers were read and transmitted at full survey
precision (~15 significant digits — sub-millimetre) for a country-level
web map. You asked specifically how much further this could safely go —
tested empirically rather than picking a number: overlaid full-precision
vs. reduced-precision outlines on the smallest ward in the densest LGA
(the single most precision-sensitive shape in the dataset, ~13 sq km) at
a tight zoom. Full vs. ~11m (4 decimal degrees) was pixel-identical; full
vs. ~111m (one digit coarser) already showed a visible corner shift on
that same shape. **4 decimal places is therefore a deliberate floor, not
a round number** — confirmed visually, not just by distance math.
Combined weight across all six boundary layers: **16.6 MB -> 9.2 MB
(-44%)**, applied once at load time in `global.R` via a new
`reduce_coord_precision()` helper (writes to a temp GeoJSON with
`COORDINATE_PRECISION=4` and reads it back — a one-time startup cost, not
a per-request one). Deliberately precision-only, not geometry
simplification (`sf::st_simplify()`/`rmapshaper`) — tested that too, and
it added only marginal extra savings on top of precision reduction while
introducing real topology risk (`st_simplify()` produced invalid geometry
on the PSU hexagon grid: "Loop 0 is not valid: Edge 2 is degenerate").
Precision reduction alone carries none of that risk — it rounds
coordinates, never moves a vertex relative to its neighbours.

**3. Four charts sent every raw row to the browser to bin client-side.**
`hour_hist`/`duration_hist`/`age_hist` (Data Integrity Checks) and
`hh_size_hist` (Sample Representativeness) used plotly's
`type="histogram"`, which ships the whole raw column for the browser to
bin in JavaScript — trivial at 903 rows, a genuinely avoidable few-MB tax
at the full 31,506 (the one piece of today's weight that actually scales
with submissions, so the most relevant fix to do proactively now).
Replaced with two new helpers in `global.R` — `bin_integer_counts()` (one
bin per integer value, e.g. age 18-90, zero-filled so the axis doesn't
skip gaps) and `bin_continuous_counts()` (equal-width bins over the
observed range, matching plotly's own `nbinsx` auto-binning, used for
`duration_min`) — feeding `type="bar"` on the pre-computed counts
instead. Verified bin-by-bin against a manual tally (exact match, not
just "didn't error") for all four.

**Verified**: full smoke suite passes, including three new permanent
regression tests — histogram binning (exact match against manual
tallies, plus empty-input/all-identical-value edge cases), and a Coverage
Map lazy-layer test (through the real app server, not just the isolated
module) confirming zero `leafletProxy()` calls for an untouched reference
layer or inactive view, and exactly one the first time each is actually
selected. Live boot confirmed (HTTP 200) after each change. No visual or
behavioural change to any chart or the map itself — same numbers, same
shapes, same filter connections, just materially less sent over the wire
to produce them, and less of that cost still ahead as data collection
continues.

Not yet deployed — held back alongside the FACT digest (2026-08-17b,
above) pending your review; let me know when to redeploy both.

## Update (2026-08-17d) — correction: FACT digest is a standalone script, not a dashboard feature

2026-08-17b built the partner data quality digest as a "Download partner
digest (Excel)" button on the live Data Quality tab — a miscommunication;
it was meant to be a workbook you generate yourself and send directly to
FACT, not something exposed on the deployed dashboard at all (which
anyone with the dashboard link could otherwise have triggered).

**Fixed**: removed the card/button from `mod_quality_ui`/
`mod_quality_server` (`R/mod_quality.R` is back to exactly its original
scope — core review flags and the flagged-submissions table, nothing
else). The report builder itself
(`build_fact_quality_digest_excel()`) moved out to its own file,
`R/reports_fact_digest.R` — still lives under `dashboard_app/R/` so
`global.R`'s own `source()` loop picks it up automatically (that's what
lets both the standalone script below and `tests/smoke_test.R` call it
with no extra wiring), but nothing in `app.R`/`ui.R` ever references it,
so it plays no part in the deployed app.

**New standalone entry point**: `generate_fact_digest.R` (project root,
alongside `deploy_dashboard.R`) —

```r
source("generate_fact_digest.R")
```

writes `reports/MSNA_2026_partner_digest_for_FACT_<date>.xlsx` (new
`reports/` folder, gitignored — a hand-off artifact you send directly,
same reasoning as `data/`/`input_data/` not being tracked). Confirms
which day's data it was built from on completion, and warns loudly if it
somehow ran against mock data instead of real. Daily workflow is
unchanged from what 2026-08-17b described — it reads `submissions_raw`
directly, so re-running `cleaning/real/prep_real_submissions.R` as usual
is the only "refresh" step, nothing extra to maintain for the digest
itself; you just run this script (instead of clicking a dashboard
button) whenever you want a fresh copy to send FACT.

**Verified**: ran the new script directly (confirmed the workbook writes
correctly, `reports/` correctly gitignored — `git status` shows nothing).
Full smoke suite passes (the digest's own regression test is unchanged
in what it checks, just relocated). Live boot check confirmed the
button/card no longer appears anywhere in the rendered page HTML — not
just removed from source, actually absent from what a browser receives.

Redeployed to shinyapps.io — verified: bundle ID matches the deployment
record, live app returns HTTP 200, the "Partner digest for FACT"
card/button is confirmed absent from the live rendered page (not just
local), and the new container's startup log is clean. This deploy also
carries the 2026-08-17c "weak internet" performance fixes (map
lazy-loading, boundary coordinate precision, histogram pre-binning) —
all now live together.

## Update (2026-08-18) — FACT digest v2: cleaning-log analysis added

2026-08-17b's digest only ever read `submissions_raw` (sample-vs-submission
MATCHING integrity — GPS distance to assigned point, hh-roster mismatch,
off-hours, duplicates). It never touched the cleaning team's own daily
check-flag logs (`cleaning/MSNA_Data_Cleaning/output/checking/`), so it had
nothing to say about response CONTENT — FSL plausibility, survey duration,
listing/sampling integrity — which is where the two real, active problems
(rushed surveys, implausible FSL answers) actually live. This update adds
that half, in the same workbook, per your steer to extend rather than
split into a second file.

**New file**: `cleaning/real/summarise_cleaning_logs.R` — discovers every
dated `<date>/all_orgs/*_cleaning_log_main.xlsx` (confirmed empirically
that each day's log is a fresh batch, not a cumulative reissue — zero
uuid+check_id overlap between consecutive days — so every date has to be
read and combined, there's no "latest file wins" shortcut here), and
classifies every `check_id` into one of four severity tiers:

- **A** — recommend deletion (structurally invalid: all-zero or
  maximum-possible FCS, entire LCSI module blank, confirmed-rushed
  duration, implausible values)
- **B** — needs a human review (duration near the threshold, GPS/sampling
  duplicates, listing-integrity breaks, generic outliers)
- **C** — pattern-only (individually plausible FSL cross-checks; only a
  concern as an enumerator-level *rate*, not a single occurrence)
- **D** — not a partner issue (self-resolving or statistical)

`CHECK_TIER` in that file is a judgement call, not derived from the
cleaning script's own `change_type` column — that column turned out to be
populated for the most recent log date only, and incompletely even there
(e.g. all-zero FCS, arguably the single worst check, was left
unclassified rather than auto-marked for removal). Confirmed with Jack
before building against it.

Two data-quality surprises turned up reading the real logs, both fixed:
- **check_id naming drift** — earlier logs spell the all-zero-FSL check
  `flag_fcs_zero`, later ones `flag_zero_fcs`; both now tier A. Found a
  genuinely new pattern along the way, `flag_full_fcs` (maximum possible
  FCS, 112/112, every day for a week) — tiered A too, as structurally
  implausible as the all-zero case, just the mirror image.
- **~25–45% of rows in the four earliest logs have no `check_id` at all**
  (the column wasn't consistently populated yet) — confirmed this wasn't
  junk, the `issue` text is still there and matches known patterns, so
  `recover_check_id_from_issue()` recovers a check_id from that text
  instead of silently dropping a third of the early history. Deliberately
  conservative: everything recovered this way lands at tier B, never A.

**Five new sheets** in `build_fact_quality_digest_excel()`
(`dashboard_app/R/reports_fact_digest.R`), ordered right after Summary:
- **Priority follow-up** — every submission with a tier-A issue, or
  already auto-marked `remove_survey` by the cleaning script, cross-checked
  against `submissions_raw` for whether it's still live. Concrete finding
  from the first real run: 41 submissions are tier-A, all 41 are still
  present in the dataset, 36 are still counting toward the achieved total.
  Nothing flagged so far has actually been removed anywhere yet.
- **By enumerator (cleaning log)** / **By partner (cleaning log)** — tier
  breakdown + HIGH/MEDIUM/LOW priority, the direct "who's having the
  biggest issues" answer objective 2 asked for.
- **Common errors** — per-`check_id` rollup (tier, plain-English issue
  text, submissions/enumerators/partners affected) — objective 1's "what
  common errors are we having problems with," independent of who caused
  them.
- **Cleaning log detail** — row-level drill-down, tier-annotated.

One finding worth flagging directly: **si (Solidarités International)**
has a 100% cleaning-log flag rate across all 104 of their submissions, and
all 13 of their enumerators land at HIGH priority. Traced the cause —
`gps_possible_duplicate` alone hits 95 of those 104 submissions, which
reads more like a systemic GPS/methodology issue than 95 individually
coincidental duplicate visits.

Scope, per your answers: cumulative snapshot only (no day-by-day trend
yet), no rest-day/staffing-pattern section (data-quality only, matching
the two stated objectives).

**Bug caught reviewing the first real output, fixed before shipping**: the
Summary sheet's two "...of which" lines (still-achieved, still-present)
were summed across the *whole* priority table instead of their own
preceding row's subset — produced a nonsensical "remove_survey: 27,
...of which still present: 41" (41 > 27, impossible). Fixed to scope each
line to its own subset, and added a regression test asserting every "of
which" figure stays ≤ its total, so this class of bug can't silently
reappear.

**Verified**: full smoke suite passes, including new assertions — sheet
structure, priority-list row count reconciles with a fresh recompute,
"counting as achieved" implies "still in dataset", tier-A sums reconcile
between the enumerator and partner rollups, every check type is
tier-labelled, and the Summary "of which" invariant above. Ran
`generate_fact_digest.R` end to end and read every new sheet back out of
the actual `.xlsx` to confirm the numbers land right, not just that the
code runs.

Still a standalone script only (`source("generate_fact_digest.R")` from
the project root) — nothing here touches `app.R`/`ui.R` or gets deployed.

## Update (2026-08-19) — Dange-Shuni reallocated Street Child → FACT; redeployed

Per `field_verify/prompt_2026-08-19_dange_shuni_partner_reallocation.md`
(instructions from the `1_sampling/` session, that project's own
`Partnerscoverage.xlsx` already updated there): Dange-Shuni LGA (Sokoto,
`NG034003`) moves from Street Child of Nigeria to FACT. Straight one-LGA
swap, no other LGA's coverage changed.

Copied the updated source into both of this project's independent
snapshots (`input_data/partner_coverage/Partnerscoverage.xlsx` and
`dashboard_app/input_data/partner_coverage/Partnerscoverage.xlsx`),
verifying the source itself first rather than trusting the prompt's word
for it — confirmed Dange-Shuni's row has FACT marked, Street Child
cleared, `COUNT` correctly still 1. Reran
`cleaning/prep/prep_partner_lga_assignment.R`: output now shows
`NG034003 -> org_id "fact"` only. One pre-existing unmatched-row warning
(Nasarawa/Eggon) is unrelated — different region, not touched by this
change, confirmed it's a frame-matching quirk that predates today.

Checked the three files the prompt flagged for caching risk
(`mod_partner_report.R`, `mod_map.R`, `reports_fact_digest.R`) rather than
assuming a file swap was enough: all three derive partner-LGA assignment
live from `partner_lga_assignment.csv` at `global.R` source time
(`partner_adm2`, `coverage_orgs_by_adm2`, `partner_coverage_label()`) —
no baked `.rds`, nothing cached across sessions. A redeploy (fresh R
process) is sufficient on its own; confirmed this directly by reading
`partner_adm2[["fact"]]`/`partner_adm2[["street_child"]]` against the
regenerated CSV before deploying, not just inferring it from the code.
Since nothing needed an actual dashboard code change, this qualified as
the "simple file swap" case the prompt said doesn't need a separate
confirmation round before redeploying.

**Real bug caught by the smoke suite along the way, unrelated to
Dange-Shuni**: a new `2026-08-18` cleaning-log folder had landed since the
last full test run (cleaning logs and `submissions_raw` refresh on
independent schedules — see 2026-08-18's entry). That log referenced more
of a few enumerators' work than the still-08-17-based `submissions_raw`
yet contained, so `submissions_flagged` briefly exceeded
`total_submissions` for those enumerators in `summarise_cleaning_logs.R`'s
`by_enumerator`/`by_partner` tables — caught by the
`Submissions.flagged <= Total.submissions` regression assertion. Fixed
with `pmax()` flooring the denominator at `submissions_flagged` (comment
in the code explains why), so this refresh-timing skew — which will
happen again any time cleaning logs get ahead of the last data pull —
can't produce a >100% flag rate or a failed invariant. Not something a
test relaxation would have been right to do here; the underlying
computation needed to be correct regardless of which source is
momentarily ahead.

**Deploy**: hit shinyapps.io network trouble again (Jack's connection
dropped mid-attempt) — the first attempt's upload succeeded but the
client lost the connection waiting on the server-side task, then three
follow-up attempts all got HTTP 409 "task already in progress" because
that first attempt's build was still genuinely running server-side (not
stuck — `rsconnect::taskLog()` showed real progress installing system
dependencies). Rather than keep retrying into the same wall, polled the
specific task ID via `rsconnect::tasks()`/`taskLog()` until it resolved
(`building` → `deploying` → `success`, ~13 minutes total). Note for next
time: the local `.dcf` deployment record's `bundleId` isn't reliable
evidence of what's actually live when multiple attempts overlap like
this — it just reflects the last `deployApp()` call made locally, success
or not. All the overlapping attempts' bundles were content-identical
(no files changed between them), so it didn't matter here, but a bundle-ID
check alone wouldn't have been trustworthy verification on its own.

**Verified**: HTTP 200, container log clean (only the routine GDAL
GeoPackage warnings, then "Listening on..."), live HTML has zero matches
for the FACT-digest button (confirming that change also stayed correctly
out of the deployed app), full smoke suite passing pre-deploy including
the new `pmax()` fix.

## Update (2026-08-20) — FACT digest v3: usability restructure + oversampled clusters

Jack's review of the first real output: too many tabs, no orientation for
someone opening it cold, and a real analytical gap (oversampled clusters
never surfaced anywhere). Four changes:

**"Read me" sheet** (replaces "Summary", first tab) — a sheet-by-sheet
guide ("what it shows" / "start here if..."), the severity-tier
definitions (A–D) spelled out in plain language, an explicit note on how
"Tier A/B/C" (can double-count a submission across tiers) differs from
"Total flag instances" (flat, non-overlapping — the direct "how many
flags in total" answer, new this update), and the headline numbers table
"Summary" used to hold alone. Navy (`#1F3864`) / black styling applied
workbook-wide: navy header row on every sheet, navy section banners on
Read me. Couldn't visually render the actual `.xlsx` to confirm the
styling reads well — Jack, please eyeball it and flag anything.

**Partners / Enumerators merged** — asked first (see conversation) whether
to consolidate by entity (one "Partners" sheet, one "Enumerators" sheet,
each carrying both dashboard-flag and cleaning-log metrics) or by
analysis-type (a "cleaning log" sheet and a "progress" sheet, each mixing
partner- and enumerator-grain rows). Went with entity-based per Jack's
choice — cleaner grain, works as a real sortable/filterable Excel Table,
matches "look up a partner/enumerator, see everything about them." Old
"By partner" + "By partner (cleaning log)" collapsed into one "Partners"
sheet; "By enumerator (cleaning log)" gained a new dashboard-flag rollup
(GPS/duration/roster/off-hours/duplicates by enumerator — didn't exist
before) to become "Enumerators". Both are now **full rosters** — every
partner/enumerator with a submission OR a cleaning-log flag, not just
flagged ones, so a clean enumerator shows zeros instead of being invisible.
Both gained "Flagged issues" (which check types, most frequent first) and
"Total flag instances" (the flat total the Read me note above explains).

Building the full roster surfaced a real gap, caught by the smoke suite:
an enumerator can appear in a cleaning log before their first submission
is pulled into `submissions_raw` at all (not just with a higher count —
absent entirely). A roster built from `submissions_raw` alone silently
dropped such an enumerator's row, tier-A flags included — found via the
enumerator-vs-partner tier-A reconciliation test failing (61 vs 63:
`si_zam_msna_015` had 2 tier-A flags and zero rows in `submissions_raw`
yet). Fixed by building both rosters as a **union** of `submissions_raw`'s
and the cleaning logs' own enum_id/org_id sets (see the union-roster note
in `summarise_cleaning_logs.R`), not `submissions_raw` alone. 33
enumerators currently exist only via this union. Their dashboard-flag
columns (Completed/Achieved/GPS outliers/...) coalesce to 0 (genuinely
unknown until pulled in) rather than blank; "Submissions" falls back to
the cleaning log's own pmax-protected count rather than showing a
contradictory 0 next to a non-zero flag count.

**Oversampled clusters** (new sheet) — clusters where achieved
submissions exceed `target_households`, computed from the same
`psu_hexagons_sf`/`psu_sites_sf` target the Coverage Map itself uses
(mirrors `mod_map.R`'s `cluster_achieved()`/`cluster_status()` pattern),
not from the cleaning logs — this is a sampling-design question, not a
response-quality one, so it doesn't go through the tier system. **14
oversampled clusters, 102 surplus submissions** as of this run. Worth
flagging directly: si's Zamfara IDP cluster (`idp_NG037001_6`) is at
92/60 — 32 over target — and si is also the partner with by far the worst
cleaning-log profile (see below). Likely the same underlying behaviour
(revisiting within a cluster instead of spreading out) producing both the
volume surplus and the GPS-duplicate flags. Shows both the *assigned*
partner (from `Partnerscoverage.xlsx`) and the *actual submitting*
partner(s) separately, since a mismatch between the two is its own signal.

**si (Solidarités International) update**: with cleaning logs now
covering through 19 Aug (vs. 17 Aug when this was first flagged), si's
picture has gotten worse, not better — cleaning-log flag rate is now a
flat 100% (151 flagged submissions known to the cleaning logs against 104
pulled into the dashboard so far — see the "Submissions" vs
"Cleaning-log flagged" note above, this is the real-world case that
motivated it), tier-A count is up to 21, and `si_zam_msna_012`
individually now shows 9 tier-A flags against 8 pulled submissions.

**Verified**: full smoke suite passes, including new assertions for the
merged sheets' roster completeness, cross-sheet tier-A reconciliation, the
oversampled-clusters sheet's own arithmetic (`Surplus == Achieved -
Target.HH` for every row), and the Read me headline numbers reconciling
against their source sheets. Ran `generate_fact_digest.R` end to end and
read every sheet back out of the actual `.xlsx` — including a manual
spot-check of si's row and an enumerator's "Flagged issues" string — not
just that the code runs without error.

## Update (2026-08-21) — mock data retired; duplicated data files cleaned up

Jack noticed `mock_submissions.csv`/`mock_meta.rds` duplicated across
`data/` (project root) and `dashboard_app/data/` (~10MB total) and asked
for it to be removed — mock data was a pre-launch stand-in before real
submissions existed, and real data has been the only thing actually
loaded (`global.R`'s own `USE_REAL_DATA` preference) for weeks now.

**Removed**: both copies of `mock_submissions.csv`/`mock_meta.rds`, and
`cleaning/mock/` entirely (`generate_mock_submissions.R` + its README —
the generator script itself, not just its output; confirmed with Jack
first since it was untracked, so deleting it isn't recoverable via git
history the way a tracked file would be).

**Not removed**: `real_submissions.csv`/`real_meta.rds`'s own two copies
(`data/` and `dashboard_app/data/`) — this looks like the same kind of
duplication but isn't: it's `deploy_dashboard.R`'s deliberate copy-into-
`dashboard_app/` step (shinyapps.io only bundles the app directory
itself), regenerated fresh on every deploy. Removing the `dashboard_app/`
copy would just break local testing until the next deploy re-created it.

**Code cleanup, not just data**: `global.R`'s mock/real fallback
(`USE_REAL_DATA`) is gone — it now requires `real_submissions.csv`
outright and fails with a clear message pointing at
`prep_real_submissions.R` if it's missing, rather than silently reaching
for a mock file that no longer exists anywhere (verified both the clean
boot path and the missing-file error path directly, not just read the
code). The `IS_MOCK_DATA` flag and its two dead UI banners (sidebar in
`app.R`, Home-tab text in `mod_home.R`) are gone too — provably always
`FALSE` now, since `real_meta.rds` never sets `is_mock_data`. Renamed the
confusingly-named `mock_meta` variable (it held real metadata regardless
of source) to `submissions_meta` — `generate_fact_digest.R` updated to
match.

**One real test dependency had to be preserved, not just deleted**:
`tests/smoke_test.R` had a `find_gps_duplicate_groups()` regression test
that specifically read `mock_submissions.csv` off disk, because the mock
generator deliberately injected a guaranteed GPS-duplicate pattern —
real data has no reliable duplicate coincidence, so asserting a nonzero
count against whichever source happened to be active would make the test
flaky the day real data's recovered-GPS subset genuinely has zero
coincidences (not a bug). Replaced with a minimal inline synthetic
fixture (three rows, two sharing one lat/lon) that exercises the same
function deterministically without needing the retired file at all.

**Verified**: full smoke suite passes. Booted the dashboard locally (this
touched UI code) and confirmed in the actual rendered HTML — zero
remaining matches for "mock" anywhere on the page, Home tab's data-source
text renders correctly. Directly tested the new missing-file error path
by temporarily renaming `data/real_submissions.csv` away and confirming
`global.R` fails with the intended clear message, then restored it.
Regenerated `generate_fact_digest.R` end to end post-cleanup to confirm
nothing there depended on any of this either.

## Update (2026-08-21b) — input-data sanity checks (new)

Jack asked whether the pipeline does any sanity-checking of the incoming
data at all, thinking about what happens if the data officer's upstream
export changes shape or has a mistake. Audit found essentially none:
two existence-only file checks, a set of per-row quality *flags* that
never alert anyone, and a test suite that verifies the app's own
arithmetic, not the data's plausibility. Concrete risk traced through the
code: a broken join or a renamed column mostly degrades into a
plausible-looking wrong number (e.g. an all-NA date column would silently
turn `FIELDING_START` into `Inf`, cascading into garbage ETA figures with
no crash and no alert) rather than failing clearly.

**New**: `cleaning/real/sanity_checks.R` — eight checks run at the end of
`prep_real_submissions.R`: schema (expected columns still present),
row-count (should only grow day to day), date-field health, numeric
parse failures (previously silently swallowed by `suppressWarnings()`),
duplicate raw uuids (an export-glitch check, distinct from the existing
methodology-aware repeat-household flag), unknown `org_id` values,
roster-join health (did it silently stop matching), and conservative
implausible-value bounds (negative duration, extreme age/household size).

**Deliberately warn, never hard-stop** (Jack's call) — a pipeline that can
block itself from refreshing on a false positive is worse than one that
flags a concern but still produces today's data. But per Jack's follow-up
— a warning that only prints to a console and scrolls away is nearly as
bad as no warning — these persist to `data/SANITY_WARNINGS.txt` and get
loudly re-announced at the start of **every** entry point in the daily
workflow (`prep_real_submissions.R`, `generate_fact_digest.R`,
`deploy_dashboard.R` — the last one being the most important checkpoint,
right before anything goes live) for as long as the file exists. It is
never auto-cleared by a subsequent clean run; `clear_sanity_warnings.R`
(new, project root) is the explicit acknowledgment step. That's the
"can't move past without acknowledging" behaviour Jack asked for, without
an actual blocking prompt (which would break running any of these
non-interactively, e.g. from this assistant).

**Found real, previously-invisible issues on the very first run** against
current data: row count had more than doubled since the last local prep
(1,363 → 3,325 — worth knowing given more data is expected within the
hour), 2 households with `hh_size` of 35/36 (internally consistent with
their roster count, so the *existing* hh_size-vs-roster mismatch flag
would never have caught these — a genuine gap this closes), and 3
submissions with a negative duration (end time before start time). Left
these live in `data/SANITY_WARNINGS.txt`, unacknowledged, for Jack to
review — not cleared as part of this work.

**Verified**: ran the real pipeline (not synthetic data) and confirmed
each finding by hand-inspecting the flagged rows, not just trusting the
check fired. Confirmed the banner re-appears at the start of
`generate_fact_digest.R` (ran it for real) without needing to re-trigger
`prep_real_submissions.R`. Verified `clear_sanity_warnings.R` displays,
removes the file, and that the banner goes silent afterward — then
re-ran `prep_real_submissions.R` once more so the file honestly reflects
current (still-unacknowledged) reality rather than being left artificially
clear from testing. Full smoke suite passes against the refreshed,
much-larger real dataset (achieved count now 3,072 of 31,506).

## Update (2026-08-21c) — workspace review (excl. `cleaning/`): findings + cleanup

Read-only review of everything outside `cleaning/` for stale files,
documentation gaps, and inefficient processes, per Jack's request. Full
findings given directly to Jack; summarised here is what got actioned,
each confirmed with him first.

**`renv.lock` was genuinely broken for deploy, not just a nagging
warning** — this is the "project is out-of-sync" message every single R
script run in this project has printed for days. Ran `renv::status()`
directly (not just noted the symptom): `rsconnect` — the package
`deploy_dashboard.R` depends on to push live — was installed and used but
never recorded in the lockfile, alongside its auth deps (`httr2`, `jose`,
`rstudioapi`, `snowflakeauth`, `packrat`, `RcppTOML`) and a drifted
`rlang` (1.2.0 recorded vs 1.3.0 installed). A fresh `renv::restore()` —
new machine, or recovering from the OneDrive folder-loss this project
already suffered once (2026-08-15c) — would silently fail to install the
one package the deploy script needs. Ran `renv::snapshot()`; `renv::status()`
now reports "No issues found." Verified `library(rsconnect)` still loads
(v1.10.1) and the full smoke suite still passes post-snapshot — did not
run an actual deploy, per the earlier "hold off" instruction still in
effect this session.

**Removed, confirmed dead first**: `MSNA_data_quality_evidence.xlsx`
(project root — grepped the whole workspace including `cleaning/`, zero
references anywhere); `input_data/kobo_form/NGA2605_MSNA_Kobo_30072026.xlsx`
(both copies — its only documented purpose was grounding the mock-data
generator, itself deleted 2026-08-21); `dashboard_app/.gitkeep`
(vestigial from before that folder had real content).

**`field_verify/` reorganised**: the closed SCI boundary-dispute thread
(verify/crosscheck scripts, output CSVs, 3 example maps, the draft
response, the original cross-session prompt that started it) moved to
`field_verify/archive/sci_boundary_dispute/` rather than deleted — Jack
confirmed the dispute is closed, but it's worth keeping as a record. Added
`field_verify/README.md` — the folder mixes several unrelated threads
with no map tying them together, so a short index of what's live vs.
archived, and why.

**Terminated the abandoned shinyapps.io app slot** (`msna_nga_monitoring`,
appId `17662994`) — flagged as "looks abandoned" back on 2026-08-03c and
never resolved. Confirmed first via `rsconnect::applications()`: status
"pending," `updated_time` nine seconds after `created_time`, meaning it
never had a successful deployment — an empty first-attempt app slot, not
live content. Confirmed with Jack, then `rsconnect::terminateApp(...)`;
re-checked `applications()` afterward to confirm status is now
"terminated." Also removed the now-orphaned local
`dashboard_app/rsconnect/shinyapps.io/impact-nga-jp/msna_nga_monitoring.dcf`.

**Flagged but not actioned** (Jack's to decide/do):
- `reports/` has no retention policy and grows forever; also has an
  unexplained gap (no 2026-08-20 file despite that day's own README entry
  describing a digest run) and mtimes that don't match the dates in their
  filenames. Could be the same OneDrive-sync quirk this project has hit
  before (2026-08-15c, 2026-08-17f) — flagged for Jack to check directly
  rather than guessed at.
- Real uncommitted work currently sitting only on disk (`README.md`,
  `mod_home.R`, `app.R`, `global.R`, `smoke_test.R`, `deploy_dashboard.R`,
  `generate_fact_digest.R`, plus `clear_sanity_warnings.R` untracked
  entirely) — not committed as part of this work, since committing wasn't
  asked for, but worth doing soon given the project's own history of
  losing exactly this kind of uncommitted work.
- Root `README.md` (this file) is now a ~1,900-line pure changelog with
  no "current state" summary at the top — not changed here since it's
  this file's own append-only convention under discussion, not a
  unilateral call to make.

**Verified**: full smoke suite passes after every change in this round
(archiving, deletions, `.gitkeep` removal, the `renv.lock` fix, the
shinyapps.io termination) — ran it fresh at the end, not just after each
individual step.

## Update (2026-08-21d) — report renamed + integrated into deploy; redeployed; a real bug caught along the way

Per Jack: (1) the report and the dashboard update are "inherently linked"
and should happen together, not as two separate things to remember; (2)
the report should drop "FACT" from its name/branding — it's IMPACT's own
internal review first, with what (if anything) gets shared with FACT (a
close field partner, not the primary audience) a decision made *after*
reviewing it, not assumed by the report's identity.

**Renamed** (via `git mv`, preserving history): `generate_fact_digest.R`
→ `generate_partner_digest.R`; `dashboard_app/R/reports_fact_digest.R` →
`reports_partner_digest.R`; the function `build_fact_quality_digest_excel`
→ `build_partner_quality_digest_excel`; the output file
`MSNA_2026_partner_digest_for_FACT_<date>.xlsx` →
`MSNA_2026_partner_digest_<date>.xlsx`. The Read me sheet's own title
dropped "(for FACT)"; its subtitle now reads "Internal IMPACT review —
generated \<date\> — what (if anything) to share with FACT or other
partners is a decision made after reviewing this, not assumed." Grepped
the whole workspace afterward to confirm no leftover `FACT`/`build_fact_*`
references outside of (a) the deliberate mentions explaining FACT as a
downstream stakeholder, and (b) untouched historical README entries
(never rewritten, per this file's own convention).

**Integrated**: `deploy_dashboard.R` now sources `generate_partner_
digest.R` as its first real step, before the data/input_data copy and the
actual deploy — one `source("deploy_dashboard.R")` now produces both.
`generate_partner_digest.R` still works standalone too (e.g. to
regenerate just the report without redeploying).

**A real, unrelated bug turned up while verifying the deploy, and got
fixed before going live**: `latitude_submitted`/`longitude_submitted`
were coming back **100% NA** in `submissions_raw` — not because the data
was missing, but because `readr::read_csv()`'s default type-guessing only
samples the first ~1,000 rows, these two columns are NA for most rows
(only populated where GPS was recovered via the spatial-duplicate audit),
and as the file has grown past 4,500 rows the real values now first
appear well past that sample window. Confirmed directly: `problems()`
showed 384 rejected cells, the resulting columns were `logical` not
`double`, and `find_gps_duplicate_groups()` — which the Data Integrity
tab's GPS-duplicate check depends on — was silently running against zero
real coordinates the whole time (the smoke test's own check on this
function is deliberately informational-only against real data, so it
never would have caught this). Noticed it from a "parsing issues" warning
in the first deploy's own console output (bundle `12445696`) while
checking the log for anything unusual — not something anyone was
specifically looking for. Fixed in `global.R`'s `read_csv()` call:
explicit `col_types` for these two columns (bulletproof regardless of
sample size) plus a much larger `guess_max` as a general safeguard
against the same class of mistake on any other sparse column. Verified
directly before and after: 0 → 192 non-NA coordinates recovered, GPS-
duplicate groups found went from 0 to a real, non-trivial count, and the
"parsing issues" warning is gone from the redeploy's console output
entirely. Redeployed with the fix (bundle `12445717`) before anyone
downstream saw the broken version live for more than a few minutes.

**Data refreshed to the latest available export** before deploying —
`NGA2605_MSNA_anonymised_2026-08-21.xlsx` (3,325 → 4,532 rows, the
"updated data" Jack was expecting). Same 5 sanity-check findings from
2026-08-21b persist unacknowledged (2 large households, 3 negative
durations) — still real, still Jack's to review, `data/SANITY_WARNINGS.txt`
correctly keeps re-announcing them at every entry point.

**Verified live**: HTTP 200, local `.dcf` bundle ID matches
(`12445717`), deployed container's own startup log confirmed clean — no
parsing-issues warning server-side either, confirming the fix applies
there too, not just locally. Grepped the live rendered page for stray
"FACT" branding: the only hits are the dashboard's own pre-existing,
legitimate "IMPACT/FACT" dual-audience framing text (unrelated, untouched
by this work), not digest branding.
