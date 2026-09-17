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
      # REDESIGNED 2026-09-16 (Jack, first draft/proof-of-concept for the
      # new tab specifically - not final, don't over-polish before he sees
      # it). Two tabs in the same card, neither chart deleted: "By amount"
      # (new, absolute-numbers, main/information-rich view) and "By %
      # achieved" (the old chart, kept as the simplified secondary view -
      # its own definition changed too, see that output's own comment).
      navset_pill(
        nav_panel("By amount", plotlyOutput(ns("partner_bar_abs"), height = "480px")),
        nav_panel("By % achieved", plotlyOutput(ns("partner_bar_pct"), height = "480px"))
      ),
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
      # 2026-09-14 (Jack, explicit general rule): a Dropped stratum's real
      # data must never enter a national/regional sum, only shown at its
      # own stratum/LGA row - filtered here, same as every other stratum-
      # scoped aggregate on this page.
      s <- filtered_stratum() %>% filter(status != "Dropped")
      # matched-only achieved (filtered_stratum()$achieved_n), same
      # definition "% of target" below uses — completed_subs() below
      # deliberately includes unmatched rows too (the trend chart needs
      # them, to show the "Unmatched" bar), so it must NOT be the source
      # for this tile, or the achieved count here would run ahead of what
      # the % implies whenever any submission fails to match.
      # FIX 2026-09-16 (Decision A): target_sample (original), not
      # target_sample_current - see global.R's compute_progress_by_stratum().
      paste0(comma(sum(s$achieved_n, na.rm = TRUE)), " / ", comma(sum(s$target_sample, na.rm = TRUE)))
    })

    output$kpi_pct <- renderText({
      s <- filtered_stratum() %>% filter(status != "Dropped")
      tgt <- sum(s$target_sample, na.rm = TRUE)
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
      s <- filtered_stratum() %>% filter(status != "Dropped")
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
      s <- filtered_stratum() %>% filter(status != "Dropped")
      subs <- filtered_subs()
      # FIX 2026-09-16 (Decision A): target_sample (original) - "Still
      # Needed" recomputes against this now, not target_sample_current.
      target <- sum(s$target_sample, na.rm = TRUE)
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
      # 2026-09-14: excludes Dropped strata, same rule as the KPI tiles above.
      # FIX 2026-09-16 (Decision A): target_sample (original), not _current -
      # "pace needed to finish on time" is a Still-Needed concept, same basis
      # as the KPI tiles above now.
      target_total <- sum(filtered_stratum() %>% filter(status != "Dropped") %>% pull(target_sample), na.rm = TRUE)
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
      # 2026-09-14: excludes Dropped strata before the region-level rollup -
      # same rule as everywhere else, matters here specifically since this
      # collapses across pop_type/LGA, exactly where a Dropped stratum's
      # achieved could otherwise blend into an active neighbour's total.
      region_base <- filtered_stratum() %>% filter(status != "Dropped")
      # FIX 2026-09-16 (Decision A): target_sample (original), not _current.
      by_region_pop <- region_base %>%
        group_by(region, pop_type) %>%
        summarise(target_sample = sum(target_sample, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(pct = ifelse(target_sample > 0, achieved_n / target_sample, 0), series = unname(POP_TYPE_LABELS[pop_type]))

      combined <- region_base %>%
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

    # ---- Progress by partner — static, off the global partner_progress_summary
    # constant computed once in global.R (like the Home tab's national
    # totals), deliberately NOT reactive to filtered_stratum()/sidebar
    # filters — the whole point of this view is comparing partners against
    # each other, which a single-partner filter would defeat.
    partner_pace_colors <- c("Behind pace" = "#C1443C", "On pace" = "#1E7B4D", "Complete" = "#1E7B4D", "Not started" = "#9AA3AF")

    # REVISED 2026-09-16b (Jack, real feedback round on the first draft) -
    # "lowest achieved at top, highest at bottom", explicitly matching the
    # OTHER tab. Both tabs now build their y-order from this SAME vector
    # (not just the same construction repeated twice, which is what caused
    # them to visually disagree in the first place - a multi-trace chart
    # like "By amount" apparently doesn't reliably respect a bare factor's
    # level order the way a single-trace bar does, so this is pinned
    # explicitly via categoryorder/categoryarray below on both, not left
    # implicit to a shared factor() call).
    partner_order <- partner_progress_summary %>% arrange(pct_achieved) %>% pull(partner_label) %>% rev()

    # Three-stage colour, shared by both the fill legend and the underlying
    # classification - all three colours already canonical in this app
    # (not new picks): red = STATUS_COLORS/partner_pace_colors' existing
    # red, dark green = STATUS_COLORS' "Complete" green, light green =
    # pct_color()'s own 75-100% shade (global.R) - chosen there for the
    # exact same reason it's reused here: it's deliberately far enough from
    # the dark green to stay visually distinct at a glance, not a similar
    # shade that would wash together.
    STAGE_COLORS <- c(
      "Below Revised Target" = "#C1443C",
      "At/above Revised, below Original" = "#8FC79A",
      "At/above Original Target" = "#1E7B4D"
    )

    # ---- NEW 2026-09-16 (Jack, first draft/proof-of-concept, revised
    # 2026-09-16b after his first look): absolute-numbers bullet-style
    # chart, replacing % as the PRIMARY partner view. Each partner's bar is
    # scaled to ITS OWN Original Target (fraction = achieved/target_sample,
    # capped at 1) - deliberately NOT one shared absolute-unit axis (FACT's
    # ~15,000 target would make ZOA's ~186 an invisible sliver) and NOT a
    # log scale either (explicitly discussed with Jack and rejected - a log
    # scale makes fill-position an unintuitive/dishonest read of real
    # progress, defeating the point of switching away from %). Real
    # absolute numbers come through via text/hover only, never via
    # comparing raw bar lengths across partners.
    output$partner_bar_abs <- renderPlotly({
      df <- partner_progress_summary %>%
        mutate(
          partner_label = factor(partner_label, levels = partner_order),
          # fraction of THIS partner's own Original Target - the bar's own
          # 0-1 scale, capped so an over-achieved partner's fill stops at
          # the bar's own full width rather than extending past it.
          fill_frac = ifelse(target_sample > 0, pmin(achieved_n / target_sample, 1), 0),
          # ADDED 2026-09-16b: the visible remainder of the bar (Achieved to
          # Original Target) - stacked on top of fill_frac so the FULL bar
          # always reaches exactly 1.0 (= Original Target), making the full
          # target length visible even where nothing's been achieved yet.
          # Shrinks to 0 once a partner reaches/exceeds Original (fill_frac
          # already capped at 1), which is exactly the desired behaviour.
          remaining_frac = 1 - fill_frac,
          # tick marker position: where Revised Target sits, expressed as a
          # fraction of Original - same denominator as the bar itself, so
          # the tick and the fill are directly comparable on one bar.
          revised_frac = ifelse(target_sample > 0, target_sample_current / target_sample, NA_real_),
          exceeded = !is.na(target_sample) & target_sample > 0 & achieved_n > target_sample,
          overflow_frac = ifelse(exceeded, 1.08, NA_real_),
          # REVISED 2026-09-16b: whole-fill-segment colour keyed off WHICH
          # STAGE a partner is at, not their pace status - checked in this
          # order deliberately (Original first) since meeting Original
          # implies meeting Revised too, and case_when takes the first
          # match.
          stage = factor(case_when(
            target_sample > 0 & achieved_n >= target_sample ~ "At/above Original Target",
            target_sample_current > 0 & achieved_n >= target_sample_current ~ "At/above Revised, below Original",
            TRUE ~ "Below Revised Target"
          ), levels = names(STAGE_COLORS)),
          hover_text = paste0(
            "Achieved: ", comma(achieved_n), " / Original Target: ", comma(target_sample),
            " (Revised Target: ", comma(round(target_sample_current)), ")",
            ifelse(exceeded, paste0("\nExceeded Original by ", comma(achieved_n - target_sample)), "")
          )
        )

      plot_ly(df) %>%
        add_bars(
          y = ~partner_label, x = ~fill_frac, color = ~stage, colors = STAGE_COLORS,
          orientation = "h", text = ~hover_text, hoverinfo = "text",
          textposition = "none", showlegend = TRUE
        ) %>%
        # REVISED 2026-09-16b: the visible "remaining to Original" segment -
        # outline-only (transparent fill, grey border), not a coloured
        # stage, so it reads as "not yet there" rather than a 4th status.
        add_bars(
          y = ~partner_label, x = ~remaining_frac, orientation = "h",
          marker = list(color = "rgba(0,0,0,0)", line = list(color = "#9AA3AF", width = 1)),
          hoverinfo = "skip", showlegend = FALSE, name = "Remaining to Original"
        ) %>%
        # Revised Target tick - a short vertical line marker on each bar.
        # REVISED 2026-09-16b: was much thicker than the bar itself
        # (size=26, width=3) causing heavy overlap - thinned down.
        add_markers(
          y = ~partner_label, x = ~revised_frac, hoverinfo = "text",
          text = ~paste0("Revised Target: ", comma(round(target_sample_current))),
          marker = list(symbol = "line-ns", size = 13, line = list(width = 2, color = "#1B2A4A")),
          showlegend = FALSE, name = "Revised Target"
        ) %>%
        # overflow indicator for a partner past their Original Target - a
        # capped bar (fill+remaining stop at 1) plus a small marker just
        # beyond it, rather than letting the bar itself extend past 100%.
        add_markers(
          data = df %>% filter(exceeded), y = ~partner_label, x = ~overflow_frac, hoverinfo = "text",
          text = ~hover_text, marker = list(symbol = "triangle-right", size = 12, color = "#D99A2B"),
          showlegend = FALSE, name = "Exceeded Original"
        ) %>%
        layout(
          barmode = "stack",
          # No numeric tick labels - "100%" on this axis means a different
          # absolute number on every row, so a shared percentage scale
          # would misleadingly imply otherwise. Real numbers live in the
          # hover text/bar labels instead.
          xaxis = list(title = "Progress toward each partner's own Original Target", showticklabels = FALSE, range = c(0, 1.15), zeroline = FALSE),
          # categoryorder/categoryarray pinned explicitly (2026-09-16b) -
          # see partner_order's own comment above for why.
          yaxis = list(title = "", categoryorder = "array", categoryarray = partner_order),
          legend = list(orientation = "h", y = -0.08),
          margin = list(l = 160, r = 20, t = 10, b = 40)
        )
    })

    # ---- OLD chart, kept as the simplified secondary view (Jack: "a very
    # clear vision on % achieved of our minimum") - REDEFINED 2026-09-16 to
    # show % against Revised Target specifically, not Original as it did
    # under Decision A - a deliberate, different question from the new
    # chart/Priority/the rest of the dashboard, computed locally here only.
    output$partner_bar_pct <- renderPlotly({
      df <- partner_progress_summary %>%
        mutate(
          partner_label = factor(partner_label, levels = partner_order),
          pct_achieved_revised = ifelse(target_sample_current > 0, achieved_n / target_sample_current, NA_real_),
          # BUG FIX 2026-09-16b (Jack: MDM showed 103% but still red - the
          # displayed % had already switched to Revised Target, but the
          # fill colour was still keyed off partner_progress_summary's own
          # `status`, which per Decision A is ORIGINAL-target-based. Full
          # status recomputed here against Revised instead, mirroring
          # partner_progress_summary's own formula (global.R) exactly, not
          # just patching the Complete threshold in isolation - pace itself
          # (current_daily_pace/start_date) doesn't depend on which target
          # you're judging completion against, only remaining/projected
          # finish do, so those two are the only pieces recomputed.
          remaining_revised = pmax(target_sample_current - achieved_n, 0),
          projected_finish_revised = if_else(
            !is.na(current_daily_pace) & current_daily_pace > 0 & remaining_revised > 0,
            today_for_pace + ceiling(remaining_revised / current_daily_pace),
            as.Date(NA)
          ),
          status_revised = case_when(
            target_sample_current <= 0 ~ "Complete",
            achieved_n >= target_sample_current ~ "Complete",
            is.na(start_date) ~ "Not started",
            is.na(current_daily_pace) | current_daily_pace <= 0 ~ "Behind pace",
            projected_finish_revised <= FIELDING_PLANNED_END ~ "On pace",
            TRUE ~ "Behind pace"
          )
        )

      plot_ly(
        df, y = ~partner_label, x = ~pct_achieved_revised, color = ~status_revised, colors = partner_pace_colors,
        type = "bar", orientation = "h",
        text = ~paste0(comma(achieved_n), " / ", comma(round(target_sample_current)), " (", percent(pct_achieved_revised, accuracy = 1), " of Revised)"),
        textposition = "outside", hoverinfo = "text"
      ) %>%
        layout(
          xaxis = list(title = "% of Revised Target achieved", tickformat = ".0%", range = c(0, 1.15)),
          yaxis = list(title = "", categoryorder = "array", categoryarray = partner_order),
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
        # 2026-09-14 (Jack): Original/Revised Target were showing raw
        # unrounded decimals here - target_sample_current (global.R) is now
        # sourced straight from 1_sampling's representativity calc ("Target
        # sample ... incl. 5% operational margin"), which is genuinely
        # fractional by construction, never rounded upstream. The KPI cards
        # elsewhere on this tab looked "clean" only because comma() defaults
        # to whole-number rounding on a single summed value - this table was
        # passing the raw column straight to DT with no such rounding, so
        # the same underlying number displayed differently in two places on
        # one page. Display-only rounding (sorting/filtering still use the
        # exact value) - restores the match the cards already implied.
        formatRound(c("Original Target", "Revised Target"), 0) %>%
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
