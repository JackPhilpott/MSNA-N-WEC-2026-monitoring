# Coverage Map tab: toggle between an LGA-level choropleth and a per-cluster
# (PSU) traffic-light view, with reference boundary/PSU/satellite layers
# available in both via the layers control. Status colours (STATUS_COLORS)
# and pop-type colours (POP_TYPE_COLORS) come from global.R for consistency
# with the rest of the dashboard.

mod_map_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Coverage Map",
    icon = icon("map-location-dot"),
    card(
      full_screen = TRUE,
      card_header(
        div(
          style = "display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;",
          span(
            "Coverage map",
            info_icon("Fill colour and \"% of target\" reflect ACHIEVED — completed, matched, non-duplicate, not a confirmed quality exclusion (under our duration floor, or implausible food-consumption answers), capped at each cluster's own target, so oversampling can't count toward or mask under-coverage elsewhere. Hover a cluster/LGA for its COLLECTED figure too (every completed interview, including oversampled surplus)."),
            if (!is.na(FRAME_AS_OF_LABEL)) {
              span(class = "text-muted", style = "font-size: 0.75em; font-weight: normal; margin-left: 10px;", FRAME_AS_OF_LABEL)
            }
          ),
          div(
            style = "display: flex; align-items: center; flex-wrap: wrap; gap: 14px;",
            radioButtons(
              ns("map_view"), NULL,
              choices = c("Coverage by LGA" = "lga", "Coverage by cluster" = "cluster"),
              selected = "lga", inline = TRUE
            ),
            checkboxGroupInput(
              ns("status_filter"), NULL,
              choices = names(STATUS_COLORS), selected = names(STATUS_COLORS), inline = TRUE
            )
          )
        ),
        span(
          class = "text-muted", style = "font-size: 0.8em; font-weight: normal;",
          "Toggle ward/state boundaries, PSU reference layers and satellite basemap via the layers control (top-right of the map). ",
          "Grey states are outside this assessment. White areas are within the assessment but have been excluded and/or not selected for sampling."
        ),
        br(),
        span(
          class = "text-muted", style = "font-size: 0.8em; font-weight: normal;",
          "Accessibility (via layers control): green = accessible, red = reported inaccessible. ",
          strong(paste0(N_ACCESSIBILITY_PARTNERS_REPORTED, " of ", TOTAL_ACCESSIBILITY_PARTNERS, " partners")),
          " have reported so far — a live, partial picture (default is accessible until a partner reports otherwise), not a final count.",
          info_icon("Reflects partner reports on their own LGA-scoped ward portions, rolled up across the whole sampling universe. This reclassifies clusters partners are already fielding — it is not a new sample design; no clusters have been added, removed, or reallocated.")
        )
      ),
      leafletOutput(ns("map"), height = "780px")
    )
  )
}

mod_map_server <- function(id, filtered_stratum, filtered_subs, map_tab_active = reactive(TRUE)) {
  moduleServer(id, function(input, output, session) {
    filtered_lga <- reactive({
      filtered_stratum() %>%
        group_by(region, adm1_pcode, adm1_name, adm2_pcode, adm2_name) %>%
        summarise(
          target_sample = sum(target_sample, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE),
          collected_n = sum(collected_n, na.rm = TRUE), .groups = "drop"
        ) %>%
        mutate(pct_achieved = ifelse(target_sample > 0, achieved_n / target_sample, NA_real_))
    })

    # in-scope admin2 polygons — used for the LGA fill, the zoom-to-extent,
    # and to scope the ward reference layer to the current filter selection.
    # Only non-overlapping columns are kept from `lga` before the join —
    # admin2_sf already carries adm1_name/adm2_name/region itself, and
    # joining with duplicates of those present on both sides would produce
    # suffixed .x/.y columns instead.
    scope_admin2_sf <- reactive({
      lga <- filtered_lga() %>% select(adm2_pcode, target_sample, achieved_n, collected_n, pct_achieved)
      admin2_sf %>% inner_join(lga, by = "adm2_pcode")
    })

    scope_state_pcodes <- reactive(unique(filtered_stratum()$adm1_pcode))
    scope_lga_names <- reactive(unique(filtered_stratum()$adm2_name))

    # "Samples required" for the LGA popup (2026-08-26, per Jack: the
    # remaining GAP to target, not the static design target itself — an
    # LGA already at/past target for a pop type shows 0, not a negative
    # number, via pmax()). Kept separate from filtered_lga() above (which
    # deliberately collapses pop_type when summing target/achieved for the
    # fill colour and overall % achieved) since this needs the split kept.
    remaining_by_pop_type <- reactive({
      filtered_stratum() %>%
        group_by(adm2_pcode, pop_type) %>%
        summarise(target_sample = sum(target_sample, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(remaining = pmax(target_sample - achieved_n, 0)) %>%
        select(adm2_pcode, pop_type, remaining) %>%
        pivot_wider(names_from = pop_type, values_from = remaining, names_prefix = "remaining_", values_fill = 0) %>%
        # a filtered-down view could in principle contain only one pop
        # type at all (e.g. a single non-IDP-only LGA selected) — pivot_
        # wider then never creates the other column at all, not just NA
        # per row, so both are guaranteed to exist before the join below.
        {
          if (!"remaining_non_idp" %in% names(.)) mutate(., remaining_non_idp = 0) else .
        } %>%
        {
          if (!"remaining_idp" %in% names(.)) mutate(., remaining_idp = 0) else .
        }
    })

    # Deliberately no req(input$status_filter) here — unchecking every
    # status checkbox sends input$status_filter as NULL, and `status %in%
    # NULL` already correctly evaluates to FALSE for every row (an empty
    # result, not an error), so this reactive still runs and clears the map
    # to blank. req() previously BLOCKED the reactive from re-running at
    # all in that case, silently leaving whatever was last drawn on screen
    # forever — found 2026-08-26 (Jack: unchecking the last remaining
    # status didn't clear it, needed a different checkbox re-toggled first
    # to "unstick" it). Same fix applied to cluster_status() below.
    lga_map_data <- reactive({
      scope_admin2_sf() %>%
        mutate(
          pct_achieved = coalesce(pct_achieved, 0),
          fill_color = pct_color(pct_achieved),
          label_pct = fmt_pct(pct_achieved),
          status = case_when(
            target_sample <= 0 | achieved_n >= target_sample ~ "Complete",
            achieved_n > 0 ~ "In progress",
            TRUE ~ "Not started"
          ),
          partner_coverage = vapply(adm2_pcode, partner_coverage_label, character(1))
        ) %>%
        left_join(accessibility_lga_summary, by = "adm2_pcode") %>%
        left_join(remaining_by_pop_type(), by = "adm2_pcode") %>%
        filter(status %in% input$status_filter)
    })

    # accessibility layer — scoped to the same in-scope LGAs as the ward
    # boundary reference layer below, so a state/LGA filter selection
    # narrows it consistently with everything else on the map. Deliberately
    # NOT reactive to the status_filter checkboxes above (a different,
    # unrelated status vocabulary — achieved/in-progress/not-started vs.
    # accessible/inaccessible) or to filtered_subs()'s date range (accessibility
    # status isn't a submissions-derived figure).
    #
    # FIXED 2026-08-28: this used to ignore pop_type entirely - both the
    # Population group sidebar filter (unlike psu_hex_in_scope/psu_sites_
    # in_scope below, which already respect it) and the fact that a dual-
    # eligible ward has two rows here (Non-IDP + IDP, identical geometry -
    # see analysis_accessible_area_layer.R's header). Status/reporting/
    # covering-partner attributes are pop-type-blind by construction (the
    # underlying partner-to-LGA assignment is LGA-grain only - confirmed via
    # analysis_partner_coverage.py, it is structurally impossible for the two
    # rows of one ward to disagree), so rendering both was always pure
    # redundant overdraw, not a risk of showing conflicting information -
    # still worth collapsing to one polygon per ward rather than drawing the
    # same shape twice. accessibility_sf$pop_type uses "Non-IDP"/"IDP"
    # labels; filtered_stratum()$pop_type uses the raw "non_idp"/"idp" codes
    # psu_hex_in_scope/psu_sites_in_scope compare against directly - mapped
    # here since this is the one place that needs both forms at once.
    accessibility_map_data <- reactive({
      s <- filtered_stratum()
      lgas <- unique(s$adm2_pcode)
      pop_labels <- ifelse(unique(s$pop_type) == "non_idp", "Non-IDP", "IDP")
      accessibility_sf %>%
        filter(adm2_pcode %in% lgas, pop_type %in% pop_labels) %>%
        distinct(adm2_pcode, wardname, .keep_all = TRUE)
    })

    psu_hex_in_scope <- reactive({
      s <- filtered_stratum()
      psu_hexagons_sf %>% filter(adm2_pcode %in% unique(s$adm2_pcode), pop_type %in% unique(s$pop_type))
    })

    psu_sites_in_scope <- reactive({
      s <- filtered_stratum()
      psu_sites_sf %>% filter(adm2_pcode %in% unique(s$adm2_pcode), pop_type %in% unique(s$pop_type))
    })

    # per-cluster achieved counts, from filtered_subs (so — unlike the LGA
    # view, which mirrors the Progress by LGA table's non-date-filtered
    # figures — this respects the date-range filter too). Uses is_achieved()
    # (global.R's single canonical "achieved" definition — completed, not a
    # duplicate, AND matched_survey_id present) rather than hand-rolling the
    # condition; the previous version here checked matched_cluster_id instead
    # of matched_survey_id, which is a materially different (weaker) test and
    # is exactly the kind of drift global.R's comment on is_achieved() warns
    # against. !is.na(matched_cluster_id) is kept as an ADDITIONAL condition,
    # not a replacement — it's needed for the count(matched_cluster_id) grain
    # itself (nothing to attribute to a hexagon without it), not as the
    # achieved test.
    cluster_achieved <- reactive({
      subs <- filtered_subs()
      subs[is_achieved(subs) & !is.na(subs$matched_cluster_id), ] %>%
        count(matched_cluster_id, name = "achieved_n")
    })

    cluster_status <- function(psu_sf) {
      psu_sf %>%
        left_join(cluster_achieved(), by = c("cluster_id" = "matched_cluster_id")) %>%
        mutate(
          achieved_n = coalesce(achieved_n, 0L),
          target_households = as.numeric(target_households),
          status = case_when(
            achieved_n >= target_households ~ "Complete",
            achieved_n > 0 ~ "In progress",
            TRUE ~ "Not started"
          ),
          fill_color = unname(STATUS_COLORS[status]),
          # Same definition as reports_partner_digest.R's compute_oversampled_
          # clusters() (target_households > 0 & achieved_n > target) — always
          # a subset of "Complete", never a sibling status, so it's drawn as a
          # border on top of the existing fill rather than a 4th status/colour
          # or its own filter checkbox (which couldn't sit alongside the
          # existing Complete/In progress/Not started group cleanly, and would
          # make an issue we want caught passively into one you have to
          # remember to go looking for).
          oversampled = target_households > 0 & achieved_n > target_households,
          label_pct = fmt_pct(ifelse(target_households > 0, achieved_n / target_households, NA_real_)),
          partner_coverage = vapply(adm2_pcode, partner_coverage_label, character(1))
        ) %>%
        filter(status %in% input$status_filter)
    }

    cluster_hex_data <- reactive(cluster_status(psu_hex_in_scope()))
    cluster_site_data <- reactive(cluster_status(psu_sites_in_scope()))

    # ---- zoom-to-extent: fit the map to whatever's currently in scope ------
    scope_bbox <- reactive({
      sf_data <- scope_admin2_sf()
      if (nrow(sf_data) == 0) return(NULL)
      bb <- sf::st_bbox(sf_data)
      if (any(!is.finite(bb))) return(NULL)
      bb
    })

    output$map <- renderLeaflet({
      leaflet(options = leafletOptions(minZoom = 5)) %>%
        addProviderTiles("CartoDB.Positron", group = "Light (default)") %>%
        addProviderTiles("Esri.WorldImagery", group = "Satellite") %>%
        setView(lng = 8.0, lat = 9.6, zoom = 6) %>%
        # Explicit panes for every layer, each pinned to a fixed zIndex above
        # the default overlayPane (400) — added 2026-08-26 after Jack found
        # the layers control's actual stacking order was following TOGGLE
        # order (whichever layer was most recently switched on/redrawn
        # landed on top) rather than a stable hierarchy, requiring an
        # untoggle-retoggle dance to get State back above Accessibility.
        # Leaflet's default behaviour is "last drawn wins" within a shared
        # pane (the pre-existing idpSitesPane comment below already notes
        # this for IDP sites vs. hexagons) — assigning every layer its own
        # pane with a fixed zIndex makes the order deterministic regardless
        # of when/how often each layer gets redrawn. Two logics in play,
        # confirmed with Jack:
        #  - FILL layers (progress/status/accessibility): finer admin grain
        #    on top, so a more specific fill is never hidden by a coarser
        #    one drawn after it — LGA progress (admin2) < Accessibility
        #    (admin3 ward) < Cluster status (PSU/cluster, finest).
        #  - OUTLINE/reference layers (State/LGA/Ward boundaries, PSU
        #    reference): the OPPOSITE — coarser admin boundary on top,
        #    since these are unfilled lines that only need to stay visible
        #    over whatever's beneath, not avoid being hidden themselves —
        #    PSU reference (cluster grain) < Ward < LGA < State (topmost).
        # idpSitesPane (existing, unchanged) stays above everything: IDP
        # site status markers should never be buried regardless of view.
        addMapPane("lgaProgressPane", zIndex = 401) %>%
        addMapPane("accessibilityPane", zIndex = 402) %>%
        addMapPane("clusterStatusPane", zIndex = 403) %>%
        addMapPane("psuReferencePane", zIndex = 410) %>%
        addMapPane("wardBoundariesPane", zIndex = 420) %>%
        addMapPane("lgaBoundariesPane", zIndex = 421) %>%
        addMapPane("stateBoundariesPane", zIndex = 422) %>%
        # Sits above every other pane — IDP site markers always render/
        # hover above everything else regardless of which layer last
        # redrew — see the "Cluster status sites" addCircleMarkers call
        # below.
        addMapPane("idpSitesPane", zIndex = 450) %>%
        # non-assessment states: static, always-on, semi-transparent grey
        # context fill — never overlaps assessment data, safe to leave
        # interactive (a "not part of this assessment" tooltip is useful).
        addPolygons(
          data = admin1_sf %>% filter(!in_assessment),
          fillColor = "#9AA3AF", fillOpacity = 0.35, color = "#9AA3AF", weight = 0.5,
          label = ~paste0(adm1_name, " (not part of this assessment)")
        ) %>%
        # Nigeria national outline — static, always on, non-interactive so
        # it never intercepts hover/labels from layers underneath.
        addPolygons(
          data = admin0_sf, fill = FALSE, color = "#0D1526", weight = 2, opacity = 0.8,
          options = pathOptions(interactive = FALSE)
        ) %>%
        addLayersControl(
          baseGroups = c("Light (default)", "Satellite"),
          overlayGroups = c("State boundaries", "LGA boundaries", "Ward boundaries", "Accessibility", "PSU hexagons (reference)", "PSU sites (reference)"),
          options = layersControlOptions(collapsed = FALSE)
        ) %>%
        hideGroup(c("LGA boundaries", "Ward boundaries", "Accessibility", "PSU hexagons (reference)", "PSU sites (reference)", "Cluster status", "Cluster status sites")) %>%
        # Ward boundaries / PSU hexagons / PSU sites are off by default and,
        # until 2026-08-17, had their (multi-MB) geometry computed and sent
        # to EVERY Coverage Map visitor regardless of whether that layer was
        # ever actually switched on — hideGroup() above only hides it with
        # CSS after the data has already crossed the wire. The leaflet R
        # package doesn't expose the layers control's checkbox toggles as a
        # Shiny input on its own, so this listens for Leaflet's native
        # 'overlayadd' event directly and forwards the toggled group's name
        # into a real input (input$layer_toggled below) the server can react
        # to — the same "only pay for what's actually used" idea as
        # map_tab_active(), just for a sub-layer instead of a whole tab.
        htmlwidgets::onRender(sprintf(
          "function(el, x) {
            this.on('overlayadd', function(e) {
              Shiny.setInputValue('%s', e.name, {priority: 'event'});
            });
          }",
          session$ns("layer_toggled")
        ))
    })
    # Render the base widget immediately at session start even though
    # Coverage Map isn't the first tab shown — otherwise (Shiny's default)
    # rendering is suspended until the tab is first visited, so the very
    # first leafletProxy() call below would target a map that doesn't exist
    # in the browser yet and be silently dropped. That was the cause of the
    # original "blank until you touch a filter" / "PSU shown by default"
    # bugs. This is a cheap, one-time render (empty base map + static
    # context layers only) — it's the PER-FILTER leafletProxy layer
    # redraws below that are expensive, and those are separately gated on
    # map_tab_active() (see the comment above the first observe() block)
    # so they still don't pay any cost until the tab is actually visited.
    outputOptions(output, "map", suspendWhenHidden = FALSE)

    # Tracks which off-by-default overlay groups have actually been
    # switched on at least once this session, via the 'overlayadd' listener
    # attached above. Persists once TRUE (no reason to stop computing a
    # layer the user has already asked to see once) — same "sticky, not
    # re-armed" spirit as filter_touched in app.R.
    layer_shown <- reactiveValues(ward = FALSE, lga_boundaries = FALSE, accessibility = FALSE, psu_hex = FALSE, psu_sites = FALSE)
    observeEvent(input$layer_toggled, {
      nm <- input$layer_toggled
      if (identical(nm, "Ward boundaries")) layer_shown$ward <- TRUE
      if (identical(nm, "LGA boundaries")) layer_shown$lga_boundaries <- TRUE
      if (identical(nm, "Accessibility")) layer_shown$accessibility <- TRUE
      if (identical(nm, "PSU hexagons (reference)")) layer_shown$psu_hex <- TRUE
      if (identical(nm, "PSU sites (reference)")) layer_shown$psu_sites <- TRUE
    })

    # ---- fill layers (z-order above/below the boundary layers further
    # down is fixed by panes, not by this registration order — see the pane
    # setup comment in renderLeaflet() above) --------------------------------
    #
    # Every observer below starts with req(map_tab_active()) — reading it
    # FIRST, before anything else, means it's the ONLY dependency this
    # observer has while the Coverage Map tab is hidden (req() stops
    # execution before any of the expensive reactives below are even
    # touched), so filter changes elsewhere don't cost anything here until
    # the user actually looks at this tab. The moment map_tab_active()
    # flips TRUE, Shiny re-runs the observer, req() passes, and it reads
    # the (already-current) reactive — which then becomes a tracked
    # dependency again for as long as the tab stays visible. Net effect:
    # zero redraw cost while hidden, exactly one fresh redraw the instant
    # the tab becomes visible, and normal live updates while it stays
    # visible — no behaviour change from the user's point of view, just
    # not paying for it on every filter click made on a different tab.
    #
    # Two more gates layer on top of that same idea, added 2026-08-17 after
    # a partner-reported "weak internet, laggy dashboard" review found both
    # of the below were being computed and sent regardless of whether
    # they'd ever be looked at:
    #   - The "LGA progress" vs "Cluster status"/"Cluster status sites" fill
    #     observers now also req() on input$map_view, so only whichever
    #     view is actually selected gets computed — switching the toggle
    #     used to reveal/hide a layer that was already fully computed both
    #     ways every time; now only the active one is.
    #   - The "Ward boundaries" / "PSU hexagons (reference)" / "PSU sites
    #     (reference)" observers further down now also req() on the
    #     matching layer_shown flag above, so — since all three are off by
    #     default — their (multi-MB, even after the 2026-08-17 coordinate-
    #     precision fix in global.R) geometry is never sent at all unless
    #     the user actually opens the layers control and switches one on.

    observe({
      req(map_tab_active())
      req(input$map_view == "lga")
      md <- lga_map_data()
      leafletProxy("map", data = md) %>%
        clearGroup("LGA progress") %>%
        addPolygons(
          fillColor = ~fill_color,
          fillOpacity = 0.75,
          color = "#FFFFFF",
          weight = 0.5,
          group = "LGA progress",
          options = pathOptions(pane = "lgaProgressPane"),
          label = ~lapply(
            paste0(
              "<b>", adm2_name, "</b>, ", adm1_name, "<br>",
              "Partner(s): ", partner_coverage, "<br>",
              "Achieved: ", coalesce(achieved_n, 0), " / ", coalesce(target_sample, 0),
              " (", label_pct, ")<br>",
              "Collected: ", coalesce(collected_n, 0), "<br>",
              "Samples required: ", coalesce(remaining_idp, 0), " IDPs | ", coalesce(remaining_non_idp, 0), " Non-IDPs<br>",
              "Inaccessible ward portions: ", coalesce(n_ward_portions_inaccessible, 0), " of ", coalesce(n_ward_portions, 0), "<br>",
              # gsub to <br> here (not baked into pop_remaining_label
              # itself, global.R) keeps that label plain text/display-
              # agnostic in case something non-HTML (an export) ever reuses
              # it — the two-lines-in-a-popup formatting is a UI concern.
              "Population remaining accessible:<br>", gsub(" | ", "<br>", coalesce(pop_remaining_label, "n/a"), fixed = TRUE)
            ),
            htmltools::HTML
          ),
          highlightOptions = highlightOptions(weight = 2, color = "#333", bringToFront = TRUE)
        )
    })

    observe({
      req(map_tab_active())
      req(input$map_view == "cluster")
      hexes <- cluster_hex_data()
      leafletProxy("map", data = hexes) %>%
        clearGroup("Cluster status") %>%
        addPolygons(
          fillColor = ~fill_color,
          fillOpacity = 0.85,
          # Deliberately NOT red (STATUS_COLORS["Not started"] is already
          # that colour in this exact legend) — a same-hue border+fill pair
          # in one legend reads as "which one is it?", and red-vs-red is a
          # particularly bad pair for red-green colourblindness on top of
          # that. OVERSAMPLED_BORDER (global.R) is purple: unmistakable
          # against the green "Complete" fill it always sits on, and against
          # every other colour already in play on this map.
          color = ~ifelse(oversampled, OVERSAMPLED_BORDER, "#FFFFFF"),
          weight = ~ifelse(oversampled, 4, 0.5), # bumped from 3 (2026-08-24, per Jack — wasn't clear enough)
          group = "Cluster status",
          options = pathOptions(pane = "clusterStatusPane"),
          label = ~lapply(
            paste0(
              "<b>", cluster_id, "</b><br>", adm2_name, ", ", adm1_name, "<br>",
              "Achieved: ", achieved_n, " / ", target_households, " (", label_pct, ")<br>",
              "Status: ", status, "<br>",
              ifelse(oversampled, paste0("<b style='color:", OVERSAMPLED_BORDER, ";'>&#9888; Oversampled by ", achieved_n - target_households, "</b><br>"), ""),
              "Partner(s): ", partner_coverage
            ),
            htmltools::HTML
          ),
          highlightOptions = highlightOptions(weight = 2, color = "#333", bringToFront = TRUE)
        )
    })

    observe({
      req(map_tab_active())
      req(input$map_view == "cluster")
      sites <- cluster_site_data()
      leafletProxy("map", data = sites) %>%
        clearGroup("Cluster status sites") %>%
        addCircleMarkers(
          radius = 6,
          fillColor = ~fill_color,
          fillOpacity = 0.9,
          color = ~ifelse(oversampled, OVERSAMPLED_BORDER, "#333333"),
          weight = ~ifelse(oversampled, 4, 1), # bumped from 3 (2026-08-24, per Jack — wasn't clear enough)
          stroke = TRUE,
          group = "Cluster status sites",
          # Own pane, above the default overlayPane hexagons/polygons share —
          # otherwise these IDP site points can end up buried under a
          # non-IDP hexagon whenever the hexagon layer happens to be
          # redrawn (clearGroup + re-add) more recently, since same-pane
          # z-order follows draw order, not just initial code order.
          options = pathOptions(pane = "idpSitesPane"),
          label = ~lapply(
            paste0(
              "<b>", coalesce(iom_site_name, cluster_id), "</b><br>", adm2_name, ", ", adm1_name, "<br>",
              "Achieved: ", achieved_n, " / ", target_households, " (", label_pct, ")<br>",
              "Status: ", status, "<br>",
              ifelse(oversampled, paste0("<b style='color:", OVERSAMPLED_BORDER, ";'>&#9888; Oversampled by ", achieved_n - target_households, "</b><br>"), ""),
              "Partner(s): ", partner_coverage
            ),
            htmltools::HTML
          )
        )
    })

    # ---- accessibility reference layer (always available, off by default) -
    # Filled (unlike the outline-only Ward/PSU reference layers) since the
    # whole point is a visible accessible/inaccessible distinction at a
    # glance. Fully opaque (fillOpacity = 1, per Jack 2026-08-26 — a partial
    # fill visually distorted the two colours) — this is used as a standalone
    # toggle layer, not shown blended with the LGA/cluster status fill.
    observe({
      req(map_tab_active())
      req(layer_shown$accessibility)
      leafletProxy("map", data = accessibility_map_data()) %>%
        clearGroup("Accessibility") %>%
        addPolygons(
          group = "Accessibility",
          fillColor = ~ifelse(accessible_status == "Inaccessible", "#C1443C", "#4C9A6A"),
          fillOpacity = 1,
          color = "#FFFFFF",
          weight = 0.5,
          options = pathOptions(pane = "accessibilityPane"),
          label = ~lapply(
            paste0(
              "<b>", wardname, "</b>, ", adm2_name, ", ", adm1_name, "<br>",
              "Status: ", accessible_status,
              # Three distinct source states now (2026-08-28) - a real partner
              # report needs no caveat; the plain default needs the generic
              # caveat; a pending ad-hoc proposal (see analysis_accessible_
              # area_layer.R's pending_adhoc_proposals.csv override) needs its
              # own wording, since "(default - not yet reported)" attached to
              # an Inaccessible status reads as contradictory otherwise.
              dplyr::case_when(
                status_source == "confirmed_by_partner_report" ~ "",
                status_source == "pending_adhoc_proposal_response" ~ " (pending partner response to an ad-hoc proposal - see resampling/input/ad_hoc_reports/)",
                TRUE ~ " (default — not yet reported)"
              ), "<br>",
              # Reported by (someone has actually told us something about this ward) takes priority;
              # when nobody has, fall back to who's assigned to cover it (2026-08-28) - "Reported by"
              # being blank previously read as "nobody's responsible" rather than "nobody's told us yet".
              ifelse(nzchar(reporting_partner_label), paste0("Reported by: ", reporting_partner_label, "<br>"),
                     ifelse(nzchar(covering_partner_label), paste0("Covered by: ", covering_partner_label, "<br>"), "")),
              ifelse(!is.na(reason_category) & reason_category != "N/A - fully accessible", paste0("Reason: ", reason_category, "<br>"), "")
            ),
            htmltools::HTML
          ),
          highlightOptions = highlightOptions(weight = 2, color = "#333", bringToFront = TRUE)
        )
    })

    # ---- reference PSU outline layers (always available, off by default) --
    observe({
      req(map_tab_active())
      req(layer_shown$psu_hex)
      leafletProxy("map", data = psu_hex_in_scope()) %>%
        clearGroup("PSU hexagons (reference)") %>%
        addPolygons(
          group = "PSU hexagons (reference)", fill = FALSE, color = "#2A4D8F", weight = 1, opacity = 0.8,
          options = pathOptions(pane = "psuReferencePane"),
          label = ~lapply(paste0("<b>", cluster_id, "</b><br>", adm2_name, ", ", adm1_name, "<br>Target HH: ", target_households), htmltools::HTML)
        )
    })

    observe({
      req(map_tab_active())
      req(layer_shown$psu_sites)
      leafletProxy("map", data = psu_sites_in_scope()) %>%
        clearGroup("PSU sites (reference)") %>%
        addCircleMarkers(
          group = "PSU sites (reference)", radius = 5, color = "#8B4A4A", fillOpacity = 0.8, stroke = TRUE, weight = 1,
          # Own pane (not idpSitesPane — that one's reserved for the
          # achieved-status "Cluster status sites" fill layer, see its own
          # comment) but still deliberately below it (410 < 450), so an
          # IDP site's live status marker is never buried under this
          # reference-only outline layer if both happen to be on at once.
          options = pathOptions(pane = "psuReferencePane"),
          label = ~lapply(paste0("<b>", coalesce(iom_site_name, cluster_id), "</b><br>", adm2_name, ", ", adm1_name, "<br>Target HH: ", target_households), htmltools::HTML)
        )
    })

    # ---- boundary layers — z-order above the fill layers is guaranteed by
    # their panes (stateBoundariesPane/lgaBoundariesPane/wardBoundariesPane,
    # all > the fill panes above), not by registration order — see the pane
    # setup comment in renderLeaflet() above (2026-08-26). State boundaries
    # are additionally drawn non-interactive (`interactive = FALSE`) so
    # sitting above the LGA/cluster fill doesn't block those layers' hover
    # labels; only the (invisible) stroke path would ever have intercepted
    # anything, and now it can't intercept at all. --------------------------

    observe({
      req(map_tab_active())
      in_scope <- scope_state_pcodes()
      assessment_states <- admin1_sf %>%
        filter(in_assessment) %>%
        mutate(is_selected = adm1_pcode %in% in_scope)

      leafletProxy("map", data = assessment_states) %>%
        clearGroup("State boundaries") %>%
        addPolygons(
          fill = FALSE,
          color = ~ifelse(is_selected, "#1B2A4A", "#8FA0BF"),
          weight = ~ifelse(is_selected, 2.2, 1),
          opacity = ~ifelse(is_selected, 0.9, 0.5),
          group = "State boundaries",
          options = pathOptions(interactive = FALSE, pane = "stateBoundariesPane")
        )
    })

    observe({
      req(map_tab_active())
      req(layer_shown$lga_boundaries)
      leafletProxy("map", data = scope_admin2_sf()) %>%
        clearGroup("LGA boundaries") %>%
        addPolygons(
          fill = FALSE, color = "#3E5A8C", weight = 1, opacity = 0.8, group = "LGA boundaries",
          options = pathOptions(pane = "lgaBoundariesPane"),
          label = ~lapply(paste0("<b>", adm2_name, "</b>, ", adm1_name), htmltools::HTML)
        )
    })

    observe({
      req(map_tab_active())
      req(layer_shown$ward)
      lgas <- scope_lga_names()
      w <- wards_sf %>% filter(lganame %in% lgas)
      leafletProxy("map", data = w) %>%
        clearGroup("Ward boundaries") %>%
        addPolygons(
          fill = FALSE, color = "#6B5B95", weight = 0.7, opacity = 0.7, group = "Ward boundaries",
          options = pathOptions(pane = "wardBoundariesPane"),
          label = ~lapply(paste0("<b>", wardname, "</b><br>", lganame, ", ", statename), htmltools::HTML)
        )
    })

    observe({
      req(map_tab_active())
      bb <- scope_bbox()
      if (is.null(bb)) return()
      leafletProxy("map") %>% fitBounds(lng1 = bb[["xmin"]], lat1 = bb[["ymin"]], lng2 = bb[["xmax"]], lat2 = bb[["ymax"]])
    })

    # ---- view toggle: swap which fill layer + legend is visible -----------
    observeEvent(input$map_view, {
      proxy <- leafletProxy("map") %>% removeControl("map_legend")
      if (input$map_view == "lga") {
        proxy %>%
          hideGroup(c("Cluster status", "Cluster status sites")) %>%
          showGroup("LGA progress") %>%
          addLegend(
            layerId = "map_legend", position = "bottomright",
            colors = c("#C1443C", "#D99A2B", "#4C9A6A", "#1E7B4D", "#9AA3AF"),
            labels = c("<35%", "35-75%", "75-100%", "100%+", "No data"),
            title = "% of target achieved (LGA)", opacity = 0.9
          )
      } else {
        proxy %>%
          hideGroup("LGA progress") %>%
          showGroup(c("Cluster status", "Cluster status sites")) %>%
          addLegend(
            layerId = "map_legend", position = "bottomright",
            colors = c(unname(STATUS_COLORS), OVERSAMPLED_BORDER),
            # The 4th entry's swatch renders as a filled square like the
            # other three, not an actual outline — addLegend() can't render
            # a border-only swatch — hence spelling out "outline" in the
            # label itself so it isn't read as a 4th fill status.
            labels = c(names(STATUS_COLORS), "Oversampled (purple outline)"),
            title = "Cluster status", opacity = 0.9
          )
      }
    })
  })
}
