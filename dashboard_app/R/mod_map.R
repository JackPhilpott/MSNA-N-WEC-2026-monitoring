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
            info_icon("Fill colour and \"% of target\" reflect ACHIEVED — capped at each cluster's own target, so oversampling can't count toward or mask under-coverage elsewhere. Hover a cluster/LGA for its COLLECTED figure too (every completed interview, including oversampled surplus).")
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

    lga_map_data <- reactive({
      req(input$status_filter)
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
        filter(status %in% input$status_filter)
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
      req(input$status_filter)
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
        # Sits above the default overlayPane (zIndex 400) that polygons use,
        # so IDP site markers always render/hover above non-IDP hexagons
        # regardless of which layer last redrew — see the "Cluster status
        # sites" addCircleMarkers call below.
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
          overlayGroups = c("State boundaries", "Ward boundaries", "PSU hexagons (reference)", "PSU sites (reference)"),
          options = layersControlOptions(collapsed = FALSE)
        ) %>%
        hideGroup(c("Ward boundaries", "PSU hexagons (reference)", "PSU sites (reference)", "Cluster status", "Cluster status sites")) %>%
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
    layer_shown <- reactiveValues(ward = FALSE, psu_hex = FALSE, psu_sites = FALSE)
    observeEvent(input$layer_toggled, {
      nm <- input$layer_toggled
      if (identical(nm, "Ward boundaries")) layer_shown$ward <- TRUE
      if (identical(nm, "PSU hexagons (reference)")) layer_shown$psu_hex <- TRUE
      if (identical(nm, "PSU sites (reference)")) layer_shown$psu_sites <- TRUE
    })

    # ---- fill layers (registered first, so boundary layers added below
    # land on top of them in z-order) --------------------------------------
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
          label = ~lapply(
            paste0(
              "<b>", adm2_name, "</b>, ", adm1_name, "<br>",
              "Achieved: ", coalesce(achieved_n, 0), " / ", coalesce(target_sample, 0),
              " (", label_pct, ")<br>",
              "Collected: ", coalesce(collected_n, 0), "<br>",
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

    # ---- reference PSU outline layers (always available, off by default) --
    observe({
      req(map_tab_active())
      req(layer_shown$psu_hex)
      leafletProxy("map", data = psu_hex_in_scope()) %>%
        clearGroup("PSU hexagons (reference)") %>%
        addPolygons(
          group = "PSU hexagons (reference)", fill = FALSE, color = "#2A4D8F", weight = 1, opacity = 0.8,
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
          options = pathOptions(pane = "idpSitesPane"),
          label = ~lapply(paste0("<b>", coalesce(iom_site_name, cluster_id), "</b><br>", adm2_name, ", ", adm1_name, "<br>Target HH: ", target_households), htmltools::HTML)
        )
    })

    # ---- boundary layers, registered AFTER the fill layers above so they
    # redraw on top of them (Shiny fires simultaneously-invalidated
    # observers in registration order) — state boundaries are drawn
    # non-interactive (`interactive = FALSE`) specifically so bringing them
    # above the LGA/cluster fill doesn't block those layers' hover labels;
    # only the (invisible) stroke path would ever have intercepted anything,
    # and now it can't intercept at all. ------------------------------------

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
          options = pathOptions(interactive = FALSE)
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
