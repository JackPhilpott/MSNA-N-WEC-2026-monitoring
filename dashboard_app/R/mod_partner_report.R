# Partner Report tab: a single partner's progress at a glance, plus
# downloadable Excel and PDF summaries they can take away — "how many
# complete / required, and where to focus" per LGA. Status/colours use the
# same 3-tier STATUS_COLORS (global.R) as the rest of the dashboard.

mod_partner_report_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Partner Report",
    icon = icon("file-export"),
    if (!is.na(FRAME_AS_OF_LABEL)) {
      div(class = "text-muted", style = "font-size: 0.8em; margin-bottom: 8px;", FRAME_AS_OF_LABEL)
    },
    layout_columns(
      col_widths = c(4, 8),
      card(
        card_header("Select partner"),
        selectInput(ns("report_partner"), NULL, choices = org_id_choices, selected = unname(org_id_choices[1])),
        p(class = "text-muted", style = "font-size: 0.85em;",
          "Defaults to the first partner selected in the sidebar filter, if any. Otherwise pick one here — the download buttons always export the partner chosen above, independent of the sidebar."),
        downloadButton(ns("download_xlsx"), "Download Excel report", class = "btn-outline-primary w-100 mb-2"),
        downloadButton(ns("download_pdf"), "Download PDF report", class = "btn-outline-primary w-100")
      ),
      layout_columns(
        col_widths = c(3, 3, 3, 3, 3, 3, 3, 3),
        value_box(title = info_title("Original Target (their LGAs)", "The frozen design-time total across this partner's assigned LGAs, unchanged since fielding began."), value = textOutput(ns("kpi_target_original")), showcase = icon("bullseye"), theme = "secondary"),
        value_box(title = info_title("Revised Target (their LGAs)", "The live total across every currently-active cluster in this partner's assigned LGAs — grows automatically when resampling adds a replacement/supplementary cluster. Achieved/% achieved are computed against THIS figure."), value = textOutput(ns("kpi_target")), showcase = icon("bullseye"), theme = "primary"),
        value_box(
          title = info_title("Achieved", "Completed, matched interviews that are not a SETTLED (confirmed/contested) tracker deletion — capped at each cluster's own target. Policy changed 2026-09-11: a pending/unresolved flag no longer excludes an interview, only a confirmed deletion does — same figure resampling now uses too."),
          value = textOutput(ns("kpi_achieved")), showcase = icon("clipboard-check"), theme = "success"
        ),
        value_box(
          title = info_title("Collected", "Every completed interview actually done, including oversampled surplus — total field effort, not what counts toward target. A large gap vs. Achieved usually means oversampling of easy-to-reach clusters."),
          value = textOutput(ns("kpi_collected")), showcase = icon("layer-group"), theme = "warning"
        ),
        value_box(
          title = info_title("Confirmed Deleted", "A settled tracker deletion in this partner's coverage — genuinely gone, feeds resampling."),
          value = textOutput(ns("kpi_confirmed_deletion")), showcase = icon("trash"), theme = "danger"
        ),
        value_box(
          title = info_title("Pending Deletion", "Informational only (changed 2026-09-11) — how much of Achieved above still carries an unresolved tracker flag (duplicate, unmatched, a still-open recovery-workbook item) that could still become a confirmed deletion later. Included in Achieved for now, not subtracted."),
          value = textOutput(ns("kpi_pending_deletion")), showcase = icon("hourglass-half"), theme = "warning"
        ),
        value_box(
          title = info_title("% achieved", "Achieved (capped, see that tile) as a share of Revised Target. Not inflated by oversampling."),
          value = textOutput(ns("kpi_pct")), showcase = icon("percent"), theme = "success"
        ),
        value_box(title = "Flagged for review", value = textOutput(ns("kpi_flagged")), showcase = icon("flag"), theme = "warning")
      ),
      layout_columns(
        col_widths = c(4),
        value_box(
          title = info_title("Oversampled clusters", "Clusters in this partner's coverage where their own submissions have pushed the cluster's achieved count past its target_households. The surplus doesn't count toward Achieved above (its own separate Oversampling Surplus figure instead — changed 2026-09-11, was folded into Pending Deletion before), but is real field effort spent past target — worth reviewing before deciding which submissions to keep. A cluster jointly worked with another partner counts for both."),
          value = textOutput(ns("kpi_oversampled")), showcase = icon("triangle-exclamation"), theme = "warning"
        )
      )
    ),
    card(
      card_header(
        "Progress by LGA (their assigned coverage area)",
        info_icon("ACHIEVED: completed, matched interviews that are not a SETTLED (confirmed/contested) tracker deletion, capped at each cluster's own target. Policy changed 2026-09-11: a pending/unresolved flag no longer excludes an interview, only a confirmed deletion does. COLLECTED: every completed interview, including oversampled surplus."),
        span(
          class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;",
          "Some LGAs are jointly covered by more than one partner (see \"Shared with\") — Achieved there reflects everyone's combined submissions, not this partner's alone."
        )
      ),
      DTOutput(ns("lga_table"))
    )
  )
}

mod_partner_report_server <- function(id, selected_partners) {
  moduleServer(id, function(input, output, session) {
    observeEvent(selected_partners(), {
      sp <- selected_partners()
      if (length(sp) >= 1 && !is.null(sp)) {
        updateSelectInput(session, "report_partner", selected = sp[1])
      }
    }, ignoreInit = TRUE)

    lga_df <- reactive({
      req(input$report_partner)
      partner_progress_by_lga(input$report_partner)
    })

    qual <- reactive({
      req(input$report_partner)
      partner_quality_summary(input$report_partner)
    })

    output$kpi_target_original <- renderText({ comma(sum(lga_df()$target_sample)) })
    output$kpi_target <- renderText({ comma(sum(lga_df()$target_sample_current)) })
    output$kpi_achieved <- renderText({ comma(sum(lga_df()$achieved_n)) })
    output$kpi_collected <- renderText({ comma(sum(lga_df()$collected_n)) })
    output$kpi_confirmed_deletion <- renderText({ comma(sum(lga_df()$confirmed_deletion_n)) })
    output$kpi_pending_deletion <- renderText({ comma(sum(lga_df()$pending_deletion_n)) })
    output$kpi_pct <- renderText({ fmt_pct(sum(lga_df()$achieved_n) / sum(lga_df()$target_sample_current)) })
    output$kpi_flagged <- renderText({
      q <- qual()
      paste0(comma(q$flagged), " (", fmt_pct(q$flag_rate), ")")
    })

    # oversampled_clusters (global.R) is static/national — filtered here to
    # clusters where THIS partner's own org_id shows up among the
    # submitting orgs (split properly, not a substring match, so e.g. "irc"
    # can't accidentally match within a longer combined string).
    partner_oversampled <- reactive({
      req(input$report_partner)
      oversampled_clusters[
        vapply(strsplit(oversampled_clusters$submitting_org_ids, ", "), function(x) input$report_partner %in% x, logical(1)),
      ]
    })
    output$kpi_oversampled <- renderText({
      o <- partner_oversampled()
      paste0(comma(nrow(o)), " (", comma(sum(o$surplus)), " surplus)")
    })

    output$lga_table <- renderDT({
      df <- lga_df() %>%
        transmute(
          Region = factor(region), State = factor(adm1_name), LGA = adm2_name,
          `Original Target` = target_sample, `Revised Target` = target_sample_current,
          Collected = collected_n, `Confirmed Deleted` = confirmed_deletion_n, `Pending Deletion` = pending_deletion_n,
          Achieved = achieved_n, `% achieved` = pct_achieved,
          Status = factor(status, levels = names(STATUS_COLORS)),
          `Shared with` = shared_with
        )
      datatable(df, rownames = FALSE, filter = "top", options = list(pageLength = 20)) %>%
        formatPercentage("% achieved", 1) %>%
        formatStyle("Status", backgroundColor = styleEqual(names(STATUS_COLORS), unname(STATUS_COLORS)))
    })

    output$download_xlsx <- downloadHandler(
      filename = function() paste0("MSNA_2026_partner_report_", input$report_partner, "_", Sys.Date(), ".xlsx"),
      content = function(file) build_partner_excel(input$report_partner, file)
    )

    output$download_pdf <- downloadHandler(
      filename = function() paste0("MSNA_2026_partner_report_", input$report_partner, "_", Sys.Date(), ".pdf"),
      content = function(file) build_partner_pdf(input$report_partner, file)
    )
  })
}

# ---- report builders (also usable standalone / from other modules) --------

build_partner_excel <- function(org_id_val, file) {
  lga_df <- partner_progress_by_lga(org_id_val)
  qual <- partner_quality_summary(org_id_val)
  label <- ORG_LABELS[[org_id_val]]
  total_target <- sum(lga_df$target_sample)
  total_target_current <- sum(lga_df$target_sample_current)
  total_achieved <- sum(lga_df$achieved_n)
  total_collected <- sum(lga_df$collected_n)
  total_confirmed_deletion <- sum(lga_df$confirmed_deletion_n)
  total_pending_deletion <- sum(lga_df$pending_deletion_n)
  total_oversampling_surplus <- sum(lga_df$oversampling_surplus_n)

  wb <- createWorkbook()
  addWorksheet(wb, "Summary")
  writeData(
    wb, "Summary",
    data.frame(
      Field = c("Partner", "Report generated", "Original Target interviews (their LGAs)", "Revised Target interviews (their LGAs)",
                "Achieved interviews", "Collected interviews", "Confirmed Deleted", "Oversampling Surplus", "Pending Deletion (informational, included in Achieved)",
                "% achieved", "Submissions logged", "Flagged for review", "Flag rate", "Consent refusals"),
      Value = c(
        label, format(Sys.time(), "%d %b %Y %H:%M"), comma(total_target), comma(total_target_current),
        comma(total_achieved), comma(total_collected), comma(total_confirmed_deletion), comma(total_oversampling_surplus), comma(total_pending_deletion),
        fmt_pct(total_achieved / total_target_current), comma(qual$submissions), comma(qual$flagged),
        fmt_pct(qual$flag_rate), comma(qual$consent_refused)
      )
    ),
    colNames = FALSE
  )
  setColWidths(wb, "Summary", cols = 1:2, widths = c(28, 40))
  addStyle(wb, "Summary", createStyle(textDecoration = "bold"), rows = 1:14, cols = 1)
  writeData(
    wb, "Summary",
    paste(
      "Achieved = completed, matched interviews that are not a SETTLED (confirmed/contested) tracker deletion, capped at each cluster's own target (oversampling can't count toward or mask coverage elsewhere), measured against Revised Target. Policy changed 2026-09-11: a pending/unresolved flag no longer excludes an interview - only a confirmed deletion does.",
      "Collected = every completed interview actually done, including oversampled surplus.",
      "Confirmed Deleted = a settled tracker deletion, genuinely gone. Pending Deletion (informational only, not part of the identity below) = how much of Achieved still carries an unresolved flag that could still become a confirmed deletion. Collected always equals Achieved + Confirmed Deleted + Oversampling Surplus (real completed interviews beyond a cluster's own target).",
      "Original Target = the frozen design-time total, unchanged since fielding began. Revised Target = the live total across the current cluster roster, grows automatically as resampling adds clusters."
    ),
    startRow = 16
  )
  addStyle(wb, "Summary", createStyle(fontSize = 9, textDecoration = "italic", fontColour = "#666666", wrapText = TRUE), rows = 16, cols = 1)

  sheet2 <- "Progress by LGA"
  addWorksheet(wb, sheet2)
  export_df <- lga_df %>%
    transmute(Region = region, State = adm1_name, LGA = adm2_name,
              `Original Target` = target_sample, `Revised Target` = target_sample_current,
              Collected = collected_n, `Confirmed Deleted` = confirmed_deletion_n, `Pending Deletion` = pending_deletion_n,
              Achieved = achieved_n, `% achieved` = pct_achieved, Status = status,
              `Shared with` = shared_with)
  writeDataTable(wb, sheet2, export_df, tableStyle = "TableStyleLight9")
  pct_col <- which(names(export_df) == "% achieved")
  status_col <- which(names(export_df) == "Status")
  addStyle(wb, sheet2, createStyle(numFmt = "0%"), rows = 2:(nrow(export_df) + 1), cols = pct_col, gridExpand = TRUE, stack = TRUE)
  for (s in names(STATUS_COLORS)) {
    rows <- which(export_df$Status == s) + 1
    if (length(rows) > 0) {
      addStyle(wb, sheet2, createStyle(fgFill = STATUS_COLORS[[s]]), rows = rows, cols = status_col, gridExpand = TRUE, stack = TRUE)
    }
  }
  setColWidths(wb, sheet2, cols = 1:ncol(export_df), widths = "auto")
  freezePane(wb, sheet2, firstRow = TRUE)

  saveWorkbook(wb, file, overwrite = TRUE)
}

build_partner_pdf <- function(org_id_val, file) {
  lga_df <- partner_progress_by_lga(org_id_val)
  qual <- partner_quality_summary(org_id_val)
  label <- ORG_LABELS[[org_id_val]]
  total_target <- sum(lga_df$target_sample)
  total_target_current <- sum(lga_df$target_sample_current)
  total_achieved <- sum(lga_df$achieved_n)
  total_collected <- sum(lga_df$collected_n)
  total_confirmed_deletion <- sum(lga_df$confirmed_deletion_n)
  total_pending_deletion <- sum(lga_df$pending_deletion_n)
  total_oversampling_surplus <- sum(lga_df$oversampling_surplus_n)
  pct <- if (total_target_current > 0) total_achieved / total_target_current else NA_real_

  header_text <- paste0(
    label, "\nMSNA N-WEC 2026 — Progress Report\nGenerated: ", format(Sys.time(), "%d %b %Y %H:%M"),
    "\n\nOriginal Target: ", comma(total_target), "     Revised Target: ", comma(total_target_current),
    "\nAchieved: ", comma(total_achieved), " (", fmt_pct(pct), ")", "     Collected: ", comma(total_collected),
    "\nConfirmed Deleted: ", comma(total_confirmed_deletion), "     Oversampling Surplus: ", comma(total_oversampling_surplus),
    "\nPending Deletion (informational, included in Achieved above): ", comma(total_pending_deletion),
    "\nSubmissions logged: ", comma(qual$submissions), "     Flagged for review: ", comma(qual$flagged), " (", fmt_pct(qual$flag_rate), ")",
    "\nAchieved = capped at each cluster's own target, measured against Revised Target, excludes only SETTLED (confirmed) deletions - a pending flag no longer excludes (policy changed 2026-09-11). Collected = every completed interview, incl. oversampled surplus. Oversampling Surplus = real completed interviews beyond a cluster's own target, capped out of Achieved by design."
  )
  header_plot <- ggplot() + theme_void() + xlim(0, 1) + ylim(0, 1) +
    annotate("text", x = 0, y = 1, label = header_text, hjust = 0, vjust = 1, size = 4.2)

  bar_plot <- ggplot(lga_df, aes(x = reorder(adm2_name, pct_achieved), y = pmin(pct_achieved, 1.5), fill = status)) +
    geom_col() +
    coord_flip() +
    scale_y_continuous(labels = percent, limits = c(0, max(1, max(lga_df$pct_achieved, na.rm = TRUE), na.rm = TRUE))) +
    scale_fill_manual(values = STATUS_COLORS, drop = FALSE) +
    labs(x = NULL, y = "% of target achieved", fill = "Status", title = "Progress by LGA") +
    theme_minimal(base_size = 10) +
    theme(legend.position = "bottom")

  focus <- lga_df %>% filter(status != "Complete") %>% arrange(pct_achieved) %>% head(10)
  focus_text <- if (nrow(focus) == 0) {
    "Focus areas: none — every assigned LGA is on track or complete."
  } else {
    paste0(
      "Focus areas (lowest % achieved):\n",
      paste0("  - ", focus$adm2_name, " (", fmt_pct(focus$pct_achieved), ", ", focus$achieved_n, "/", focus$target_sample_current, ")", collapse = "\n")
    )
  }
  shared <- lga_df %>% filter(shared_with != "")
  if (nrow(shared) > 0) {
    focus_text <- paste0(
      focus_text, "\n\nJointly covered with another partner (Achieved reflects both):\n",
      paste0("  - ", shared$adm2_name, " (with ", shared$shared_with, ")", collapse = "\n")
    )
  }
  focus_plot <- ggplot() + theme_void() + xlim(0, 1) + ylim(0, 1) +
    annotate("text", x = 0, y = 1, label = focus_text, hjust = 0, vjust = 1, size = 3.6, family = "mono")

  combined <- cowplot::plot_grid(header_plot, bar_plot, focus_plot, ncol = 1, rel_heights = c(0.20, 0.52, 0.28))
  ggsave(file, combined, width = 8.27, height = 11.69, units = "in", device = "pdf")
}
