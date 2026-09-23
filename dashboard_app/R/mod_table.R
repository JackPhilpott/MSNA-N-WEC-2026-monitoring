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
        info_icon("Achieved = every interview that counts toward target here, including any collected past this stratum's own target. Still needed = what remains after that cap, so Achieved + Still needed only equals Target where nothing was over-collected; Extra interviews shows the amount above target. % achieved is capped at 100% (it uses Achieved counted up to target), so an over-collected stratum reads 100% plus an Extra interviews figure rather than 150%. Collected = every completed interview. Confirmed Deleted = settled, genuinely gone. Pending Deletion = already in Achieved, but still flagged. Sampling shows MSNA Light strata, where collection is LGA-level via government enumerators."),
        span(
          class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;",
          "Original Target = the fixed sample size set at collection start. Revised Target = the current minimum needed, recalculated as accessibility changes. Status and % achieved follow the sidebar's Target basis toggle. Δ vs Original flags a 25%+ shift between the two. Dropped = excluded from the design; its interviews stay on this row and are left out of national and partner totals."
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
          # ADDED 2026-09-16 (Jack, visibility ask): shared helper (global.R)
          # so this can't drift from the same calc used on the map/other tabs.
          `Δ vs Original` = target_delta_pct(target_sample, target_sample_current),
          Collected = collected_n,
          `Confirmed Deleted` = confirmed_deletion_n,
          `Pending Deletion` = pending_deletion_n,
          Achieved = achieved_n,
          # ADDED 2026-09-22 (Jack): the figure this table never showed -
          # what is actually still required here after each stratum's own
          # cap. A reader previously had to do Target - Achieved themselves,
          # which is wrong for any stratum that collected past target.
          `Still needed` = remaining_n,
          # ADDED 2026-09-22 alongside it: interviews beyond this stratum's
          # own target. Keeps oversampling visible now that "% achieved"
          # below is capped and can no longer read over 100%.
          `Extra interviews` = pmax(achieved_n - target_active, 0),
          # capped/credited as of 2026-09-22 - defined once in
          # compute_progress_by_stratum() (global.R), not recomputed here,
          # so this table can't drift from the tiles again.
          `% achieved` = pct_achieved,
          `% from reserve` = pct_reserve_used,
          # ADDED 2026-09-22: MSNA Light strata were indistinguishable here.
          # Reads the frame's own sampling_method (already carried through
          # compute_progress_by_stratum()), so it tags whatever the frame
          # marks rather than a hardcoded LGA list.
          Sampling = factor(ifelse(is.na(sampling_method) | sampling_method == "", "MSNA Full Design", sampling_method)),
          # factor (not character) so DT's column filter row renders a
          # clickable dropdown of the actual levels here, instead of a
          # free-text search box — same for Pop. group above.
          Status = factor(status, levels = names(STRATUM_STATUS_COLORS))
        ) %>%
        # 2026-09-22 (Jack): sorted by what's still outstanding, largest
        # first - this table is read to decide where to push effort, and
        # "lowest % achieved" put tiny strata above big shortfalls.
        arrange(desc(`Still needed`))

      datatable(
        df,
        rownames = FALSE,
        filter = "top",
        options = list(
          pageLength = 20,
          # 0-based column indices (2026-09-22: "Oversampling Surplus"
          # dropped - it is a near-zero match-quality residual, not real
          # oversampling, and readers took it for the latter; "Still
          # needed", "Extra interviews" and "Sampling" added):
          # 0 Region, 1 State, 2 LGA, 3 Pop. group, 4 Partner coverage,
          # 5 Original Target, 6 Revised Target, 7 Delta vs Original,
          # 8 Collected, 9 Confirmed Deleted, 10 Pending Deletion,
          # 11 Achieved, 12 Still needed, 13 Extra interviews,
          # 14 % achieved, 15 % from reserve, 16 Sampling, 17 Status.
          order = list(list(12, "desc")),
          columnDefs = list(list(className = "dt-right", targets = 5:15))
        )
      ) %>%
        # 2026-09-14: same fix as mod_progress.R's partner table - Revised
        # Target (target_sample_current) is now sourced straight from
        # 1_sampling's representativity calc, genuinely fractional by
        # construction. Display-only rounding.
        formatRound(c("Original Target", "Revised Target"), 0) %>%
        formatPercentage(c("% achieved", "% from reserve"), 1) %>%
        formatPercentage("Δ vs Original", 1) %>%
        # ADDED 2026-09-16 (Jack): background highlight when a stratum's
        # Revised has moved 25%+ from Original (either direction) - same
        # TARGET_DIVERGENCE_THRESHOLD (global.R) the map popup and every
        # other surface uses. A signed value's natural range doesn't fit
        # styleColorBar's single-direction magnitude scale, so this uses
        # formatStyle()+styleInterval() instead - same conditional-highlight
        # spirit as Status's own background fill just below, not a new
        # visual language.
        formatStyle(
          "Δ vs Original",
          backgroundColor = styleInterval(
            c(-TARGET_DIVERGENCE_THRESHOLD, TARGET_DIVERGENCE_THRESHOLD),
            c("#FCE8CF", "#FFFFFF", "#FCE8CF")
          )
        ) %>%
        formatStyle(
          "Status",
          # STRATUM_STATUS_COLORS, not STATUS_COLORS (2026-09-22): the
          # latter has no "Dropped" entry, so all 18 Dropped strata fell
          # outside the factor levels and rendered as a blank cell.
          backgroundColor = styleEqual(names(STRATUM_STATUS_COLORS), unname(STRATUM_STATUS_COLORS)),
          color = styleEqual(names(STRATUM_STATUS_COLORS), c("white", "#1a1a1a", "white", "white"))
        ) %>%
        formatStyle(
          "Still needed",
          background = styleColorBar(c(0, max(df$`Still needed`, 1, na.rm = TRUE)), "#F8CBAD"),
          backgroundSize = "90% 70%",
          backgroundRepeat = "no-repeat",
          backgroundPosition = "left"
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
