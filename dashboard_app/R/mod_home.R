# Home tab: top-level project introduction, live at go-live (2026-08-15).
# The "Today's snapshot" and "Priorities" panels are deliberately
# NATIONAL/unfiltered regardless of the sidebar — this is a stable
# landing page, not a working analysis view, so it shouldn't appear to
# go empty just because a partner filter is active elsewhere in the app.

mod_home_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Home",
    icon = icon("house"),
    layout_columns(
      col_widths = c(8, 4),
      card(
        card_header("MSNA North-West / East / Central Nigeria 2026 — Monitoring Dashboard"),
        div(
          style = "font-size: 1.02em; line-height: 1.6;",
          p(
            "This dashboard tracks daily progress of the 2026 Multi-Sector Needs Assessment ",
            "(MSNA) household data collection across North-West, North-East and North-Central ",
            "Nigeria. It draws on the finalised sampling frame (", strong(comma(TOTAL_PLANNED_INTERVIEWS)), " planned ",
            "interviews across ", strong(TOTAL_COVERED_LGAS), " partner-covered LGAs, both IDP and Non-IDP ",
            "population groups) and daily submission data to show how collection is tracking ",
            "against target, where it's falling behind, and what data-quality issues need ",
            "attention."
          ),
          p(strong("This dashboard serves two audiences:")),
          tags$ul(
            tags$li(
              strong("IMPACT/FACT internal monitoring & coordination team"), " — cleaning and overseeing the whole data collection: ",
              em("Progress Overview"), ", ", em("Coverage Map"), " and ", em("Progress by LGA"), " show where effort/support is most needed; ",
              em("Data Quality"), " catches issues (GPS/duration outliers, duplicates, LGA mismatches, refusals, off-hours submissions) early.",
              if (SHOW_ANALYSIS_TAB) {
                tagList(
                  " ", em("Data Integrity Checks"), ", ", em("Enumerator Performance"), " and ", em("Sample Representativeness"),
                  " (under the ", strong("Analysis"), " menu) dig deeper into who's collecting and whether the achieved sample looks like what the design expected."
                )
              }
            ),
            tags$li(
              strong("Field partners"), " collecting in specific locations: filter to your organisation via the sidebar, and use the ",
              em("Partner Report"), " tab to see (and download) your own LGAs' progress and focus areas. ",
              em("Data Export"), " lets anyone download whatever's currently in view."
            )
          ),
          p(
            "Data source: real KoBo submissions, cleaned and adapted daily via ",
            code("cleaning/real/prep_real_submissions.R"), " from the data team's own cleaning ",
            "pipeline output."
          ),
          p(
            strong("Collected vs. Achieved: "),
            "wherever this dashboard reports progress against target, it draws a hard line ",
            "between ", strong("Collected"), " (every completed interview actually done in the ",
            "field — includes oversampled surplus and duplicates) and ", strong("Achieved"),
            " (completed, matched, non-duplicate interviews, capped at each CLUSTER's own ",
            "target before being summed up to LGA/partner level — what actually counts toward ",
            "the sample frame). A cluster that's been oversampled never contributes more than ",
            "its own target to Achieved, so padding an easy-to-reach cluster can't compensate ",
            "for, or mask, under-coverage somewhere else. A large Collected-vs-Achieved gap for ",
            "a partner or LGA usually means wasted operational effort on oversampling, not real ",
            "progress. Look for the ", icon("circle-info", class = "text-muted"), " icon next to ",
            "a figure for its exact definition."
          ),
          p(
            strong("Administrative boundary sources: "),
            "LGA (admin-2) is always drawn from ", strong("OCHA/COD"), " — the officially ",
            "endorsed humanitarian boundary dataset — and is the authoritative source ",
            "wherever a sampling point's LGA is shown or compared. Ward (admin-3) detail, ",
            "which OCHA/COD doesn't publish for the NW & NC regions, comes from ",
            strong("GRID3"), " instead, used only to supplement ward-level detail — never ",
            "as a substitute for OCHA/COD at LGA level. The two datasets occasionally ",
            "disagree right at LGA borders (GRID3's ward polygons carry their own embedded ",
            "LGA label, which can differ from the official OCHA/COD line by a few tens to ",
            "a few hundred metres). Where that happens, OCHA/COD is treated as correct — ",
            "this is a known, expected source of near-border discrepancy, not a data error."
          )
        )
      ),
      card(
        card_header("At a glance"),
        uiOutput(ns("glance"))
      )
    ),
    layout_columns(
      col_widths = c(6, 6),
      card(
        card_header("Today's snapshot", span(class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;", "National, unfiltered")),
        uiOutput(ns("snapshot"))
      ),
      card(
        card_header("Priorities", span(class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;", "Auto-generated, national, unfiltered — a starting point, not a full picture")),
        uiOutput(ns("priorities"))
      )
    )
  )
}

mod_home_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    output$glance <- renderUI({
      # progress_by_stratum$achieved_n, not sum(is_achieved(submissions_raw))
      # directly (2026-08-25 fix) — the latter is uncapped and has the same
      # oversampling-inflation issue this whole Collected/Achieved split was
      # built to fix; progress_by_stratum already applies the cluster-level
      # cap (see compute_progress_by_stratum(), global.R).
      total_achieved <- sum(progress_by_stratum$achieved_n)
      total_collected <- sum(is_collected(submissions_raw))
      target_by_pop <- strata_frame %>% group_by(pop_type) %>% summarise(target = sum(target_sample, na.rm = TRUE), .groups = "drop")
      target_non_idp <- target_by_pop$target[target_by_pop$pop_type == "non_idp"]
      target_idp <- target_by_pop$target[target_by_pop$pop_type == "idp"]
      n_states <- length(unique(strata_frame$adm1_name))
      n_regions <- length(unique(strata_frame$region))

      tags$table(
        class = "table table-sm",
        tags$tr(tags$td("Fielding window"), tags$td(strong(paste(format(FIELDING_START, "%d %b"), "-", format(FIELDING_PLANNED_END, "%d %b %Y"))))),
        tags$tr(tags$td("Target interviews"), tags$td(strong(comma(TOTAL_PLANNED_INTERVIEWS)))),
        tags$tr(
          tags$td("Achieved so far", info_icon("Completed, matched, non-duplicate interviews, capped at each cluster's own target. Oversampled surplus never counts here.")),
          tags$td(strong(comma(total_achieved), " (", fmt_pct(total_achieved / TOTAL_PLANNED_INTERVIEWS), " of target)"))
        ),
        tags$tr(
          tags$td("Collected so far", info_icon("Every completed interview actually done — includes oversampled surplus, duplicates, and unmatched submissions. Total field effort, not what counts toward target.")),
          tags$td(strong(comma(total_collected)))
        ),
        tags$tr(tags$td("Target by population group"), tags$td(strong("Non-IDP: ", comma(target_non_idp), " / IDP: ", comma(target_idp)))),
        tags$tr(tags$td("Covered LGAs"), tags$td(strong(TOTAL_COVERED_LGAS))),
        tags$tr(tags$td("States / regions"), tags$td(strong(n_states, " states across ", n_regions, " regions (", paste(sort(unique(strata_frame$adm1_name)), collapse = ", "), ")"))),
        tags$tr(tags$td("Field partners"), tags$td(strong(length(setdiff(unique(partner_lga_assignment$org_id), "other")))))
      )
    })

    output$snapshot <- renderUI({
      today_n <- max(submissions_raw$submission_date, na.rm = TRUE)
      # "that day"/"the day before" are activity counts, not a cumulative
      # figure with a target to cap against — left on the per-row
      # is_achieved() flag deliberately, unlike total_achieved below.
      achieved_mask <- is_achieved(submissions_raw)
      yesterday_n <- sum(submissions_raw$submission_date == (today_n - 1) & achieved_mask)
      today_count <- sum(submissions_raw$submission_date == today_n & achieved_mask)
      # capped (progress_by_stratum), not sum(achieved_mask) directly — see
      # the matching note in output$glance above.
      total_achieved <- sum(progress_by_stratum$achieved_n)
      total_collected <- sum(is_collected(submissions_raw))
      total_target <- TOTAL_PLANNED_INTERVIEWS
      last_upload <- max(submissions_raw$uploaded_at, na.rm = TRUE)

      tags$table(
        class = "table table-sm",
        tags$tr(tags$td("Latest submission date in the data"), tags$td(strong(format(today_n, "%d %b %Y")))),
        tags$tr(tags$td("Submissions that day"), tags$td(strong(comma(today_count)))),
        tags$tr(tags$td("Submissions the day before"), tags$td(strong(comma(yesterday_n)))),
        tags$tr(
          tags$td("Total achieved to date", info_icon("Completed, matched, non-duplicate interviews, capped at each cluster's own target. Oversampled surplus never counts here.")),
          tags$td(strong(comma(total_achieved), " / ", comma(total_target), " (", fmt_pct(total_achieved / total_target), ")"))
        ),
        tags$tr(
          tags$td("Total collected to date", info_icon("Every completed interview actually done — includes oversampled surplus, duplicates, and unmatched submissions.")),
          tags$td(strong(comma(total_collected)))
        ),
        tags$tr(tags$td("Most recent upload timestamp"), tags$td(strong(format(last_upload, "%d %b %Y %H:%M"))))
      )
    })

    output$priorities <- renderUI({
      worst_lgas <- progress_by_stratum %>%
        filter(status != "Complete", target_sample > 0) %>%
        arrange(pct_achieved) %>%
        head(5)

      enum_stats <- compute_enumerator_stats(submissions_raw)
      worst_enum <- enum_stats %>% filter(submissions >= 10) %>% arrange(desc(flag_rate)) %>% head(3)

      tagList(
        p(strong("LGAs furthest behind target:")),
        tags$ul(
          if (nrow(worst_lgas) == 0) tags$li("None currently far behind.") else
            lapply(seq_len(nrow(worst_lgas)), function(i) {
              r <- worst_lgas[i, ]
              tags$li(paste0(r$adm2_name, ", ", r$adm1_name, " (", unname(POP_TYPE_LABELS[r$pop_type]), ") — ", fmt_pct(r$pct_achieved), " (", r$achieved_n, "/", r$target_sample, ")"))
            })
        ),
        p(strong("Enumerators with the highest flag rates (10+ submissions):")),
        tags$ul(
          if (nrow(worst_enum) == 0) tags$li("Not enough data yet.") else
            lapply(seq_len(nrow(worst_enum)), function(i) {
              r <- worst_enum[i, ]
              tags$li(paste0(r$enum_id, " (", r$org_label, ") — ", fmt_pct(r$flag_rate), " flag rate across ", r$submissions, " submissions"))
            })
        )
      )
    })
  })
}
