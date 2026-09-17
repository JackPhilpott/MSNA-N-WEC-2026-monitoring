# Sample Representativeness tab: compares the achieved sample's
# demographic profile against the sampling design's own assumptions
# (there's no external population benchmark available — n_pop/N_hh in the
# strata frame is the design's own household-size assumption, which IS a
# genuine, checkable comparison). Useful for the technical supervisor to
# catch systematic skew (e.g. one gender/age group being under-reached)
# early, while there's still time to course-correct in the field.

mod_representativeness_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Sample Representativeness",
    icon = icon("scale-balanced"),
    layout_columns(
      col_widths = c(3, 3, 3, 3),
      value_box(title = "Design avg. household size", value = textOutput(ns("kpi_design_hh")), showcase = icon("house-chimney"), theme = "secondary"),
      value_box(title = "Achieved avg. household size", value = textOutput(ns("kpi_achieved_hh")), showcase = icon("house-chimney-user"), theme = "primary"),
      value_box(title = "Respondent female %", value = textOutput(ns("kpi_resp_female")), showcase = icon("venus"), theme = "secondary"),
      value_box(title = "Head-of-household male %", value = textOutput(ns("kpi_hoh_male")), showcase = icon("mars"), theme = "secondary")
    ),
    layout_columns(
      col_widths = c(6, 6),
      card(
        card_header("Household size: achieved vs. design assumption"),
        plotlyOutput(ns("hh_size_hist"), height = "400px")
      ),
      card(
        card_header("Setting (rural / urban / camp)"),
        plotlyOutput(ns("setting_bar"), height = "400px")
      )
    ),
    layout_columns(
      col_widths = c(7, 5),
      card(
        card_header("Respondent age-gender pyramid"),
        plotlyOutput(ns("pyramid"), height = "440px")
      ),
      card(
        card_header("Design vs. achieved avg. household size, by region x population group"),
        DTOutput(ns("hh_size_table"))
      )
    )
  )
}

mod_representativeness_server <- function(id, filtered_subs, filtered_stratum) {
  moduleServer(id, function(input, output, session) {
    # matched only — an unmatched submission's pop_type is still a real,
    # enumerator-reported value (see mod_progress.R's trend-chart fix), but
    # it can't be attributed to a specific stratum's design assumptions,
    # which is what every comparison in this tab is built on.
    #
    # 2026-09-14 (Jack, explicit general rule): a Dropped stratum's real
    # data must never enter a national/regional aggregate - this tab's
    # region-level average-HH-size comparison is exactly that kind of
    # aggregate, so a Dropped stratum's real interviews (e.g. Tsafe/
    # idp_NG037013's 54) are excluded here too, not just from the
    # progress/target views.
    completed <- reactive({
      dropped_strata <- unique(filtered_stratum()$strata_id[filtered_stratum()$status == "Dropped"])
      filtered_subs() %>% filter(is_achieved(.), !matched_strata_id %in% dropped_strata)
    })

    design_hh_scope <- reactive({
      strata_frame %>%
        filter(strata_id %in% unique(filtered_stratum()$strata_id)) %>%
        summarise(v = sum(n_pop, na.rm = TRUE) / sum(N_hh, na.rm = TRUE)) %>%
        pull(v)
    })

    output$kpi_design_hh <- renderText(fmt_num(design_hh_scope()))
    output$kpi_achieved_hh <- renderText(fmt_num(mean(completed()$hh_size, na.rm = TRUE)))
    output$kpi_resp_female <- renderText(fmt_pct(mean(completed()$resp_gender == "female", na.rm = TRUE)))
    output$kpi_hoh_male <- renderText(fmt_pct(mean(completed()$hoh_gender == "male", na.rm = TRUE)))

    output$hh_size_hist <- renderPlotly({
      df <- bin_integer_counts(completed()$hh_size, 1, 20)
      plot_ly(df, x = ~value, y = ~n, type = "bar", marker = list(color = "#4C7FD9")) %>%
        layout(
          xaxis = list(title = "Household size"), yaxis = list(title = "Households"),
          bargap = 0,
          shapes = list(list(type = "line", x0 = design_hh_scope(), x1 = design_hh_scope(), y0 = 0, y1 = 1, yref = "paper", line = list(color = "#C1443C", dash = "dash", width = 2))),
          annotations = list(list(x = design_hh_scope(), y = 1, yref = "paper", text = "design avg", showarrow = FALSE, yanchor = "bottom", font = list(color = "#C1443C", size = 11)))
        )
    })

    output$setting_bar <- renderPlotly({
      df <- completed() %>% filter(!is.na(setting)) %>% count(setting) %>% mutate(pct = n / sum(n))
      plot_ly(df, x = ~pct, y = ~reorder(setting, pct), type = "bar", orientation = "h", marker = list(color = "#4C9A6A"),
              text = ~percent(pct, 1), textposition = "outside") %>%
        layout(xaxis = list(title = "% of achieved sample", tickformat = ".0%"), yaxis = list(title = ""))
    })

    output$pyramid <- renderPlotly({
      df <- completed() %>%
        filter(!is.na(resp_age), !is.na(resp_gender)) %>%
        mutate(age_band = cut(resp_age, breaks = c(17, 24, 34, 44, 54, 64, 100), labels = c("18-24", "25-34", "35-44", "45-54", "55-64", "65+"))) %>%
        count(age_band, resp_gender) %>%
        mutate(n_signed = ifelse(resp_gender == "male", -n, n))

      plot_ly() %>%
        add_bars(data = df %>% filter(resp_gender == "male"), x = ~n_signed, y = ~age_band, name = "Male", orientation = "h", marker = list(color = "#4C7FD9")) %>%
        add_bars(data = df %>% filter(resp_gender == "female"), x = ~n_signed, y = ~age_band, name = "Female", orientation = "h", marker = list(color = "#D99A2B")) %>%
        layout(
          barmode = "overlay",
          xaxis = list(title = "Respondents", tickvals = pretty(c(-max(df$n, 1), max(df$n, 1))), ticktext = abs(pretty(c(-max(df$n, 1), max(df$n, 1))))),
          yaxis = list(title = ""),
          legend = list(orientation = "h", y = -0.15)
        )
    })

    output$hh_size_table <- renderDT({
      # admin1 on submissions is a state name; design_avg_hh_size() is
      # region-level (n_pop/N_hh only exists at strata_frame's own
      # region x pop_type grain) — join achieved (by state) to its region
      # via strata_frame's own state->region mapping before aggregating.
      achieved_by_state <- completed() %>%
        group_by(state = admin1, pop_type) %>%
        summarise(achieved_avg_hh_size = mean(hh_size, na.rm = TRUE), n = n(), .groups = "drop")
      state_to_region <- strata_frame %>% distinct(adm1_name, region)
      # Fixed 2026-08-25: was design_avg_hh_size() with no argument, which
      # silently defaults to the full, unfiltered strata_frame — the
      # "Achieved" side above is correctly scoped to filtered_stratum() via
      # completed(), so an active filter was comparing a filtered achieved
      # figure against a national design figure under the same table row.
      # Same scoping pattern kpi_design_hh already uses (design_hh_scope()
      # above) — reused here instead of duplicated.
      design <- design_avg_hh_size(strata_frame %>% filter(strata_id %in% unique(filtered_stratum()$strata_id)))

      df <- achieved_by_state %>%
        left_join(state_to_region, by = c("state" = "adm1_name")) %>%
        group_by(region, pop_type) %>%
        summarise(achieved_avg_hh_size = weighted.mean(achieved_avg_hh_size, n, na.rm = TRUE), n = sum(n), .groups = "drop") %>%
        left_join(design, by = c("region", "pop_type")) %>%
        transmute(
          Region = region,
          `Pop. group` = unname(POP_TYPE_LABELS[pop_type]),
          `Design avg. HH size` = round(design_avg_hh_size, 2),
          `Achieved avg. HH size` = round(achieved_avg_hh_size, 2),
          `Achieved n` = n,
          Difference = round(achieved_avg_hh_size - design_avg_hh_size, 2)
        ) %>%
        arrange(Region, `Pop. group`)

      datatable(df, rownames = FALSE, options = list(pageLength = 10, dom = "t")) %>%
        formatStyle("Difference", color = styleInterval(c(-0.5, 0.5), c("#C1443C", "black", "#C1443C")))
    })
  })
}
