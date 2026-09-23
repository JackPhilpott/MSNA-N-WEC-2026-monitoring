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
    # Six tiles at col_widths 4, two rows of three. Order was Achieved >
    # follow-up gap > Collected > % of target > days remaining > days
    # required (Jack, 2026-09-04); re-ordered 2026-09-22 so the top row is
    # the three figures that reconcile with each other - Achieved, Still
    # needed, % of target - and the bottom row is effort and time.
    # REBUILT 2026-09-22 (Jack: "the dashboard summary page is generally a
    # bit confusing now the numbers don't align fully"). Three changes:
    # (1) a "Still needed" tile - the post-cap figure was nowhere on this
    #     page, so a reader subtracted Achieved from planned and got the
    #     wrong number whenever any stratum had over-collected (1,293
    #     nationally the day this was built: planned - achieved read 7,746
    #     against a real 9,039 still needed);
    # (2) the "Collected - Achieved" tile is gone, replaced by plain
    #     "Collected" - its value silently mixed confirmed deletions,
    #     interviews in Dropped strata and unmatched submissions, and its
    #     own tooltip still said "duplicates", which have counted toward
    #     Achieved since 2026-09-11. The split now lives in the (i);
    # (3) every supporting number moved INTO the (i) tooltips rather than
    #     onto the card faces (Jack, explicit: "not to confuse/clutter the
    #     space"), which is why these four titles are rendered server-side -
    #     the tooltips carry live figures, not static prose.
    layout_columns(
      col_widths = c(4, 4, 4, 4, 4, 4),
      value_box(
        title = uiOutput(ns("kpi_achieved_title")),
        value = textOutput(ns("kpi_achieved")),
        showcase = icon("clipboard-check"),
        theme = "primary"
      ),
      value_box(
        title = uiOutput(ns("kpi_still_needed_title")),
        value = textOutput(ns("kpi_still_needed")),
        showcase = icon("list-check"),
        theme = "danger"
      ),
      value_box(
        title = uiOutput(ns("kpi_pct_title")),
        value = textOutput(ns("kpi_pct")),
        showcase = icon("percent"),
        theme = "success"
      ),
      value_box(
        title = uiOutput(ns("kpi_collected_title")),
        value = textOutput(ns("kpi_collected")),
        showcase = icon("layer-group"),
        theme = "warning"
      ),
      value_box(
        title = info_title(
          "Planned days remaining",
          "Calendar days left until the planned end date — a fixed countdown, not a pace estimate."
        ),
        value = textOutput(ns("kpi_days_remaining")),
        showcase = icon("calendar-days"),
        theme = "secondary"
      ),
      value_box(
        title = info_title(
          "Est. days required",
          "Days still needed to close what's outstanding, at the pace of the LAST 7 DAYS. Changed 2026-09-22 (Jack): this used to divide by the average pace since fielding began, which included every early-surge day and read faster than the teams are currently working. Compare to Planned days remaining to see if you're on track.",
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
          info_icon("Bars = new interviews per day. Green line = cumulative Achieved to date (ALL interviews incl. any surplus past a stratum's own target - the raw count, deliberately). Red dotted line = the steady pace needed to hit target by the deadline. Above the line = ahead of pace in total field effort - but surplus in one stratum can't close a gap in another, so read this alongside the '% of target' tile above (credited per stratum) before concluding the target itself is on track."),
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
        info_icon("Shows every assigned partner nationally, regardless of sidebar filters. Target includes every LGA assigned to them, even ones not yet started. Achieved reflects the whole LGA's progress, including any partner sharing it (see 'Shared with')."),
        span(class = "text-muted", style = "font-size: 0.8em; font-weight: normal; margin-left: 8px;", "Charts sorted by % of target achieved (lowest first); the table below opens sorted by Still needed, largest first")
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

mod_progress_server <- function(id, filtered_subs, filtered_stratum, target_basis) {
  moduleServer(id, function(input, output, session) {
    completed_subs <- reactive({
      filtered_subs() %>% filter(interview_outcome == "completed", !is_duplicate)
    })

    # ---- headline figures, computed once per (filter, basis) and shared by
    # every tile + its tooltip below, so a tile face and its own (i) can
    # never disagree (2026-09-22).
    headline <- reactive({
      s <- filtered_stratum() %>% filter(status != "Dropped")
      ach <- sum(s$achieved_n, na.rm = TRUE)
      cred <- sum(s$credited_achieved_n, na.rm = TRUE)
      list(
        target = sum(s$target_active, na.rm = TRUE),
        achieved = ach,
        credited = cred,
        # interviews sitting above their own stratum's target: the exact
        # amount by which "planned - achieved" understates Still needed
        surplus = ach - cred,
        remaining = sum(s$remaining_n, na.rm = TRUE),
        # shared with the Home page's own split - see collected_breakdown()
        # in global.R (2026-09-22) for why this isn't computed locally.
        cb = collected_breakdown(filtered_stratum(), filtered_subs())
      )
    })

    output$kpi_achieved_title <- renderUI({
      h <- headline()
      info_title(
        "Interviews achieved",
        paste0(
          "Every completed interview that counts - excludes confirmed deletions, and includes in full any collected past a stratum's own target. ",
          "Of these, ", comma(h$credited), " count toward the target of ", comma(h$target),
          if (h$surplus > 0) paste0(", and ", comma(h$surplus), " are extra interviews in strata already at target - which is why planned minus achieved is NOT what's still needed. ") else ". ",
          "See the Still needed tile for the real remaining figure."
        ),
        icon_color = "white"
      )
    })

    output$kpi_still_needed_title <- renderUI({
      h <- headline()
      info_title(
        "Still needed",
        paste0(
          "What is actually still required: every stratum's own remaining gap, floored at zero and then summed, so surplus in one place never cancels a shortfall in another. ",
          comma(h$credited), " counted toward target + ", comma(h$remaining), " still needed = ", comma(h$target), " target. ",
          "Added 2026-09-22 - this figure drives the partner workbooks' 'Still Needed' too, and the two now always agree."
        )
      )
    })

    output$kpi_pct_title <- renderUI({
      h <- headline()
      info_title(
        "% of target",
        paste0(
          "Progress toward target, capped per stratum before summing - an oversampled stratum's surplus never offsets another's shortfall, so this can't read 100% while any stratum is still short. ",
          comma(h$credited), " of ", comma(h$target), ". ",
          "The raw share (all interviews incl. surplus / target) was removed 2026-09-22 per Jack - two competing percentages for the same thing read as the dashboard contradicting itself."
        )
      )
    })

    output$kpi_collected_title <- renderUI({
      cb <- headline()$cb
      gap <- cb$gap
      unmatched <- cb$unmatched
      info_title(
        "Collected",
        paste0(
          "Every completed interview done - total field effort, not what counts toward the sample. ",
          comma(gap), " of these don't count toward target: ", comma(cb$confirmed), " confirmed deletions, ",
          comma(cb$dropped_collected), " in strata dropped from the design, ", comma(unmatched), " not matched to a sampled cluster",
          if (cb$surplus > 0) paste0(", ", comma(cb$surplus), " match-quality residual. ") else ". ",
          "Replaced the old 'Collected - Achieved' tile on 2026-09-22, which showed only that total with no split and still described it as duplicates (duplicates have counted toward Achieved since 2026-09-11)."
        )
      )
    })

    output$kpi_still_needed <- renderText(comma(headline()$remaining))

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
      # FIX 2026-09-16 (Decision A), extended 2026-09-19 (global toggle):
      # target_active - see global.R's compute_progress_by_stratum().
      # 2026-09-22: the planned total moved off this card face into the
      # (i) and the "% of target" tile. Showing "achieved / planned" here
      # invited the subtraction that this page kept getting wrong - see the
      # Still needed tile.
      comma(sum(s$achieved_n, na.rm = TRUE))
    })

    output$kpi_pct <- renderText({
      # credited_achieved_n is capped at each stratum's own target BEFORE
      # the sum (compute_progress_by_stratum(), global.R), so this tile
      # can't read "done" while any stratum is still short. The raw ratio
      # that used to sit beside it in brackets was removed 2026-09-22 per
      # Jack - see this tile's own tooltip.
      h <- headline()
      if (h$target <= 0) return(fmt_pct(NA_real_))
      fmt_pct(h$credited / h$target)
    })

    output$kpi_collected <- renderText({
      # Total field effort — every completed interview, unconditional (see
      # is_collected() in global.R). Deliberately NOT summed from
      # filtered_stratum()$collected_n, which only counts rows that resolved
      # to a real stratum_id — this total should never undercount just
      # because a handful of submissions couldn't be attributed to one.
      # Taken from the shared collected_breakdown() (2026-09-22) so the tile
      # face and its own tooltip can't come from two different sums.
      comma(headline()$cb$collected)
    })

    # kpi_followup ("Collected - Achieved") REMOVED 2026-09-22 - replaced by
    # the plain Collected tile, whose tooltip now splits that same gap into
    # confirmed deletions / dropped strata / unmatched instead of showing
    # one unexplained total.

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
      subs <- filtered_subs()
      # FIX 2026-09-21: remaining_n is floored per stratum then summed
      # (global.R) - was max(sum(target) - sum(achieved), 0), one
      # subtraction after summing raw achieved across every stratum in
      # scope, which let surplus in one stratum hide a shortfall in
      # another.
      remaining <- headline()$remaining
      if (remaining <= 0) return("Target met")
      # CHANGED 2026-09-22 (Jack: "let's do 7 day pace"): the rate is now
      # the last 7 days of achieved interviews, not the average since this
      # scope's first submission. The lifetime average included the early
      # ramp-up and every since-completed stratum's peak - nationally it
      # read 502/day against 414/day over the last week, i.e. 19 days to
      # finish where the teams' current speed implies 22. PACE_WINDOW_DAYS
      # is the whole mechanism, so widening/narrowing the window is a
      # one-line change rather than a rewrite.
      PACE_WINDOW_DAYS <- 7
      window_start <- today_for_pace - (PACE_WINDOW_DAYS - 1)
      recent <- sum(is_achieved(subs) & !is.na(subs$submission_date) & subs$submission_date >= window_start, na.rm = TRUE)
      rate <- recent / PACE_WINDOW_DAYS
      if (!is.finite(rate) || rate <= 0) return("N/A")
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
      # the quality-exclusion filter) - a THIRD, unlabelled quantity despite
      # the legend saying "Cumulative achieved". Applies the exact same
      # is_achieved() filter compute_progress_by_stratum() uses (global.R),
      # summed cumulatively per day, so the line's last point reconciles
      # exactly with the Achieved KPI tile above (verified via the smoke
      # test). Restricted to matched_strata_id %in% filtered_stratum()'s own
      # strata_id, not just is_achieved(filtered_subs()) directly -
      # filtered_stratum() applies its own state/LGA/pop-type/partner filter
      # AFTER compute_progress_by_stratum(), so a handful of rows could
      # otherwise sit in a stratum filtered_stratum() has excluded, breaking
      # that same reconciliation.
      #
      # UNCAPPED as of 2026-09-20 (Jack's explicit decision, informed by
      # discussion with donors: achieved should include all oversampled
      # interviews, target stays as-is) - this used to also apply the same
      # per-cluster-per-day pmin(cumsum(n), target_households) cap
      # compute_progress_by_stratum() applied before that date (removed
      # there in the same pass, see that function's own header in global.R
      # for the full reasoning). Since every cluster's cumulative count is
      # no longer capped, the cluster_targets join this needed is gone too.
      achieved_scope <- filtered_stratum()$strata_id
      achieved_rows <- filtered_subs() %>%
        filter(is_achieved(.), matched_strata_id %in% achieved_scope, !is.na(matched_cluster_id))

      if (nrow(achieved_rows) == 0) {
        by_day_total <- tibble(
          submission_date = seq(min(df$submission_date), max(df$submission_date), by = "day"),
          cumulative = 0
        )
      } else {
        by_day_total <- achieved_rows %>%
          count(matched_cluster_id, submission_date, name = "n") %>%
          complete(
            submission_date = seq(min(df$submission_date), max(df$submission_date), by = "day"),
            nesting(matched_cluster_id),
            fill = list(n = 0)
          ) %>%
          arrange(matched_cluster_id, submission_date) %>%
          group_by(matched_cluster_id) %>%
          mutate(cum_n = cumsum(n)) %>%
          ungroup() %>%
          group_by(submission_date) %>%
          summarise(cumulative = sum(cum_n), .groups = "drop") %>%
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
      # FIX 2026-09-16 (Decision A), extended 2026-09-19 (global toggle):
      # target_active - "pace needed to finish on time" is a Still-Needed
      # concept, same basis as the KPI tiles above now.
      target_total <- sum(filtered_stratum() %>% filter(status != "Dropped") %>% pull(target_active), na.rm = TRUE)
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
      # FIX 2026-09-16 (Decision A), extended 2026-09-19 (global toggle):
      # target_active - follows the sidebar's Target basis toggle now.
      # FIX 2026-09-21: credited_achieved_n (capped per stratum in
      # global.R) instead of raw achieved_n - a region bar collapses many
      # strata, exactly where surplus in one masked shortfall in another.
      by_region_pop <- region_base %>%
        group_by(region, pop_type) %>%
        summarise(target_active = sum(target_active, na.rm = TRUE), credited_achieved_n = sum(credited_achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(pct = ifelse(target_active > 0, credited_achieved_n / target_active, 0), series = unname(POP_TYPE_LABELS[pop_type]))

      combined <- region_base %>%
        group_by(region) %>%
        summarise(target_active = sum(target_active, na.rm = TRUE), credited_achieved_n = sum(credited_achieved_n, na.rm = TRUE), .groups = "drop") %>%
        mutate(pct = ifelse(target_active > 0, credited_achieved_n / target_active, 0), series = "Combined")

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
          xaxis = list(title = "% of target achieved (credited per stratum - surplus never offsets another stratum's gap)", tickformat = ".0%", range = c(0, 1.2)),
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
    #
    # 2026-09-19 (global target-basis toggle), REVISED 2026-09-20 (Jack,
    # explicit): partner_bar_abs stays PERMANENTLY pinned to Original -
    # "each partner's own Original Target" is baked into its own axis title
    # and its whole bullet-chart design (a Revised-Target tick mark on an
    # Original-scaled bar), and Jack confirmed it "accurately depicts both"
    # already, unchanged. partner_bar_pct was ALSO permanently pinned
    # (to Revised, since 2026-09-16b) until today - Jack's own words: "now I
    # would have this one reflect the status of the original/revised toggle
    # universal filter" - so it now reads target_active/pct_achieved/status
    # straight off partner_summary_active() below (already computed against
    # whichever basis is active - see build_partner_progress_summary() in
    # global.R), same as partner_table just below it. partner_order still
    # deliberately stays pinned to the static, Original-based
    # partner_progress_summary - it's shared by BOTH charts to keep their
    # row order visually consistent with each other (see its own comment
    # below), and reordering rows every time the toggle flips would be a
    # confusing side effect nobody asked for; only the BAR VALUES on
    # partner_bar_pct move with the toggle now, not which row is on top.
    partner_summary_active <- reactive(build_partner_progress_summary(target_basis()))
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
          # FIX 2026-09-21: credited_achieved_n (per-stratum capped, from
          # build_partner_progress_summary(), original basis here) - raw
          # achieved_n let a partner's oversampled LGA fill in for a short
          # one. pmin(...,1) kept as a belt-and-braces guard only.
          fill_frac = ifelse(target_sample > 0, pmin(credited_achieved_n / target_sample, 1), 0),
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
          # FIX 2026-09-21: "At/above Original" now means every stratum
          # met its own target (remaining_n == 0, per-stratum floored),
          # not raw partner-total >= partner-target. The Revised-stage
          # test stays raw: this static summary is original-basis only, so
          # there's no revised-basis credited figure to key it off - a
          # known, documented residual, not an oversight.
          stage = factor(case_when(
            target_sample > 0 & remaining_n <= 0 ~ "At/above Original Target",
            target_sample_current > 0 & achieved_n >= target_sample_current ~ "At/above Revised, below Original",
            TRUE ~ "Below Revised Target"
          ), levels = names(STAGE_COLORS)),
          hover_text = paste0(
            "Credited toward target: ", comma(credited_achieved_n), " / Original Target: ", comma(target_sample),
            "\nStill needed: ", comma(remaining_n),
            "\nAll interviews (incl. surplus): ", comma(achieved_n),
            " (Revised Target: ", comma(round(target_sample_current)), ")",
            ifelse(exceeded, paste0("\nExceeded Original in total by ", comma(achieved_n - target_sample)), "")
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
          xaxis = list(title = "Progress toward each partner's own Original Target (always Original — independent of the sidebar's Target basis toggle)", showticklabels = FALSE, range = c(0, 1.15), zeroline = FALSE),
          # categoryorder/categoryarray pinned explicitly (2026-09-16b) -
          # see partner_order's own comment above for why.
          yaxis = list(title = "", categoryorder = "array", categoryarray = partner_order),
          legend = list(orientation = "h", y = -0.08),
          margin = list(l = 160, r = 20, t = 10, b = 40)
        )
    })

    # ---- Secondary view (Jack: "a very clear vision on % achieved of our
    # minimum") - was permanently redefined 2026-09-16 to always show %
    # against Revised Target specifically, independent of Decision A/the
    # sidebar toggle. REVISED 2026-09-20 (Jack, explicit): now follows the
    # sidebar's Target basis toggle instead, matching the rest of the
    # dashboard - reads target_active/pct_achieved/status straight off
    # partner_summary_active() (global.R's build_partner_progress_summary(),
    # already computed against whichever basis is active), rather than
    # re-deriving a local "_revised" variant of the same pace/status logic
    # as before - that duplication is what caused the 2026-09-16b MDM bug
    # (fill colour keyed off a different basis than the displayed %) in the
    # first place; reusing the one shared computation removes the class of
    # bug, not just this instance of it.
    output$partner_bar_pct <- renderPlotly({
      df <- partner_summary_active() %>%
        mutate(partner_label = factor(partner_label, levels = partner_order))

      plot_ly(
        df, y = ~partner_label, x = ~pct_achieved, color = ~status, colors = partner_pace_colors,
        type = "bar", orientation = "h",
        # FIX 2026-09-21: pct_achieved here is credited (per-stratum
        # capped) as of build_partner_progress_summary(); label shows
        # credited / target with the raw all-interviews count alongside.
        text = ~paste0(comma(credited_achieved_n), " / ", comma(round(target_active)), " (", percent(pct_achieved, accuracy = 1), " of ", target_basis_label(target_basis()), "; ", comma(achieved_n), " incl. surplus)"),
        textposition = "outside", hoverinfo = "text"
      ) %>%
        layout(
          xaxis = list(title = paste0("% of ", target_basis_label(target_basis()), " achieved"), tickformat = ".0%", range = c(0, 1.15)),
          yaxis = list(title = "", categoryorder = "array", categoryarray = partner_order),
          legend = list(orientation = "h", y = -0.08),
          margin = list(l = 160, r = 20, t = 10, b = 40)
        )
    })

    output$partner_table <- renderDT({
      # 2026-09-19: unlike the two charts above (deliberately pinned, see
      # comment on partner_summary_active's own definition), this plain
      # reference table follows the sidebar's Target basis toggle - Achieved/
      # % achieved/Status come from partner_summary_active()'s target_active-
      # based columns; Original/Revised Target stay their own two explicit
      # reference columns regardless, unaffected by the toggle.
      df <- partner_summary_active() %>%
        transmute(
          Partner = partner_label,
          `Original Target` = target_sample, `Revised Target` = target_sample_current,
          Collected = collected_n, `Confirmed Deleted` = confirmed_deletion_n, `Oversampling Surplus` = oversampling_surplus_n,
          `Pending Deletion` = pending_deletion_n,
          Achieved = achieved_n,
          # FIX 2026-09-21 ("show both"): Achieved stays the raw all-
          # interviews count; the two new columns are the per-stratum-
          # capped/floored rollups; % achieved is credited-based (can't
          # read 100% while any stratum is short), raw % kept alongside.
          `Credited toward target` = credited_achieved_n,
          `Still needed` = remaining_n,
          `% achieved` = pct_achieved,
          # "% achieved (raw)" REMOVED 2026-09-22 (Jack) - Achieved above is
          # still the full raw interview count, so nothing is hidden; it
          # just isn't shown as a second, competing percentage.
          `Shared with` = shared_with,
          `Start date` = start_date,
          `Current daily pace` = round(current_daily_pace, 1),
          `Required daily pace` = round(required_daily_pace, 1),
          `Projected finish` = projected_finish_date,
          Status = factor(status, levels = c("Behind pace", "On pace", "Complete", "Not started"))
        )

      # 0-based (2026-09-22: "% achieved (raw)" removed): 0 Partner,
      # 1 Original Target, 2 Revised Target, 3 Collected, 4 Confirmed
      # Deleted, 5 Oversampling Surplus, 6 Pending Deletion, 7 Achieved,
      # 8 Credited toward target, 9 Still needed, 10 % achieved,
      # 11 Shared with, 12 Start date, 13 Current pace, 14 Required pace,
      # 15 Projected finish, 16 Status.
      datatable(
        df, rownames = FALSE, filter = "top",
        options = list(pageLength = 20, order = list(list(9, "desc")), columnDefs = list(list(className = "dt-right", targets = c(1:10, 13, 14))))
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
