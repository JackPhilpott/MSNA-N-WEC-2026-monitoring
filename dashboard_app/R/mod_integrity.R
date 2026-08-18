# Data Integrity Checks tab: deeper diagnostics beyond the core review
# flags — signals that suggest rushing, digit preference, or fabrication,
# aimed at the technical supervisor. None of these prove wrongdoing on
# their own (a busy day, a coincidence, a genuine local age-reporting
# pattern are all possible innocent explanations) — they're leads, not
# verdicts.

mod_integrity_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Data Integrity Checks",
    icon = icon("magnifying-glass-chart"),
    layout_columns(
      col_widths = c(3, 3, 3, 3),
      value_box(title = "Exact GPS-duplicate submissions", value = textOutput(ns("kpi_gps_dup")), showcase = icon("location-dot"), theme = "danger"),
      value_box(title = "Off-hours submissions", value = textOutput(ns("kpi_off_hours")), showcase = icon("moon"), theme = "warning"),
      value_box(title = "Age-heaping (Whipple's Index)", value = textOutput(ns("kpi_whipple")), showcase = icon("chart-column"), theme = "warning"),
      value_box(title = "Enumerator-days over plausible max", value = textOutput(ns("kpi_overmax")), showcase = icon("triangle-exclamation"), theme = "danger")
    ),
    layout_columns(
      col_widths = c(6, 6),
      card(
        card_header("Submission time-of-day"),
        plotlyOutput(ns("hour_hist"), height = "380px")
      ),
      card(
        card_header("Interview duration distribution"),
        plotlyOutput(ns("duration_hist"), height = "380px")
      )
    ),
    layout_columns(
      col_widths = c(6, 6),
      card(
        card_header("Respondent age distribution (heaping check)", span(class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;", "Spikes at multiples of 5 indicate rounding, not real ages.")),
        plotlyOutput(ns("age_hist"), height = "380px")
      ),
      card(
        card_header("Whipple's Index by enumerator (top 15 highest)"),
        plotlyOutput(ns("whipple_by_enum"), height = "380px")
      )
    ),
    navset_card_tab(
      nav_panel(
        "Exact GPS-duplicate groups",
        p(class = "text-muted", "Submissions sharing bit-identical GPS coordinates — real jitter essentially never coincides by chance."),
        DTOutput(ns("gps_dup_table"))
      ),
      nav_panel(
        "Implausible daily counts",
        p(class = "text-muted", paste0("Enumerator-days with more than ", MAX_PLAUSIBLE_INTERVIEWS_PER_DAY, " completed interviews (given ~40min avg. duration).")),
        DTOutput(ns("overmax_table"))
      )
    )
  )
}

mod_integrity_server <- function(id, filtered_subs) {
  moduleServer(id, function(input, output, session) {
    gps_dups <- reactive(find_gps_duplicate_groups(filtered_subs()))

    output$kpi_gps_dup <- renderText(comma(sum(gps_dups()$n_submissions)))
    output$kpi_off_hours <- renderText({
      df <- filtered_subs()
      paste0(comma(sum(df$flag_off_hours)), " (", fmt_pct(mean(df$flag_off_hours)), ")")
    })
    output$kpi_whipple <- renderText({
      w <- whipples_index(filtered_subs()$resp_age)
      paste0(round(w), " (", whipples_label(w), ")")
    })

    overmax <- reactive({
      filtered_subs() %>%
        filter(!is_duplicate) %>%
        count(enum_id, submission_date, name = "n") %>%
        filter(n > MAX_PLAUSIBLE_INTERVIEWS_PER_DAY) %>%
        arrange(desc(n))
    })
    output$kpi_overmax <- renderText(comma(nrow(overmax())))

    output$hour_hist <- renderPlotly({
      df <- bin_integer_counts(hour(filtered_subs()$start_datetime), 0, 23)
      plot_ly(df, x = ~value, y = ~n, type = "bar", marker = list(color = "#4C7FD9")) %>%
        layout(
          xaxis = list(title = "Hour of day", dtick = 2),
          yaxis = list(title = "Submissions"),
          bargap = 0,
          shapes = list(
            list(type = "rect", x0 = -0.5, x1 = 5.5, y0 = 0, y1 = 1, yref = "paper", fillcolor = "#C1443C", opacity = 0.08, line = list(width = 0)),
            list(type = "rect", x0 = 18.5, x1 = 23.5, y0 = 0, y1 = 1, yref = "paper", fillcolor = "#C1443C", opacity = 0.08, line = list(width = 0))
          )
        )
    })

    output$duration_hist <- renderPlotly({
      df <- bin_continuous_counts(filtered_subs()$duration_min, bins = 40)
      plot_ly(df, x = ~center, y = ~n, type = "bar", marker = list(color = "#4C9A6A")) %>%
        layout(xaxis = list(title = "Duration (min)"), yaxis = list(title = "Submissions"), bargap = 0)
    })

    output$age_hist <- renderPlotly({
      df <- bin_integer_counts(filtered_subs()$resp_age, 18, 90)
      plot_ly(df, x = ~value, y = ~n, type = "bar", marker = list(color = "#D99A2B")) %>%
        layout(xaxis = list(title = "Respondent age"), yaxis = list(title = "Count"), bargap = 0)
    })

    output$whipple_by_enum <- renderPlotly({
      df <- filtered_subs() %>%
        group_by(enum_id) %>%
        summarise(w = whipples_index(resp_age), n = sum(!is.na(resp_age)), .groups = "drop") %>%
        filter(n >= 15) %>%
        arrange(desc(w)) %>%
        head(15)
      if (nrow(df) == 0) return(plotly_empty())
      plot_ly(df, x = ~w, y = ~reorder(enum_id, w), type = "bar", orientation = "h", marker = list(color = "#D99A2B")) %>%
        layout(xaxis = list(title = "Whipple's Index"), yaxis = list(title = ""))
    })

    output$gps_dup_table <- renderDT({
      datatable(gps_dups(), rownames = FALSE, options = list(pageLength = 15))
    })

    output$overmax_table <- renderDT({
      df <- overmax() %>% rename(Enumerator = enum_id, Date = submission_date, `Interviews that day` = n)
      datatable(df, rownames = FALSE, options = list(pageLength = 15))
    })
  })
}
