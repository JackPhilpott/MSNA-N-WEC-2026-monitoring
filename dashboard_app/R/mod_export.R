# Data Export tab: download the currently filtered submissions and LGA
# progress table as CSV or Excel — for partners wanting their own data, or
# the technical supervisor doing ad hoc analysis outside the dashboard.

mod_export_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Data Export",
    icon = icon("download"),
    layout_columns(
      col_widths = c(6, 6),
      card(
        card_header("Filtered submissions"),
        p(class = "text-muted", "Every submission-level column currently in scope (respects all sidebar filters) — every raw submission, including consent refusals and duplicate copies. This is a larger number than both \"Collected\" (completed interviews only) and \"Achieved\" (completed, matched, non-duplicate, AND capped at each cluster's own target) elsewhere in the dashboard — see the Home tab for those definitions. Respondent-identifying fields (age/gender/household size/exact GPS) are excluded — see the Sample Representativeness tab for the same information in aggregate."),
        uiOutput(ns("subs_count")),
        downloadButton(ns("dl_subs_csv"), "Download CSV", class = "btn-outline-primary w-100 mb-2"),
        downloadButton(ns("dl_subs_xlsx"), "Download Excel", class = "btn-outline-primary w-100")
      ),
      card(
        card_header("Filtered LGA x population-group progress"),
        p(class = "text-muted", "Target/achieved/status per stratum, same scope as the Progress by LGA table."),
        uiOutput(ns("stratum_count")),
        downloadButton(ns("dl_stratum_csv"), "Download CSV", class = "btn-outline-primary w-100 mb-2"),
        downloadButton(ns("dl_stratum_xlsx"), "Download Excel", class = "btn-outline-primary w-100")
      )
    ),
    card(
      card_header("Preview (first 200 filtered submissions)"),
      DTOutput(ns("preview"))
    )
  )
}

mod_export_server <- function(id, filtered_subs, filtered_stratum) {
  moduleServer(id, function(input, output, session) {
    # Row-level submission data is exported/previewed here — unlike every
    # other tab, which only ever shows these fields in aggregate (a
    # histogram, a %, a group mean), this is a raw per-respondent dump, so
    # it's the one place strip_row_level_pii() (global.R) has to be
    # applied. filtered_subs() itself stays untouched (still has every
    # column for anything internal that needs it, e.g. is_duplicate/
    # match_quality-based counts elsewhere in the app).
    exportable_subs <- reactive(strip_row_level_pii(filtered_subs()))

    output$subs_count <- renderUI(p(strong(comma(nrow(filtered_subs()))), " submissions in scope"))
    output$stratum_count <- renderUI(p(strong(comma(nrow(filtered_stratum()))), " stratum rows in scope"))

    output$preview <- renderDT({
      datatable(exportable_subs() %>% head(200), rownames = FALSE, options = list(scrollX = TRUE, pageLength = 10))
    })

    output$dl_subs_csv <- downloadHandler(
      filename = function() paste0("MSNA_2026_submissions_filtered_", Sys.Date(), ".csv"),
      content = function(file) write_csv(exportable_subs(), file)
    )
    output$dl_subs_xlsx <- downloadHandler(
      filename = function() paste0("MSNA_2026_submissions_filtered_", Sys.Date(), ".xlsx"),
      content = function(file) writeData_wrapper(exportable_subs(), file, "Submissions")
    )
    output$dl_stratum_csv <- downloadHandler(
      filename = function() paste0("MSNA_2026_lga_progress_filtered_", Sys.Date(), ".csv"),
      content = function(file) write_csv(filtered_stratum(), file)
    )
    output$dl_stratum_xlsx <- downloadHandler(
      filename = function() paste0("MSNA_2026_lga_progress_filtered_", Sys.Date(), ".xlsx"),
      content = function(file) writeData_wrapper(filtered_stratum(), file, "LGA progress")
    )
  })
}

writeData_wrapper <- function(df, file, sheet_name) {
  wb <- createWorkbook()
  addWorksheet(wb, sheet_name)
  writeDataTable(wb, sheet_name, df, tableStyle = "TableStyleLight9")
  setColWidths(wb, sheet_name, cols = seq_along(df), widths = "auto")
  freezePane(wb, sheet_name, firstRow = TRUE)
  saveWorkbook(wb, file, overwrite = TRUE)
}
