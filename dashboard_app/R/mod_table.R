# Progress by Stratum/LGA tab: sortable/filterable table of achieved vs
# target per LGA x pop_type, flagging under/over-target strata and reserve
# utilization (a difficulty signal — how much of a stratum's achieved
# sample came from reserve rows, i.e. primary non-response replacements).
#
# ETA/pace columns removed 2026-09-09 (Jack: no longer needed, prioritising
# the Confirmed/Pending Deletion breakdown instead) — the pace-vs-deadline
# view still exists on the Progress Overview tab if that's ever wanted back
# here specifically.

mod_table_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Progress by LGA",
    icon = icon("table"),
    card(
      full_screen = TRUE,
      card_header(
        "Achieved vs. target, per LGA x population group",
        info_icon("ACHIEVED: completed, matched, non-duplicate, not currently flagged for deletion (duration floor, fcs_zero, duplicate point, consent, percentage missing, or a missing HH listing), capped at each cluster's own target. PROVISIONAL — a flagged interview drops out immediately, before a partner responds; resampling uses a narrower, settled-only figure. COLLECTED: every completed interview, including oversampled surplus and duplicates — total field effort, not what counts toward target. CONFIRMED DELETED: a settled tracker deletion (partner didn't contest, or a contest was reviewed and the deletion upheld) — genuinely gone, feeds resampling. PENDING DELETION: everything else not yet counted as Achieved — duplicates, unmatched submissions, a still-open tracker flag, and any oversampling surplus. None of the last three currently have a partner review path the way a tracker flag does, but none are confirmed gone either — Collected always equals Achieved + Confirmed Deleted + Pending Deletion, exactly."),
        span(
          class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;",
          "Original Target = the design's fixed sample size for this stratum, unchanged since fielding began. Revised Target = the live total across whichever clusters currently make up this stratum's roster — grows automatically the moment a resampling batch adds a replacement or supplementary cluster, so it can differ from Original once resampling has touched a stratum. Status and % achieved are computed against the Revised figure."
        )
      ),
      if (!is.na(FRAME_AS_OF_LABEL)) {
        div(class = "text-muted", style = "font-size: 0.8em; padding: 0 12px;", FRAME_AS_OF_LABEL)
      },
      DTOutput(ns("table"))
    )
  )
}

mod_table_server <- function(id, filtered_stratum) {
  moduleServer(id, function(input, output, session) {
    output$table <- renderDT({
      df <- filtered_stratum() %>%
        transmute(
          Region = factor(region),
          State = factor(adm1_name),
          LGA = adm2_name,
          `Pop. group` = factor(unname(POP_TYPE_LABELS[pop_type])),
          `Partner coverage` = vapply(adm2_pcode, partner_coverage_label, character(1)),
          `Original Target` = target_sample,
          `Revised Target` = target_sample_current,
          Collected = collected_n,
          `Confirmed Deleted` = confirmed_deletion_n,
          `Pending Deletion` = pending_deletion_n,
          Achieved = achieved_n,
          `% achieved` = pct_achieved,
          `% from reserve` = pct_reserve_used,
          # factor (not character) so DT's column filter row renders a
          # clickable dropdown of the actual levels here, instead of a
          # free-text search box — same for Pop. group above.
          Status = factor(status, levels = names(STATUS_COLORS))
        ) %>%
        arrange(`% achieved`)

      datatable(
        df,
        rownames = FALSE,
        filter = "top",
        options = list(
          pageLength = 20,
          # 0-based column indices: 0 Region, 1 State, 2 LGA, 3 Pop. group,
          # 4 Partner coverage, 5 Original Target, 6 Revised Target,
          # 7 Collected, 8 Confirmed Deleted, 9 Pending Deletion,
          # 10 Achieved, 11 % achieved, 12 % from reserve, 13 Status.
          order = list(list(11, "asc")),
          columnDefs = list(list(className = "dt-right", targets = 5:12))
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
        ) %>%
        formatStyle(
          "Pending Deletion",
          background = styleColorBar(c(0, max(df$`Pending Deletion`, 1, na.rm = TRUE)), "#FCE8CF"),
          backgroundSize = "90% 70%",
          backgroundRepeat = "no-repeat",
          backgroundPosition = "left"
        )
    })
  })
}
