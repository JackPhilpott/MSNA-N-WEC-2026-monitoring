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
        info_icon("ACHIEVED: completed, matched interviews that are not a SETTLED (confirmed/contested) tracker deletion, capped at each cluster's own target. Policy changed 2026-09-11: a pending/unresolved flag no longer excludes an interview, only a confirmed deletion does. COLLECTED: every completed interview, including oversampled surplus — total field effort, not what counts toward target. CONFIRMED DELETED: a settled tracker deletion (partner didn't contest, or a contest was reviewed and the deletion upheld) — genuinely gone, feeds resampling. OVERSAMPLING SURPLUS: real completed interviews beyond a cluster's own target, capped out of Achieved by design — likely needs reviewing so an over-collected cluster isn't asked for more. PENDING DELETION (informational only, already included in Achieved above): how much of Achieved still carries an unresolved flag (duplicate, unmatched, a still-open tracker item) that could still become a confirmed deletion — Collected always equals Achieved + Confirmed Deleted + Oversampling Surplus, exactly."),
        span(
          class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;",
          "Original Target = the design's fixed sample size for this stratum, unchanged since fielding began. Revised Target = the live required minimum — 1_sampling's representativity calculation (10% MoE, ICC=0.06, +5% operational margin), recomputed fresh every refresh against the current accessible population; can rise OR fall (accessibility loss/a dropped LGA lowers the population base it's calculated against), not just grow as resampling adds clusters. Status and % achieved are computed against whichever Target basis is selected in the sidebar's \"Target basis\" toggle (default Original, matching partner workbooks — 2026-09-19, replacing Decision A's permanently-Original choice). Both Original and Revised are always shown here as reference columns regardless of the toggle. Δ vs Original (added 2026-09-16) flags a stratum where Revised has moved 25%+ away from Original in either direction — worth a second look at why."
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
          `Oversampling Surplus` = oversampling_surplus_n,
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
          # 7 Delta vs Original, 8 Collected, 9 Confirmed Deleted,
          # 10 Oversampling Surplus, 11 Pending Deletion, 12 Achieved,
          # 13 % achieved, 14 % from reserve, 15 Status.
          order = list(list(13, "asc")),
          columnDefs = list(list(className = "dt-right", targets = 5:14))
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
