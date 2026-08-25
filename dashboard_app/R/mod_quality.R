# Data Quality tab: core review flags and flagged submissions. Per-
# enumerator performance moved to its own, much richer "Enumerator
# Performance" tab (under Analysis) — enum_id is kept here only as a plain
# identifying column on the flagged-submissions table, not duplicated as a
# full leaderboard.

mod_quality_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Data Quality",
    icon = icon("triangle-exclamation"),
    layout_columns(
      col_widths = c(3, 3, 3, 3),
      value_box(title = "Flagged submissions", value = textOutput(ns("kpi_flagged")), showcase = icon("flag"), theme = "danger"),
      value_box(title = "GPS outliers", value = textOutput(ns("kpi_gps")), showcase = icon("location-crosshairs"), theme = "warning"),
      value_box(title = "Duration outliers", value = textOutput(ns("kpi_duration")), showcase = icon("clock"), theme = "warning"),
      value_box(title = "Likely duplicates", value = textOutput(ns("kpi_dup")), showcase = icon("copy"), theme = "warning")
    ),
    layout_columns(
      col_widths = c(12),
      card(
        card_header("Flags by type"),
        plotlyOutput(ns("flag_plot"), height = "340px")
      )
    ),
    card(
      card_header("Flagged submissions"),
      DTOutput(ns("flagged_table"))
    )
  )
}

mod_quality_server <- function(id, filtered_subs) {
  moduleServer(id, function(input, output, session) {
    output$kpi_flagged <- renderText({
      df <- filtered_subs()
      paste0(comma(sum(df$any_quality_flag)), " (", fmt_pct(mean(df$any_quality_flag)), ")")
    })
    output$kpi_gps <- renderText({ comma(sum(filtered_subs()$flag_gps_outlier)) })
    output$kpi_duration <- renderText({ comma(sum(filtered_subs()$flag_duration_outlier)) })
    output$kpi_dup <- renderText({ comma(sum(filtered_subs()$is_duplicate)) })

    output$flag_plot <- renderPlotly({
      df <- filtered_subs()
      counts <- tibble(
        flag = c("GPS outlier", "Duration outlier", "HH size / roster mismatch", "LGA mismatch", "Duplicate"),
        n = c(sum(df$flag_gps_outlier), sum(df$flag_duration_outlier), sum(df$flag_hh_size_mismatch), sum(df$flag_lga_mismatch), sum(df$is_duplicate))
      ) %>% arrange(n)

      plot_ly(counts, x = ~n, y = ~factor(flag, levels = flag), type = "bar", orientation = "h",
              marker = list(color = "#D99A2B")) %>%
        layout(xaxis = list(title = "Submissions"), yaxis = list(title = ""))
    })

    output$flagged_table <- renderDT({
      yn <- function(x) factor(ifelse(x, "Yes", "No"), levels = c("Yes", "No"))
      df <- filtered_subs() %>%
        filter(any_quality_flag) %>%
        transmute(
          Date = submission_date,
          State = factor(admin1),
          LGA = admin2_submitted,
          Enumerator = enum_id,
          `Duration (min)` = duration_min,
          `GPS dist. (m)` = dist_to_matched_point_m,
          `Match quality` = factor(match_quality),
          # each a factor (Yes/No), not logical — DT's filter="top" only
          # renders a clickable dropdown for factor columns, so this is
          # what lets you filter to e.g. just GPS-outlier rows, or GPS
          # outlier + Duplicate together, directly from the column headers.
          `GPS outlier` = yn(flag_gps_outlier),
          `Duration outlier` = yn(flag_duration_outlier),
          `HH size mismatch` = yn(flag_hh_size_mismatch),
          `LGA mismatch` = yn(flag_lga_mismatch),
          Duplicate = yn(is_duplicate)
        ) %>%
        arrange(desc(Date))

      datatable(df, rownames = FALSE, filter = "top", options = list(pageLength = 15))
    })
  })
}
