# Progress Overview tab: national/regional KPI tiles + daily submissions
# trend. Pop-type series (daily trend stack, region-progress bars) use the
# global POP_TYPE_COLORS/COMBINED_COLOR/UNMATCHED_COLOR for a consistent
# theme with the rest of the dashboard.

mod_progress_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Progress Overview",
    icon = icon("gauge-high"),
    layout_columns(
      col_widths = c(3, 3, 3, 3),
      value_box(
        title = "Interviews achieved / planned",
        value = textOutput(ns("kpi_achieved")),
        showcase = icon("clipboard-check"),
        theme = "primary"
      ),
      value_box(
        title = "% of target",
        value = textOutput(ns("kpi_pct")),
        showcase = icon("percent"),
        theme = "success"
      ),
      value_box(
        title = "Consent refusal rate",
        value = textOutput(ns("kpi_refusal")),
        showcase = icon("hand"),
        theme = "warning"
      ),
      value_box(
        title = "Days remaining (est.)",
        value = textOutput(ns("kpi_days_remaining")),
        showcase = icon("calendar-days"),
        theme = "secondary"
      )
    ),
    layout_columns(
      col_widths = c(8, 4),
      card(
        card_header(
          "Daily submissions (by population group) vs. pace needed to finish on time",
          span(
            class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;",
            "\"Unmatched\" = submissions where the enumerator picked the wrong LGA in-app, so they couldn't be linked to a sampled cluster (and therefore a pop. group) — see the Data Quality tab's LGA-mismatch flag."
          )
        ),
        plotlyOutput(ns("trend_plot"), height = "460px")
      ),
      card(
        card_header("Progress by region", span(class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;", "Non-IDP / IDP / combined")),
        plotlyOutput(ns("region_plot"), height = "460px")
      )
    )
  )
}

mod_progress_server <- function(id, filtered_subs, filtered_stratum) {
  moduleServer(id, function(input, output, session) {
    completed_subs <- reactive({
      filtered_subs() %>% filter(interview_outcome == "completed", !is_duplicate)
    })

    output$kpi_achieved <- renderText({
      s <- filtered_stratum()
      # matched-only achieved (filtered_stratum()$achieved_n), same
      # definition "% of target" below uses — completed_subs() below
      # deliberately includes unmatched rows too (the trend chart needs
      # them, to show the "Unmatched" bar), so it must NOT be the source
      # for this tile, or the achieved count here would run ahead of what
      # the % implies whenever any submission fails to match.
      paste0(comma(sum(s$achieved_n, na.rm = TRUE)), " / ", comma(sum(s$target_sample, na.rm = TRUE)))
    })

    output$kpi_pct <- renderText({
      s <- filtered_stratum()
      tgt <- sum(s$target_sample, na.rm = TRUE)
      ach <- sum(s$achieved_n, na.rm = TRUE)
      fmt_pct(if (tgt > 0) ach / tgt else NA_real_)
    })

    output$kpi_refusal <- renderText({
      df <- filtered_subs()
      denom <- sum(df$interview_outcome %in% c("completed", "consent_refused"))
      num <- sum(df$interview_outcome == "consent_refused")
      fmt_pct(if (denom > 0) num / denom else NA_real_)
    })

    output$kpi_days_remaining <- renderText({
      paste0(days_remaining, " / ", days_total, " days")
    })

    output$trend_plot <- renderPlotly({
      df <- completed_subs()
      if (nrow(df) == 0) return(plotly_empty(type = "scatter", mode = "markers"))

      pop_cats <- c("Non-IDP", "IDP", "Unmatched")
      by_day_pop <- df %>%
        # "Unmatched" means genuinely unmatched (no sampling-frame point
        # linked), checked first — NOT inferred from pop_type being
        # something other than idp/non_idp. The real KoBo tool's pop_type
        # is a required field the enumerator always answers, so an
        # unmatched real submission still reports a real "idp"/"non_idp"
        # value and would otherwise get silently absorbed into one of
        # those two bars instead of flagged Unmatched (this only mattered
        # for the mock data's older simulated tool, which left pop_type
        # blank on an unmatched row instead).
        mutate(pop_cat = case_when(
          is.na(matched_survey_id) ~ "Unmatched",
          pop_type == "non_idp" ~ "Non-IDP",
          pop_type == "idp" ~ "IDP",
          TRUE ~ "Unmatched"
        )) %>%
        count(submission_date, pop_cat, name = "n") %>%
        complete(submission_date = seq(min(df$submission_date), max(df$submission_date), by = "day"), pop_cat = pop_cats, fill = list(n = 0)) %>%
        arrange(submission_date)

      # Cumulative line deliberately excludes the Unmatched bucket — it
      # has to agree with the "achieved" definition used by the KPI tile
      # and % of target above (matched only), even though the bars above
      # it show Unmatched as its own visible series for awareness.
      by_day_total <- by_day_pop %>%
        filter(pop_cat != "Unmatched") %>%
        group_by(submission_date) %>%
        summarise(n = sum(n), .groups = "drop") %>%
        arrange(submission_date) %>%
        mutate(cumulative = cumsum(n))

      target_total <- sum(filtered_stratum()$target_sample, na.rm = TRUE)
      by_day_total$needed_pace <- seq(0, target_total, length.out = nrow(by_day_total))

      cat_colors <- c("Non-IDP" = unname(POP_TYPE_COLORS[["non_idp"]]), "IDP" = unname(POP_TYPE_COLORS[["idp"]]), "Unmatched" = UNMATCHED_COLOR)

      plot_ly()  %>%
        add_bars(
          data = by_day_pop %>% filter(pop_cat == "Non-IDP"), x = ~submission_date, y = ~n,
          name = "Non-IDP", marker = list(color = cat_colors[["Non-IDP"]]), yaxis = "y2"
        ) %>%
        add_bars(
          data = by_day_pop %>% filter(pop_cat == "IDP"), x = ~submission_date, y = ~n,
          name = "IDP", marker = list(color = cat_colors[["IDP"]]), yaxis = "y2"
        ) %>%
        add_bars(
          data = by_day_pop %>% filter(pop_cat == "Unmatched"), x = ~submission_date, y = ~n,
          name = "Unmatched", marker = list(color = cat_colors[["Unmatched"]]), yaxis = "y2"
        ) %>%
        add_lines(data = by_day_total, x = ~submission_date, y = ~cumulative, name = "Cumulative achieved", line = list(color = "#1E7B4D", width = 3)) %>%
        add_lines(data = by_day_total, x = ~submission_date, y = ~needed_pace, name = "Pace needed to finish on time", line = list(color = "#C1443C", dash = "dot")) %>%
        layout(
          barmode = "stack",
          yaxis = list(title = "Cumulative interviews"),
          yaxis2 = list(overlaying = "y", side = "right", title = "Daily submissions", showgrid = FALSE),
          xaxis = list(title = ""),
          legend = list(orientation = "h", y = -0.2),
          hovermode = "x unified",
          margin = list(l = 60, r = 80, t = 20, b = 40)
        )
    })

    output$region_plot <- renderPlotly({
      by_region_pop <- filtered_stratum() %>%
        group_by(region, pop_type) %>%
        summarise(target_sample = sum(target_sample, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(pct = ifelse(target_sample > 0, achieved_n / target_sample, 0), series = unname(POP_TYPE_LABELS[pop_type]))

      combined <- filtered_stratum() %>%
        group_by(region) %>%
        summarise(target_sample = sum(target_sample, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(pct = ifelse(target_sample > 0, achieved_n / target_sample, 0), series = "Combined")

      s <- bind_rows(
        by_region_pop %>% select(region, pct, series),
        combined %>% select(region, pct, series)
      ) %>%
        mutate(series = factor(series, levels = c("Non-IDP", "IDP", "Combined")))

      series_colors <- c("Non-IDP" = unname(POP_TYPE_COLORS[["non_idp"]]), "IDP" = unname(POP_TYPE_COLORS[["idp"]]), "Combined" = COMBINED_COLOR)

      plot_ly(
        s, y = ~region, x = ~pct, color = ~series, colors = series_colors,
        type = "bar", orientation = "h",
        text = ~percent(pct, accuracy = 1), textposition = "outside"
      ) %>%
        layout(
          barmode = "group",
          xaxis = list(title = "% of target achieved", tickformat = ".0%", range = c(0, 1.2)),
          yaxis = list(title = ""),
          legend = list(orientation = "h", y = -0.15),
          margin = list(l = 90, r = 20, t = 20, b = 40)
        )
    })
  })
}
