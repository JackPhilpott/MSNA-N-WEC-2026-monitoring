# Progress by Stratum/LGA tab: sortable/filterable table of achieved vs
# target per LGA x pop_type, flagging under/over-target strata, reserve
# utilization (a difficulty signal — how much of a stratum's achieved
# sample came from reserve rows, i.e. primary non-response replacements),
# and a naive current-pace ETA vs the fielding deadline.

mod_table_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Progress by LGA",
    icon = icon("table"),
    card(
      full_screen = TRUE,
      card_header(
        "Achieved vs. target, per LGA x population group",
        info_icon("ACHIEVED: completed, matched, non-duplicate, capped at each cluster's own target. COLLECTED: every completed interview, including oversampled surplus and duplicates — total field effort, not what counts toward target."),
        span(
          class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;",
          "ETA assumes each stratum keeps its own achieved-to-date pace — a rough projection, not a commitment."
        )
      ),
      DTOutput(ns("table"))
    )
  )
}

mod_table_server <- function(id, filtered_stratum) {
  moduleServer(id, function(input, output, session) {
    output$table <- renderDT({
      df <- filtered_stratum() %>%
        mutate(
          daily_rate = achieved_n / days_elapsed,
          days_needed = ifelse(daily_rate > 0, (target_sample - achieved_n) / daily_rate, NA_real_),
          eta = as.Date(NA)
        )
      df$eta[!is.na(df$days_needed)] <- (FIELDING_START + days_elapsed) + ceiling(df$days_needed[!is.na(df$days_needed)])
      df <- df %>%
        mutate(
          pace_status = case_when(
            status == "Complete" ~ "Complete",
            is.na(eta) ~ "No progress yet",
            eta <= FIELDING_PLANNED_END ~ "On pace",
            TRUE ~ "Behind pace"
          )
        ) %>%
        transmute(
          Region = factor(region),
          State = factor(adm1_name),
          LGA = adm2_name,
          `Pop. group` = factor(unname(POP_TYPE_LABELS[pop_type])),
          `Partner coverage` = vapply(adm2_pcode, partner_coverage_label, character(1)),
          Target = target_sample,
          Collected = collected_n,
          Achieved = achieved_n,
          `% achieved` = pct_achieved,
          # factor (not character) so DT's column filter row renders a
          # clickable dropdown of the actual levels here, instead of a
          # free-text search box — same for Pop. group/Pace above/below.
          Status = factor(status, levels = names(STATUS_COLORS)),
          `% from reserve` = pct_reserve_used,
          `ETA at current pace` = eta,
          `Pace vs. deadline` = factor(pace_status, levels = c("Behind pace", "On pace", "Complete", "No progress yet"))
        ) %>%
        arrange(`% achieved`)

      datatable(
        df,
        rownames = FALSE,
        filter = "top",
        options = list(
          pageLength = 20,
          # column indices shifted by 1 (2026-08-25) after inserting
          # Partner coverage between Pop. group and Target — 8 is now
          # "% achieved"
          order = list(list(8, "asc")),
          columnDefs = list(list(className = "dt-right", targets = 5:8))
        )
      ) %>%
        formatPercentage(c("% achieved", "% from reserve"), 1) %>%
        formatStyle(
          "Status",
          backgroundColor = styleEqual(names(STATUS_COLORS), unname(STATUS_COLORS)),
          color = styleEqual(names(STATUS_COLORS), c("white", "#1a1a1a", "white"))
        ) %>%
        formatStyle(
          "Pop. group",
          color = styleEqual(unname(POP_TYPE_LABELS), unname(POP_TYPE_COLORS)),
          fontWeight = "bold"
        ) %>%
        formatStyle(
          "Pace vs. deadline",
          color = styleEqual(c("Behind pace", "On pace", "Complete", "No progress yet"), c("#C1443C", "#1E7B4D", "#1E7B4D", "#9AA3AF"))
        ) %>%
        formatStyle(
          "% achieved",
          background = styleColorBar(c(0, 1), "#CFE0F5"),
          backgroundSize = "90% 70%",
          backgroundRepeat = "no-repeat",
          backgroundPosition = "left"
        ) %>%
        formatStyle(
          "% from reserve",
          background = styleColorBar(c(0, max(df$`% from reserve`, 0.01, na.rm = TRUE)), "#F0DCF0"),
          backgroundSize = "90% 70%",
          backgroundRepeat = "no-repeat",
          backgroundPosition = "left"
        )
    })
  })
}
