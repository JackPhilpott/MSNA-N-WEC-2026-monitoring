# Progress Overview tab: national/regional KPI tiles + daily submissions
# trend. Pop-type series (daily trend stack, region-progress bars) use the
# global POP_TYPE_COLORS/COMBINED_COLOR/UNMATCHED_COLOR for a consistent
# theme with the rest of the dashboard.

mod_progress_ui <- function(id) {
  ns <- NS(id)
  nav_panel(
    title = "Progress Overview",
    icon = icon("gauge-high"),
    # This tab is deliberately left OUT of app.R's page_navbar(fillable = c(...))
    # list (2026-08-30) so it scrolls instead of being squeezed to the
    # viewport — page_navbar()'s default fillable=TRUE squeezes every tab's
    # content to fit the viewport height without scrolling, fine for the
    # original 2-chart layout, but once the Progress by Partner bar+table
    # section was added there was simply too much to compress into one
    # screen without everything overlapping. (nav_panel() itself has no
    # fillable argument — an earlier attempt to set fillable=FALSE right
    # here did nothing but attach a stray, inert HTML attribute; the real
    # control lives on page_navbar(), see app.R.)
    if (!is.na(FRAME_AS_OF_LABEL)) {
      div(class = "text-muted", style = "font-size: 0.8em; margin-bottom: 8px;", FRAME_AS_OF_LABEL)
    },
    # Ordered per Jack (2026-09-04): Achieved > follow-up gap > Collected >
    # % of target > Planned days remaining > Est. days required. Six tiles
    # at col_widths 4 wraps cleanly into two rows of three (4+4+4=12 per
    # row) rather than squeezing six into one row.
    layout_columns(
      col_widths = c(4, 4, 4, 4, 4, 4),
      value_box(
        title = info_title(
          "Interviews achieved / planned",
          "ACHIEVED: completed, matched interviews that are not a SETTLED (confirmed/contested) tracker deletion — capped at each cluster's own target. Policy changed 2026-09-11: a pending/unresolved flag (duplicate, unmatched, a still-open recovery-workbook item) no longer excludes an interview here, only an actually-confirmed deletion does — matching the same figure resampling uses. A cluster that's been oversampled only ever contributes up to its target here, never more, so oversampling in one cluster can't mask under-coverage in another. Reflects your current sidebar filter selection (state/LGA/partner/population group) — the Home tab always shows the fixed national total regardless of filters, so the two can legitimately differ.",
          icon_color = "white"
        ),
        value = textOutput(ns("kpi_achieved")),
        showcase = icon("clipboard-check"),
        theme = "primary"
      ),
      value_box(
        title = info_title(
          "Collected − Achieved",
          "Every completed interview that does NOT currently count toward target: confirmed quality exclusions (duration floor, implausible food-consumption), duplicates, submissions that couldn't be matched to a sampled point, and any oversampled-cluster surplus. Not all of this needs deleting — oversampling surplus is wasted field effort, not a data problem — but it's the running total of what needs review or follow-up before it can count. Reflects your current sidebar filter selection, same as the tiles either side of it."
        ),
        value = textOutput(ns("kpi_followup")),
        showcase = icon("flag"),
        theme = "danger"
      ),
      value_box(
        title = info_title(
          "Collected",
          "COLLECTED: every completed interview actually done in the field — includes oversampled surplus, duplicates, and submissions that couldn't be matched to a sampled point. This is total field effort, not what counts toward the sample. A big gap between Collected and Achieved usually means oversampling of easy-to-reach clusters, which is wasted operational resource, not progress toward coverage elsewhere."
        ),
        value = textOutput(ns("kpi_collected")),
        showcase = icon("layer-group"),
        theme = "warning"
      ),
      value_box(
        title = info_title("% of target", "Achieved (capped, see that tile's definition) as a share of the planned sample. Oversampling does not inflate this. Reflects your current sidebar filter selection, same as the tile to the left."),
        value = textOutput(ns("kpi_pct")),
        showcase = icon("percent"),
        theme = "success"
      ),
      value_box(
        title = info_title(
          "Planned days remaining",
          "Calendar days left between today and the planned fielding end date, regardless of how fast or slow collection is actually going — a fixed countdown, not a pace estimate. Compare against \"Est. days required\": if that number is higher than this one, the current rate of progress won't reach target by the planned end date."
        ),
        value = textOutput(ns("kpi_days_remaining")),
        showcase = icon("calendar-days"),
        theme = "secondary"
      ),
      value_box(
        title = info_title(
          "Est. days required",
          "How many MORE days of data collection are needed to reach target at the CURRENT rate of Achieved progress (Achieved so far, within your current filter, divided by days since that filter's earliest submission). Unlike \"Planned days remaining\", this is driven entirely by actual pace, not the calendar — it can come out higher or lower, and moves as pace changes.",
          icon_color = "white"
        ),
        value = textOutput(ns("kpi_days_required")),
        showcase = icon("stopwatch"),
        # Bootstrap's default "info" (bright cyan, #0dcaf0) isn't customised
        # in app.R's bs_theme() the way primary/success/warning/danger are,
        # so it stood out against the rest of this row's muted palette
        # (2026-09-04, per Jack: "a little bit bright"). A muted slate blue
        # fits the same navy/green/amber/red/grey family instead - a custom
        # value_box_theme() rather than touching bs_theme()'s global "info"
        # since nothing else in the app uses that theme name (confirmed via
        # grep) and a global change would be wider-reaching than intended.
        theme = value_box_theme(bg = "#5C7A99", fg = "white")
      )
    ),
    layout_columns(
      col_widths = c(8, 4),
      card(
        card_header(
          "Daily submissions (by population group) vs. pace needed to finish on time",
          info_icon("Bars = new interviews each day, by population group (right axis). Solid green line = cumulative Achieved to date (left axis) — same definition as the Achieved KPI tile above (quality-excluded, capped per cluster), so it reaches exactly that tile's total on the last day with data. Dotted red line = the constant daily rate that would reach 100% of target exactly on the fielding deadline, starting from the fielding start date — it runs all the way to the deadline, past the last day with real data, so you can see whether the green line is on track to reach it in time. Green line above the red line at the same date = ahead of pace; below = behind."),
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
    ),
    card(
      full_screen = TRUE,
      card_header(
        "Progress by partner",
        info_icon("Every assigned partner, regardless of your sidebar filters — this always shows the full national picture, same convention as the Home tab, since the point is comparing partners against each other. Target is every stratum in every LGA assigned to that partner (partner_lga_assignment), not just LGAs where they've already submitted. \"Current pace\" is a whole-period average since that partner's own first submission — not the global fielding start date, so a partner who started later isn't penalised for days before they were even in the field. Achieved/% achieved reflect the WHOLE LGA's progress, including any other partner assigned to the same LGA (see \"Shared with\") — so a partner can show a nonzero % and still be \"Not started\" themselves if a partner they share an LGA with has already submitted there."),
        span(class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;", "Sorted by % of target achieved (lowest first)")
      ),
      plotlyOutput(ns("partner_bar"), height = "480px"),
      DTOutput(ns("partner_table"))
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
      paste0(comma(sum(s$achieved_n, na.rm = TRUE)), " / ", comma(sum(s$target_sample_current, na.rm = TRUE)))
    })

    output$kpi_pct <- renderText({
      s <- filtered_stratum()
      tgt <- sum(s$target_sample_current, na.rm = TRUE)
      ach <- sum(s$achieved_n, na.rm = TRUE)
      fmt_pct(if (tgt > 0) ach / tgt else NA_real_)
    })

    output$kpi_collected <- renderText({
      # Total field effort — every completed interview, unconditional (see
      # is_collected() in global.R). Computed directly from filtered_subs()
      # rather than summed from filtered_stratum()$collected_n, since the
      # stratum-level figure can only include rows that resolved to a real
      # stratum_id — this total should never undercount just because a
      # handful of submissions couldn't be attributed to one.
      comma(sum(is_collected(filtered_subs())))
    })

    output$kpi_followup <- renderText({
      # Collected - Achieved, from the exact same two figures the tiles
      # either side of it show (kpi_achieved's s$achieved_n, kpi_collected's
      # is_collected(filtered_subs())) - so a user can literally check
      # Achieved + this = Collected. Floored at 0 defensively; Achieved's
      # conditions are a strict subset of Collected's (plus cluster-capping,
      # which only ever removes further), so it should never go negative.
      s <- filtered_stratum()
      ach <- sum(s$achieved_n, na.rm = TRUE)
      col <- sum(is_collected(filtered_subs()))
      comma(max(col - ach, 0))
    })

    output$kpi_days_remaining <- renderText({
      paste0(days_remaining, " / ", days_total, " days")
    })

    output$kpi_days_required <- renderText({
      # Pace-based estimate, deliberately mirroring partner_progress_summary's
      # per-partner calc in global.R (current_pace = achieved / days_active
      # since that scope's own earliest submission, not the global fielding
      # start - a filter that only starts partway through the assessment
      # shouldn't look artificially slow just because the x-axis "started"
      # before it had any activity). today_for_pace is the same global "as
      # of now" anchor global.R's partner pace table uses, not this filtered
      # set's own last submission - otherwise a filter with a recent lull
      # would look faster than it really is.
      s <- filtered_stratum()
      subs <- filtered_subs()
      target <- sum(s$target_sample_current, na.rm = TRUE)
      achieved <- sum(s$achieved_n, na.rm = TRUE)
      remaining <- max(target - achieved, 0)
      if (remaining <= 0) return("Target met")
      start_date <- suppressWarnings(min(subs$submission_date, na.rm = TRUE))
      if (!is.finite(start_date)) return("N/A")
      days_active <- as.numeric(today_for_pace - start_date) + 1
      if (days_active <= 0) return("N/A")
      rate <- achieved / days_active
      if (rate <= 0) return("N/A")
      paste(comma(ceiling(remaining / rate)), "days")
    })

    output$trend_plot <- renderPlotly({
      # FIXED 2026-09-11: a date_outlier row now flows through with
      # submission_date deliberately NA (see prep_real_submissions.R's "7b"
      # step) instead of being dropped outright - correctly counted
      # everywhere else, but a day-by-day trend line has no axis position
      # to put an undated row on. Without this filter, seq(min(...),
      # max(...)) below errors outright the moment one exists (NA in, NA
      # out, seq() can't build a range to/from NA). Excluded from THIS
      # chart specifically, not from Achieved/Collected/the KPI totals.
      df <- completed_subs() %>% filter(!is.na(submission_date))
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

      # Cumulative line = true Achieved (fixed 2026-09-04, per Jack: this
      # used to just be matched+non-duplicate summed/cumsum'd - agreed with
      # neither Collected (no dup/unmatched exclusion) nor Achieved (missing
      # the quality-exclusion filter AND the per-cluster cap) - a THIRD,
      # unlabelled quantity despite the legend saying "Cumulative achieved".
      # Now applies the exact same is_achieved() + cluster_targets capping
      # compute_progress_by_stratum() uses (global.R), but CUMULATIVELY per
      # cluster per day - capping is a running-total concept, a cluster
      # can't be "capped" on any single day in isolation - then summed
      # across clusters, so the line's last point reconciles exactly with
      # the Achieved KPI tile above (verified via the smoke test: both read
      # 11,737 on the unfiltered national view). Restricted to
      # matched_strata_id %in% filtered_stratum()'s own strata_id, not just
      # is_achieved(filtered_subs()) directly - filtered_stratum() applies
      # its own state/LGA/pop-type/partner filter AFTER compute_progress_
      # by_stratum(), so a handful of rows could otherwise sit in a stratum
      # filtered_stratum() has excluded, breaking that same reconciliation.
      achieved_scope <- filtered_stratum()$strata_id
      achieved_rows <- filtered_subs() %>%
        filter(is_achieved(.), matched_strata_id %in% achieved_scope, !is.na(matched_cluster_id)) %>%
        left_join(cluster_targets, by = c("matched_cluster_id" = "cluster_id")) %>%
        mutate(target_households = coalesce(target_households, 0))

      if (nrow(achieved_rows) == 0) {
        by_day_total <- tibble(
          submission_date = seq(min(df$submission_date), max(df$submission_date), by = "day"),
          cumulative = 0
        )
      } else {
        by_day_total <- achieved_rows %>%
          count(matched_cluster_id, submission_date, target_households, name = "n") %>%
          complete(
            submission_date = seq(min(df$submission_date), max(df$submission_date), by = "day"),
            nesting(matched_cluster_id, target_households),
            fill = list(n = 0)
          ) %>%
          arrange(matched_cluster_id, submission_date) %>%
          group_by(matched_cluster_id) %>%
          mutate(capped_cum_n = pmin(cumsum(n), target_households)) %>%
          ungroup() %>%
          group_by(submission_date) %>%
          summarise(cumulative = sum(capped_cum_n), .groups = "drop") %>%
          arrange(submission_date)
      }

      # Pace line deliberately in its OWN data frame with its own date axis
      # (FIELDING_START to FIELDING_PLANNED_END) — fixed 2026-08-27, found
      # while explaining this chart to Jack: the previous version built
      # this off by_day_total's own dates, i.e. seq(0, target, length.out =
      # days from first submission to the LAST DAY WITH DATA), which always
      # reaches 100% of target on TODAY, not on the real fielding deadline.
      # That silently doubled the implied required daily rate (~1,750/day
      # vs. the real ~927/day at the time this was found) and got steeper
      # every single day, regardless of whether pace was actually fine.
      # Extending the pace line's x-range all the way to the real deadline
      # (beyond the last day of actual data) is what lets you visually
      # extrapolate the green cumulative line and see whether it's on
      # track to cross the red line by 11 Sept — not just where it stands
      # today.
      target_total <- sum(filtered_stratum()$target_sample_current, na.rm = TRUE)
      pace_line <- tibble(
        submission_date = seq(FIELDING_START, FIELDING_PLANNED_END, by = "day")
      ) %>%
        mutate(needed_pace = seq(0, target_total, length.out = n()))

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
        add_lines(data = pace_line, x = ~submission_date, y = ~needed_pace, name = "Pace needed to finish on time", line = list(color = "#C1443C", dash = "dot")) %>%
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
        summarise(target_sample_current = sum(target_sample_current, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(pct = ifelse(target_sample_current > 0, achieved_n / target_sample_current, 0), series = unname(POP_TYPE_LABELS[pop_type]))

      combined <- filtered_stratum() %>%
        group_by(region) %>%
        summarise(target_sample_current = sum(target_sample_current, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(pct = ifelse(target_sample_current > 0, achieved_n / target_sample_current, 0), series = "Combined")

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

    # ---- Progress by partner — static, off the global partner_progress_summary
    # constant computed once in global.R (like the Home tab's national
    # totals), deliberately NOT reactive to filtered_stratum()/sidebar
    # filters — the whole point of this view is comparing partners against
    # each other, which a single-partner filter would defeat.
    partner_pace_colors <- c("Behind pace" = "#C1443C", "On pace" = "#1E7B4D", "Complete" = "#1E7B4D", "Not started" = "#9AA3AF")

    output$partner_bar <- renderPlotly({
      df <- partner_progress_summary %>%
        mutate(partner_label = factor(partner_label, levels = rev(partner_label)))

      plot_ly(
        df, y = ~partner_label, x = ~pct_achieved, color = ~status, colors = partner_pace_colors,
        type = "bar", orientation = "h",
        text = ~paste0(comma(achieved_n), " / ", comma(target_sample_current), " (", percent(pct_achieved, accuracy = 1), ")"),
        textposition = "outside", hoverinfo = "text"
      ) %>%
        layout(
          xaxis = list(title = "% of target achieved", tickformat = ".0%", range = c(0, 1.15)),
          yaxis = list(title = ""),
          legend = list(orientation = "h", y = -0.08),
          margin = list(l = 160, r = 20, t = 10, b = 40)
        )
    })

    output$partner_table <- renderDT({
      df <- partner_progress_summary %>%
        transmute(
          Partner = partner_label,
          `Original Target` = target_sample, `Revised Target` = target_sample_current,
          Collected = collected_n, `Confirmed Deleted` = confirmed_deletion_n, `Oversampling Surplus` = oversampling_surplus_n,
          `Pending Deletion` = pending_deletion_n,
          Achieved = achieved_n,
          `% achieved` = pct_achieved,
          `Shared with` = shared_with,
          `Start date` = start_date,
          `Current daily pace` = round(current_daily_pace, 1),
          `Required daily pace` = round(required_daily_pace, 1),
          `Projected finish` = projected_finish_date,
          Status = factor(status, levels = c("Behind pace", "On pace", "Complete", "Not started"))
        )

      # 0-based: 0 Partner, 1 Original Target, 2 Revised Target, 3 Collected,
      # 4 Confirmed Deleted, 5 Pending Deletion, 6 Achieved, 7 % achieved,
      # 8 Shared with, 9 Start date, 10 Current pace, 11 Required pace,
      # 12 Projected finish, 13 Status.
      datatable(
        df, rownames = FALSE, filter = "top",
        options = list(pageLength = 20, order = list(list(7, "asc")), columnDefs = list(list(className = "dt-right", targets = c(1:7, 10, 11))))
      ) %>%
        formatPercentage("% achieved", 1) %>%
        formatStyle(
          "Status",
          color = styleEqual(names(partner_pace_colors), unname(partner_pace_colors))
        ) %>%
        formatStyle(
          "% achieved",
          background = styleColorBar(c(0, 1), "#CFE0F5"),
          backgroundSize = "90% 70%", backgroundRepeat = "no-repeat", backgroundPosition = "left"
        )
    })
  })
}
