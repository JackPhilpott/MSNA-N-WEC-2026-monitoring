# MSNA N-WEC 2026 — Monitoring dashboard (live 2026-08-15)
#
# Reads: ../data/real_submissions.csv, adapted daily from the data team's
# cleaning pipeline by cleaning/real/prep_real_submissions.R. global.R does
# all data loading; R/mod_*.R hold one Shiny module per tab.
# (Mock/simulated data was used pre-launch, before real submissions
# existed — retired 2026-08-21 once real data was reliably flowing.)
#
# Dual audience: IMPACT/FACT internal monitoring (all tabs, unfiltered) and
# field partners (filter to their org via the sidebar, or use the dedicated
# Partner Report tab). See mod_home.R for the fuller framing.

source("global.R", local = FALSE)

# Taller value_box (Analysis-tab summary boxes were clipping combined
# "1,234 (56%)"-style values) + a touch more room generally — applies
# dashboard-wide via CSS rather than touching every value_box() call.
GLOBAL_CSS <- tags$style(HTML("
  .bslib-value-box { min-height: 132px; }
  .bslib-value-box .value-box-value { white-space: normal; word-break: break-word; line-height: 1.25; font-size: 1.3rem; }
  .bslib-value-box .value-box-title { white-space: normal; }
  /* 2026-09-20 (Jack: DT column-filter dropdowns): DT's filter=\"top\" row
     sets each <select>'s width inline to match its own (often narrow)
     column, so a short word like \"Complete\" can wrap across 2-3 lines
     inside the OPEN dropdown list on Windows/Chrome, which renders a
     select's popup at the same width as the closed control rather than
     auto-fitting the longest option. width: auto !important overrides
     that inline style; overflow: visible on the header cell lets the
     now-wider control sit without being clipped by the column's own
     narrow boundary, at the cost of it visually overlapping a neighbouring
     header by a few px on the very narrowest columns (Status) — a better
     tradeoff than 3-line-wrapped option text. Applies to every DT table
     with a filter row dashboard-wide (Progress by LGA, Partner Report's
     LGA table, etc.), not just one. */
  table.dataTable thead tr.filters th { overflow: visible; }
  table.dataTable thead tr.filters select {
    width: auto !important;
    min-width: 110px;
  }
"))

# A proper collapsed dropdown for every multi-select filter — showing all
# ~176 LGAs or ~2,000 wards as individual removable tags (what
# selectizeInput did) made the sidebar stretch absurdly long once
# everything defaults to selected. pickerInput collapses to a compact
# "X of Y selected" summary instead, with a search box and select-all/
# deselect-all actions for the long lists (LGA/Ward/Partner).
#
# Ward filter (re-enabled 2026-08-15): the real tool's admin3 field
# turned out to be a genuine per-submission ward selection (a
# select_one_from_file backed by input_data/MSNA_2026_admin3.csv, a KoBo
# media attachment, not visible in the XLSForm workbook itself) — not
# unusable the way the 2026-08-14 note here assumed. Its ward *names*
# match our own GRID3-based adm3_name 1:1 despite using a different pcode
# scheme (confirmed against all wards seen in the real data so far), so
# cleaning/real/prep_real_submissions.R translates through that file and
# populates admin3_submitted for real, and the existing GRID3-based
# scaffolding (get_ward_choices()/ward_to_lga in global.R) works
# unmodified.
# container = "body": bootstrap-select's dropdown panel is rendered as a
# direct child of <body> instead of nested inside the sidebar — otherwise
# the sidebar's own stacking context clips/hides the right-hand side of an
# open dropdown (the tick marks) behind the main page content, worst on the
# Partner filter since it's furthest down the sidebar.
picker_opts <- function(...) pickerOptions(
  actionsBox = TRUE, liveSearch = TRUE, selectedTextFormat = "count > 3",
  countSelectedText = "{0} of {1} selected", noneSelectedText = "Nothing selected",
  size = 10, container = "body", ...
)

# All five of Region/State/LGA/Partner/Population group mutually narrow
# each other's available choices (see compute_filter_choices() in
# global.R); every picker below starts with ALL of its choices
# pre-selected — no separate "All X" pseudo-choice to manage, so
# deselecting one option just narrows, exactly like a normal multi-select.
filter_sidebar <- sidebar(
  title = "Filters",
  width = 300,
  # 2026-09-19 (Jack-approved build, relayed via the Coordinator): a global
  # computation-basis switch, not a scope filter like everything below it
  # (it doesn't narrow which rows are in view — it changes what "target"
  # MEANS for every target-dependent figure dashboard-wide: status/
  # "Complete", pct_achieved, map colouring, Still-Needed, KPI %s). Given
  # its own visually separated block + a stronger label for that reason,
  # rather than sitting inline with Region/State/etc. as just another
  # pickerInput. Default "original" matches Decision A (2026-09-16) exactly
  # — nothing on the dashboard changes until a user actively toggles this.
  # See global.R's target_basis_label()/active_planned_interviews() and
  # compute_progress_by_stratum()'s target_active for the mechanism.
  # 2026-09-20 (Jack: spacing review) - no margin-bottom here: the outer
  # wrapper was adding its own 10px on top of radioButtons()'s existing
  # form-group bottom margin (the same margin every pickerInput/
  # checkboxGroupInput below already has), stacking into a visibly bigger
  # gap after this block than between any other pair of filters. Dropping
  # it lets the same natural form-group margin apply here as everywhere
  # else in the sidebar.
  div(
    style = "background: rgba(255,255,255,0.08); border-radius: 6px; padding: 8px 10px;",
    div(
      style = "display: flex; align-items: center; gap: 6px;",
      strong("Target basis"),
      info_icon(
        "Switches which target every % and status on the dashboard is measured against. Original = the fixed target set at the start of collection. Revised = the current minimum needed samples, recalculated as accessibility changes. Both are always shown for reference wherever they appear — this only changes which one drives the headline figures.",
        color = THEME_SIDEBAR_FG
      )
    ),
    radioButtons(
      "target_basis", NULL,
      choices = c("Original Target" = "original", "Revised Target" = "revised"),
      selected = "original", inline = TRUE
    )
  ),
  actionButton("reset_filters", "Reset all filters", icon = icon("rotate-left"), class = "btn-secondary btn-sm w-100 mb-2"),
  pickerInput(
    "f_region", "Region",
    choices = region_choices, selected = unname(region_choices),
    multiple = TRUE, options = picker_opts()
  ),
  pickerInput(
    "f_state", "State",
    choices = state_choices, selected = state_choices,
    multiple = TRUE, options = picker_opts()
  ),
  pickerInput(
    "f_lga", "LGA",
    choices = compute_filter_choices("lga", list()), selected = compute_filter_choices("lga", list()),
    multiple = TRUE, options = picker_opts()
  ),
  pickerInput(
    "f_ward", "Ward",
    choices = get_ward_choices(compute_filter_choices("lga", list())),
    selected = get_ward_choices(compute_filter_choices("lga", list())),
    multiple = TRUE, options = picker_opts(virtualScroll = 50)
  ),
  checkboxGroupInput(
    "f_poptype", "Population group",
    choices = pop_type_choices, selected = unname(pop_type_choices)
  ),
  pickerInput(
    "f_partner", "Partner",
    choices = org_id_choices, selected = unname(org_id_choices),
    multiple = TRUE, options = picker_opts()
  ),
  dateRangeInput(
    "f_daterange", "Submission date range",
    start = FIELDING_START,
    end = max(submissions_raw$submission_date, na.rm = TRUE),
    min = FIELDING_START,
    max = max(submissions_raw$submission_date, na.rm = TRUE)
  ),
  hr(),
  bg = THEME_SIDEBAR_BG, fg = THEME_SIDEBAR_FG
)

ui <- tagList(
  GLOBAL_CSS,
  page_navbar(
    id = "main_nav",
    title = "MSNA N-WEC 2026 — Monitoring",
    theme = bs_theme(version = 5, primary = "#1B2A4A", success = "#1E7B4D", warning = "#D99A2B", danger = "#C1443C"),
    navbar_options = navbar_options(bg = THEME_NAVBAR_BG, theme = "dark"),
    sidebar = filter_sidebar,
    # fillable is a page_navbar()-level setting, not a nav_panel() one —
    # nav_panel() has no fillable argument at all (confirmed against the
    # installed bslib 0.11.0's own formals()), so the fillable=FALSE
    # previously passed to mod_progress.R's nav_panel() silently landed in
    # its ... and was emitted as an inert fillable="FALSE" HTML attribute
    # (visible in the rendered page, which is why that fix looked like it
    # had taken effect) — it never actually removed the html-fill-item/
    # html-fill-container classes bslib uses to squeeze a tab to the
    # viewport, so Progress Overview stayed compressed. The real
    # mechanism: pass a character vector of nav_panel *values* here to
    # make ONLY those tabs fillable; every value left out of the vector
    # scrolls instead. Progress Overview is deliberately excluded — see
    # mod_progress.R's own comment.
    fillable = c(
      "Home", "Coverage Map", "Progress by LGA", "Data Quality", "Partner Report", "Data Export",
      "Enumerator Performance", "Data Integrity Checks", "Sample Representativeness"
    ),
    mod_home_ui("home"),
    mod_progress_ui("progress"),
    mod_map_ui("map"),
    mod_table_ui("table"),
    mod_quality_ui("quality"),
    mod_partner_report_ui("partner_report"),
    mod_export_ui("export"),
    if (SHOW_ANALYSIS_TAB) {
      nav_menu(
        "Analysis",
        icon = icon("magnifying-glass-chart"),
        mod_enumerator_ui("enumerator"),
        mod_integrity_ui("integrity"),
        mod_representativeness_ui("representativeness")
      )
    },
    footer = div(
      style = "font-size: 0.8em; color: #888; padding: 6px 16px;",
      "MSNA N-WEC 2026 monitoring dashboard"
    )
  )
)

server <- function(input, output, session) {
  # ---- cross-filtering: Region / State / LGA / Partner / Pop. group -------
  #
  # Region -> State -> LGA -> Ward is a strict *containment* hierarchy
  # (every state belongs to exactly one region, every LGA to exactly one
  # state), and is kept ONE-DIRECTIONAL among itself — parent narrows
  # child, never the reverse. Partner and Population group are genuinely
  # independent facets (not nested inside geography), so they stay fully
  # mutual with the whole hierarchy AND with each other.
  #
  # Why not make everything fully mutual (an earlier version of this did):
  # picking Region = "North-West" would correctly narrow State to NW's
  # states — but if State also fed back into Region's own choice list (as
  # it did before this fix), Region's list would itself narrow to just
  # "North-West", permanently — there'd be no way to click North-East back
  # in, since it would no longer even be in the list. This is a known
  # trap with "fully mutual"/"only relevant values" filtering on a nested
  # hierarchy (Tableau's own docs call out exactly this failure mode and
  # recommend the same fix: pick a one-directional order for anything
  # that's actually a containment chain, and reserve true mutual filtering
  # for independent facets). Partner/Pop.group aren't nested inside
  # geography the same way, so the equivalent lock is far less likely
  # there — but the "Reset filters" button below exists as a safety net
  # regardless, for this or any other filter combination that paints
  # itself into a corner.
  #
  # `filter_ui_state` + `sync_filter_input()` guard against a *different*
  # bug (constant refreshing/jumping): pickerInput's underlying
  # bootstrap-select JS fires a change event on *every* update*Input() call
  # — even when the choices/selected passed in are identical to what's
  # already there — so calling it unconditionally on every invalidation
  # meant filters kept re-triggering each other forever. Tracking what was
  # last actually sent (per filter, isolated so reading it doesn't create
  # a self-dependency) and only calling update*Input when something has
  # genuinely changed breaks that cycle at the source.
  filter_ui_state <- reactiveValues(
    region = list(choices = unname(region_choices), selected = unname(region_choices)),
    state = list(choices = state_choices, selected = state_choices),
    lga = list(choices = compute_filter_choices("lga", list()), selected = compute_filter_choices("lga", list())),
    poptype = list(choices = unname(pop_type_choices), selected = unname(pop_type_choices)),
    partner = list(choices = unname(org_id_choices), selected = unname(org_id_choices)),
    ward = list(choices = get_ward_choices(compute_filter_choices("lga", list())), selected = get_ward_choices(compute_filter_choices("lga", list())))
  )

  sync_filter_input <- function(key, input_id, new_choices, new_selected, updater = updatePickerInput) {
    prev <- isolate(filter_ui_state[[key]])
    if (!setequal(unname(new_choices), unname(prev$choices)) || !setequal(new_selected, prev$selected)) {
      updater(session, input_id, choices = new_choices, selected = new_selected)
      filter_ui_state[[key]] <- list(choices = new_choices, selected = new_selected)
    }
  }

  # Whether a filter has been manually narrowed by the user has to be
  # tracked as its own PERSISTENT flag, not inferred fresh on every
  # cascading recompute — an earlier version tried the latter (comparing
  # the filter's current value against filter_ui_state's cached record)
  # and had a one-shot memory bug: the very first time a manual narrowing
  # was correctly detected and reconciled, sync_filter_input() updates
  # filter_ui_state to match that reconciled value — so on the VERY NEXT
  # sibling-triggered recompute, the current value now equals the cached
  # record again (they were just synced), the system concludes
  # "untouched", and immediately snaps back to selecting everything. The
  # touch signal only survived exactly one comparison before being erased
  # by the act of reconciling it — which is what "filters constantly
  # resetting" actually was.
  #
  # Fixed with a dedicated observer per filter that watches ONLY that
  # filter's own input and sets a flag that, once TRUE, stays TRUE
  # (independent of anything the cross-filter recompute observers do)
  # until "Reset all filters" clears it. To tell a genuine user click
  # apart from our own update*Input() call echoing back (both fire the
  # same input change event) — the flag is set only when the new value
  # doesn't match filter_ui_state's record of what WE last told the
  # client to have; when it matches, this change event is our own echo
  # confirming what we just sent, not a user action.
  filter_touched <- reactiveValues(region = FALSE, state = FALSE, lga = FALSE, ward = FALSE, poptype = FALSE, partner = FALSE)

  # Regression fix (2026-08-16): toggling a filter off then back on (e.g.
  # deselect Region=NW, then reselect it) could leave a DESCENDANT filter
  # (State, LGA) permanently stuck at a narrower-than-correct choice list
  # — e.g. LGA staying at 156/176 and the "planned interviews" KPI staying
  # short of the true 31,506 even after the region was fully restored, with
  # only "Reset all filters" able to fix it. Root cause: every cross-filter
  # observer below used to read SIBLING filters via input$f_x — but input$
  # only updates after a full client round-trip, so within the SAME tick a
  # parent filter changes, a descendant's observer (also invalidated by
  # that same parent change) could still see the OLD, pre-change value of
  # an intermediate sibling that hadn't echoed back yet, computing an
  # incorrect (too-narrow) result. Worse, on the LATER tick where that
  # sibling's real value finally arrived, if the descendant's fresh
  # (correct) computation happened to be a NEW result, sync_filter_input()
  # would send the fix — but if some other coincidence made the check
  # think nothing had changed, the wrong value could silently stick.
  #
  # Fixed by making filter_ui_state itself — not input$f_x — the thing
  # every cross-filter observer reads for its SIBLINGS' current
  # selections. filter_ui_state updates SYNCHRONOUSLY, in the same R
  # execution, both when we send our own update (sync_filter_input, as
  # before) AND now also the moment a genuine user edit is detected
  # (watch_for_manual_touch, below) — no client round-trip needed for
  # this internal bookkeeping. Combined with Shiny's documented behaviour
  # of running simultaneously-invalidated observers in registration order
  # (Region, then State, then LGA — matching the actual dependency chain),
  # a single user action now resolves the entire cascade correctly within
  # one server-side tick: State's observer runs first and synchronously
  # records its corrected value, so by the time LGA's observer runs
  # immediately after, it reads State's ALREADY-fresh value, never a
  # stale one — eliminating the bug at its source rather than hoping a
  # later correction round happens to fire.
  watch_for_manual_touch <- function(key, input_id) {
    observeEvent(input[[input_id]], {
      live <- input[[input_id]]
      prev <- isolate(filter_ui_state[[key]])
      if (is.null(prev$selected) || !setequal(live, prev$selected)) {
        filter_touched[[key]] <- TRUE
        filter_ui_state[[key]] <- list(choices = prev$choices, selected = live)
      }
    }, ignoreInit = TRUE)
  }
  watch_for_manual_touch("region", "f_region")
  watch_for_manual_touch("state", "f_state")
  watch_for_manual_touch("lga", "f_lga")
  watch_for_manual_touch("ward", "f_ward")
  watch_for_manual_touch("poptype", "f_poptype")
  watch_for_manual_touch("partner", "f_partner")

  # Untouched filters auto-follow to *everything* newly available on a
  # cascading recompute (what makes re-selecting a region, after
  # deselecting it, automatically restore the states/LGAs it had narrowed
  # away, with no separate reset click needed); touched filters keep
  # `smart_selection()`'s narrowing-preservation behaviour, unaffected by
  # how many times the underlying choices/selected get reconciled. Reads
  # the filter's OWN current selection from filter_ui_state (synchronous,
  # authoritative) rather than input$f_x, for the same staleness reason
  # documented above.
  resolve_selection <- function(key, new_choices) {
    new_values <- unname(new_choices)
    current <- isolate(filter_ui_state[[key]]$selected)
    if (isolate(filter_touched[[key]])) smart_selection(current, new_values) else new_values
  }

  # Safety net regardless of the hierarchy/mutual-filter design above —
  # unconditionally restores every filter to "everything selected", the
  # same state the app loads in.
  observeEvent(input$reset_filters, {
    for (k in names(filter_touched)) filter_touched[[k]] <- FALSE
    sync_filter_input("region", "f_region", region_choices, unname(region_choices))
    sync_filter_input("state", "f_state", state_choices, state_choices)
    all_lgas <- compute_filter_choices("lga", list())
    sync_filter_input("lga", "f_lga", all_lgas, all_lgas)
    all_wards <- get_ward_choices(all_lgas)
    sync_filter_input("ward", "f_ward", all_wards, all_wards)
    sync_filter_input("poptype", "f_poptype", pop_type_choices, unname(pop_type_choices), updater = updateCheckboxGroupInput)
    sync_filter_input("partner", "f_partner", org_id_choices, unname(org_id_choices))
    updateDateRangeInput(
      session, "f_daterange",
      start = FIELDING_START, end = max(submissions_raw$submission_date, na.rm = TRUE)
    )
  })

  # Region / State / LGA / Pop.group / Partner are computed TOGETHER, in
  # one unified observer, rather than as five separate ones each reading
  # the others' filter_ui_state. Discovered 2026-08-16, one level deeper
  # than the bug the long comment above watch_for_manual_touch describes:
  # registering State before LGA (so LGA reads State's already-fresh
  # value in the same tick) correctly fixes the strictly one-directional
  # Region -> State -> LGA -> Ward chain, but Pop.group and Partner
  # mutually depend on EACH OTHER (and on the whole hierarchy) — a genuine
  # cycle, not a chain. No FIXED registration order can make both sides
  # of a cycle read each other's fresh value in a single linear pass:
  # whichever of the two is registered first still reads the other's
  # value from BEFORE this tick's change. Confirmed directly: restoring
  # Region to full correctly refreshed State and, via it, LGA's OWN
  # region/state inputs — but LGA also depends on Partner, which hadn't
  # been recomputed yet (registered after LGA), so LGA silently kept
  # computing against Partner's stale, pre-restoration narrowing — 156
  # LGAs instead of 176, exactly the reported bug, one dependency further
  # in than the first fix reached.
  #
  # A first attempt fixed this by iterating the whole 5-way computation
  # repeatedly within one observer run until it stopped changing — but
  # that can still CONVERGE to a self-consistent WRONG answer: two
  # UNTOUCHED, mutually-dependent dimensions (Pop.group/Partner) can each
  # keep constraining the other using the other's CURRENT (still stale)
  # selected value, round after round, without either ever getting the
  # chance to jump back to "everything" — confirmed directly (state stuck
  # at 8/11, not 11, even after iterating to a stable fixed point).
  #
  # Fixed properly with a single-pass rule instead: an UNTOUCHED
  # dimension never acts as a constraint on ANY other dimension's
  # computation, regardless of what its current selected value happens to
  # be — only a dimension the user has actually, deliberately narrowed
  # (filter_touched[[x]] == TRUE) is ever passed in as a constraint.
  # This is exactly the correct semantics ("untouched" = "no restriction
  # from here" by definition, not "whatever it currently happens to
  # show") and it eliminates the staleness problem at its root: with
  # nothing but genuinely-touched (always-authoritative, never-stale)
  # values ever feeding into any computation, there is no longer any
  # circular dependency to iterate against, so one pass is always
  # correct — confirmed directly against both the original bug scenario
  # (restoring Region while Pop.group/Partner are untouched-but-stale
  # correctly returns to the full 3/11/176/2/20) and the core narrowing
  # behaviour (deselecting a Region still correctly narrows State/LGA/
  # Partner). Region's own computation still never reads State/LGA, and
  # State's never reads LGA, preserving the one-directional hierarchy
  # that prevents the OTHER known failure mode (narrowing State
  # permanently locking Region's own choices, see the header comment on
  # this whole cross-filtering section).
  observe({
    touched <- list(
      region = filter_touched$region, state = filter_touched$state, lga = filter_touched$lga,
      poptype = filter_touched$poptype, partner = filter_touched$partner
    )
    sel <- list(
      region = filter_ui_state$region$selected, state = filter_ui_state$state$selected,
      lga = filter_ui_state$lga$selected, poptype = filter_ui_state$poptype$selected,
      partner = filter_ui_state$partner$selected
    )
    only_if_touched <- function(key) if (touched[[key]]) sel[[key]] else NULL

    choices <- list(
      region  = compute_filter_choices("region",  list(poptype = only_if_touched("poptype"), partner = only_if_touched("partner"))),
      state   = compute_filter_choices("state",   list(region = only_if_touched("region"), poptype = only_if_touched("poptype"), partner = only_if_touched("partner"))),
      lga     = compute_filter_choices("lga",     list(region = only_if_touched("region"), state = only_if_touched("state"), poptype = only_if_touched("poptype"), partner = only_if_touched("partner"))),
      poptype = compute_filter_choices("poptype", list(region = only_if_touched("region"), state = only_if_touched("state"), lga = only_if_touched("lga"), partner = only_if_touched("partner"))),
      partner = compute_filter_choices("partner", list(region = only_if_touched("region"), state = only_if_touched("state"), lga = only_if_touched("lga"), poptype = only_if_touched("poptype")))
    )
    new_sel <- list(
      region  = if (touched$region)  smart_selection(sel$region,  unname(choices$region))  else unname(choices$region),
      state   = if (touched$state)   smart_selection(sel$state,   unname(choices$state))   else unname(choices$state),
      lga     = if (touched$lga)     smart_selection(sel$lga,     unname(choices$lga))     else unname(choices$lga),
      poptype = if (touched$poptype) smart_selection(sel$poptype, unname(choices$poptype)) else unname(choices$poptype),
      partner = if (touched$partner) smart_selection(sel$partner, unname(choices$partner)) else unname(choices$partner)
    )

    sync_filter_input("region", "f_region", choices$region, new_sel$region)
    sync_filter_input("state", "f_state", choices$state, new_sel$state)
    sync_filter_input("lga", "f_lga", choices$lga, new_sel$lga)
    sync_filter_input("poptype", "f_poptype", choices$poptype, new_sel$poptype, updater = updateCheckboxGroupInput)
    sync_filter_input("partner", "f_partner", choices$partner, new_sel$partner)
  })

  # Ward stays downstream of LGA only (nothing narrows *because of* a ward
  # pick, except which LGA(s) are effectively in view — see effective_lgas).
  # Kept as its own observer since nothing above ever needs Ward's value
  # back — reading filter_ui_state$lga$selected (updated synchronously by
  # the unified observer above, in the same tick) rather than input$f_lga
  # for the same staleness reason as everywhere else in this file.
  observe({
    new_wards <- get_ward_choices(filter_ui_state$lga$selected)
    selected <- resolve_selection("ward", new_wards)
    sync_filter_input("ward", "f_ward", new_wards, selected)
  })

  # LGAs actually in scope once the ward filter is also applied — narrowed
  # to LGA(s) containing at least one currently-selected ward (targets are
  # LGA-level, not ward-level, so a ward selection can't split a target
  # further, only narrow which LGA(s) are in view). Consistent with every
  # other filter: an empty ward selection means "match nothing", not "no
  # restriction" — `ward_to_lga` covers all 176 LGAs (every household-frame
  # row has a resolved ward), so this is never missing an LGA that has no
  # wards to begin with.
  # Reads filter_ui_state (not input$f_lga/input$f_ward directly) for the
  # same reason as the cross-filter observers above: filter_ui_state is
  # always synchronously up to date, whereas input$f_x only reflects a
  # filter's true current value after a full client round-trip — without
  # this, the "planned interviews"/"achieved" KPIs derived from
  # filtered_subs()/filtered_stratum() below could keep showing a
  # transiently-stale, narrower-than-correct scope even after
  # filter_ui_state (and thus the picker widgets themselves) had already
  # resolved to the correct one.
  effective_lgas <- reactive({
    intersect(filter_ui_state$lga$selected, ward_to_lga$adm2_name[ward_to_lga$adm3_name %in% filter_ui_state$ward$selected])
  })

  # adm2_pcodes assigned to the selected partner(s), for scoping
  # target/progress data (which has no org_id of its own — assignment is
  # LGA-level, from partner_lga_assignment).
  selected_partner_adm2 <- reactive(unique(unlist(partner_adm2[filter_ui_state$partner$selected])))

  filtered_subs <- reactive({
    poptype_sel <- filter_ui_state$poptype$selected
    req(poptype_sel)
    submissions_raw %>%
      filter(
        # !(x %in% KNOWN_*) rows (2026-09-01 fix, see KNOWN_STATE_NAMES/
        # KNOWN_LGA_NAMES/KNOWN_WARD_NAMES in global.R): a submitted name the
        # CURRENT frame doesn't recognise at all — most often after a frame
        # revision renames/merges/drops it — was never offered as a filter
        # choice, so it could never be "selected" and would otherwise vanish
        # from every LGA-level view even on a full reset. Only a recognised
        # name that's actively NOT selected should ever be excluded here.
        is.na(admin1) | !(admin1 %in% KNOWN_STATE_NAMES) | admin1 %in% filter_ui_state$state$selected,
        is.na(admin2_submitted) | !(admin2_submitted %in% KNOWN_LGA_NAMES) | admin2_submitted %in% effective_lgas(),
        is.na(admin3_submitted) | !(admin3_submitted %in% KNOWN_WARD_NAMES) | admin3_submitted %in% filter_ui_state$ward$selected,
        is.na(pop_type) | pop_type %in% poptype_sel,
        # FIXED 2026-09-11: was submission_date >= .../<= ... with no NA
        # guard - a date_outlier row now has submission_date deliberately
        # nulled (see prep_real_submissions.R's "7b" step), and NA >= x
        # evaluates to NA, which filter() drops. That made these rows
        # invisible from every date-filtered view (Coverage Map, Progress by
        # LGA, Progress Overview) regardless of which range was selected -
        # even the default "everything" range - while still being counted
        # in the Home page's unfiltered national total. Same is.na()-passes-
        # through pattern already used for ward/pop_type above, applied here
        # too, rather than guessing a fallback date (Jack explicitly
        # rejected that approach on 2026-08-27 for the same reason this
        # field gets nulled in the first place).
        is.na(submission_date) | submission_date >= input$f_daterange[1],
        is.na(submission_date) | submission_date <= input$f_daterange[2],
        org_id %in% filter_ui_state$partner$selected
      )
  })

  # 2026-09-19 (global target-basis toggle, Jack-approved build): every
  # target-dependent figure dashboard-wide reads this one reactive rather
  # than each module re-reading input$target_basis directly, so there's a
  # single point of truth for "which basis is active right now" - matches
  # the existing pattern for map_tab_active()/effective_lgas() etc. above.
  target_basis <- reactive(input$target_basis)

  # Computed from filtered_subs() (not the static progress_by_stratum), so
  # every LGA-level view — Coverage Map's LGA choropleth, Progress by LGA
  # table, Progress Overview's region chart — respects the date-range
  # filter too, same as the Coverage by cluster view already did. Now also
  # basis-aware (target_basis()) — this is the ONE place filtered_stratum's
  # own consumers (mod_map/mod_table/mod_export/mod_representativeness) need
  # the toggle threaded through, since they only ever read filtered_stratum()
  # itself, already basis-aware once it's threaded here.
  filtered_stratum <- reactive({
    poptype_sel <- filter_ui_state$poptype$selected
    req(poptype_sel)
    compute_progress_by_stratum(filtered_subs(), target_basis()) %>%
      filter(
        adm1_name %in% filter_ui_state$state$selected,
        adm2_name %in% effective_lgas(),
        pop_type %in% poptype_sel,
        adm2_pcode %in% selected_partner_adm2()
      )
  })

  # Coverage Map's layer-redraw observers are real-geometry leafletProxy
  # calls (~2,500 hexagons + ~800 sites + boundaries) that used to fire on
  # EVERY filter change regardless of which tab was actually visible —
  # profiled at ~0.2s/layer server-side alone, before network transfer and
  # the client's own Leaflet re-render are even counted, for a tab the user
  # might not be looking at at all. Passed into mod_map_server so its
  # observers can gate on it (see that file for the req()-based mechanism).
  map_tab_active <- reactive(identical(input$main_nav, "Coverage Map"))

  mod_home_server("home", target_basis)
  mod_progress_server("progress", filtered_subs, filtered_stratum, target_basis)
  mod_map_server("map", filtered_stratum, filtered_subs, map_tab_active, target_basis)
  mod_table_server("table", filtered_stratum)
  mod_quality_server("quality", filtered_subs)
  mod_partner_report_server("partner_report", reactive(filter_ui_state$partner$selected), target_basis)
  mod_export_server("export", filtered_subs, filtered_stratum)
  mod_enumerator_server("enumerator", filtered_subs)
  mod_integrity_server("integrity", filtered_subs)
  mod_representativeness_server("representativeness", filtered_subs, filtered_stratum)
}

shinyApp(ui, server)
