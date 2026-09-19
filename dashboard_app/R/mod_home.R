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
            "field — includes oversampled surplus) and ", strong("Achieved"),
            " (completed, matched interviews that are not a SETTLED, confirmed tracker ",
            "deletion — capped at each CLUSTER's own target before being summed up to ",
            "LGA/partner level — what actually counts toward the sample frame). Policy changed ",
            "2026-09-11: a pending/unresolved flag (duplicate, unmatched, a still-open ",
            "recovery-workbook item) no longer excludes an interview from Achieved — only an ",
            "actually-confirmed deletion does. A cluster that's been oversampled never contributes more than ",
            "its own target to Achieved, so padding an easy-to-reach cluster can't compensate ",
            "for, or mask, under-coverage somewhere else. A large Collected-vs-Achieved gap for ",
            "a partner or LGA usually means real oversampling, worth reviewing so an over-collected ",
            "cluster isn't asked for more. Look for the ", icon("circle-info", class = "text-muted"), " icon next to ",
            "a figure for its exact definition."
          ),
          p(
            strong("A live, evolving sampling frame: "),
            "the sampling frame — and every target figure this dashboard shows, whether ",
            "national, per-LGA, or per-cluster — reflects the ", strong("current"), " iteration ",
            "of an ongoing sampling process, not a single design fixed at the start of ",
            "fielding. As partners report on accessibility (insecurity, denied access, etc.), ",
            "newly-inaccessible areas are excluded from potential sampling, and remaining ",
            "accessible areas can gain supplementary clusters to help make up what was lost — ",
            "so which specific clusters and wards are currently in scope, and occasionally the ",
            "national target itself (see the revision note under ", em("Target interviews"),
            " in \"At a glance\"), can genuinely change over the course of fielding without any ",
            "data-quality issue. ",
            if (!is.na(FRAME_AS_OF_LABEL)) {
              tagList(strong(FRAME_AS_OF_LABEL), " — every figure on this dashboard reflects this version of the frame.")
            } else {
              "The frame's current version date isn't available right now."
            }
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

mod_home_server <- function(id, target_basis) {
  moduleServer(id, function(input, output, session) {
    # 2026-09-19 (global target-basis toggle, Jack-approved build): Home's
    # national KPIs used to read the static progress_by_stratum global
    # (global.R, permanently basis="original") directly — that would
    # silently ignore the sidebar toggle, since this module has no other
    # reactive input. Recomputed here instead, same pattern as
    # build_partner_progress_summary()/partner_progress_by_lga() in
    # global.R. Cheap enough to recompute on a toggle flip (infrequent,
    # deliberate) — not cached beyond the reactive's own memoisation.
    progress_active <- reactive(compute_progress_by_stratum(submissions_raw, target_basis()))

    output$glance <- renderUI({
      # progress_by_stratum$achieved_n, not sum(is_achieved(submissions_raw))
      # directly (2026-08-25 fix) — the latter is uncapped and has the same
      # oversampling-inflation issue this whole Collected/Achieved split was
      # built to fix; progress_by_stratum already applies the cluster-level
      # cap (see compute_progress_by_stratum(), global.R).
      #
      # 2026-09-14 (Jack, explicit general rule): a Dropped stratum's real
      # data must never enter a national/regional sum, only ever shown at
      # its own stratum/LGA row (surfaced by Tsafe/idp_NG037013 - 54 real
      # achieved interviews, held indicative-only, not blended into any
      # topline figure). Filtered here as one shared base so every total on
      # this row stays internally consistent with each other (Collected =
      # Achieved + Confirmed Deletion + Oversampling Surplus must still hold
      # exactly - excluding Dropped from only one of the four would break
      # that identity, not just under-report it).
      national_agg <- progress_active() %>% filter(status != "Dropped")
      total_achieved <- sum(national_agg$achieved_n)
      # FIXED 2026-09-11: was sum(is_collected(submissions_raw)) - a raw,
      # unscoped sum over every submission, computed independently from the
      # other three figures on this row (which all come from
      # progress_by_stratum, itself scoped to strata_frame's current
      # roster). A completed interview whose cluster has since been
      # retired/dropped would inflate this while staying invisible to
      # Achieved/Confirmed/Pending - breaking the very identity this row
      # claims to hold exactly. Now sourced from the same roster-scoped
      # place as the other three, so the identity can't drift.
      total_collected <- sum(national_agg$collected_n)
      total_confirmed_deletion <- sum(national_agg$confirmed_deletion_n)
      total_pending_deletion <- sum(national_agg$pending_deletion_n)
      total_oversampling_surplus <- sum(national_agg$oversampling_surplus_n)
      # FIX 2026-09-16 (Decision A), extended 2026-09-19 (global toggle):
      # target_active (the toggle's current basis, "original" by default) -
      # matches every other headline "target" figure on this page now; the
      # Original vs. Revised national totals get their own row below
      # instead of forking this by-pop-type breakdown into two.
      target_by_pop <- national_agg %>% group_by(pop_type) %>% summarise(target = sum(target_active, na.rm = TRUE), .groups = "drop")
      target_non_idp <- target_by_pop$target[target_by_pop$pop_type == "non_idp"]
      target_idp <- target_by_pop$target[target_by_pop$pop_type == "idp"]
      n_states <- length(unique(strata_frame$adm1_name))
      n_regions <- length(unique(strata_frame$region))

      tags$table(
        class = "table table-sm",
        tags$tr(tags$td("Fielding window"), tags$td(strong(paste(format(FIELDING_START, "%d %b"), "-", format(FIELDING_PLANNED_END, "%d %b %Y"))))),
        tags$tr(
          tags$td("Original Target", info_icon("The frozen design-time total across all covered LGAs, unchanged since fielding began — this page always shows the national picture and is not affected by the sidebar filters.")),
          tags$td(strong(comma(TOTAL_PLANNED_INTERVIEWS)))
        ),
        tags$tr(
          tags$td("Revised Target", info_icon("The LIVE required minimum — 1_sampling's own representativity calculation (10% margin of error, ICC=0.06, +5% flat operational margin), recomputed fresh every refresh against the CURRENT accessible population for every covered stratum. Corrected 2026-09-14: unlike the old capacity-based figure, this can both rise AND fall (accessibility loss or a dropped LGA lowers the population base it's calculated against) — a retroactive correction against current conditions, not a one-way ratchet that only ever grows. Achieved/% achieved/Status everywhere on this dashboard are computed against Original Target, not this one (Decision A, 2026-09-16).")),
          # ADDED 2026-09-16 (Jack, visibility ask): fold the delta straight
          # into this row's own value, shared helper (global.R); red/bold
          # when the national-level gap crosses TARGET_DIVERGENCE_THRESHOLD.
          tags$td(
            strong(comma(TOTAL_PLANNED_INTERVIEWS_CURRENT)),
            if (nzchar(target_delta_label(TOTAL_PLANNED_INTERVIEWS, TOTAL_PLANNED_INTERVIEWS_CURRENT))) {
              tagList(
                " (",
                span(
                  style = if (is_significant_target_divergence(TOTAL_PLANNED_INTERVIEWS, TOTAL_PLANNED_INTERVIEWS_CURRENT)) "color:#C1443C; font-weight:bold;" else NULL,
                  target_delta_label(TOTAL_PLANNED_INTERVIEWS, TOTAL_PLANNED_INTERVIEWS_CURRENT)
                ),
                ")"
              )
            }
          )
        ),
        if (HAS_TARGET_REVISION) {
          tags$tr(
            tags$td(colspan = 2, class = "text-muted", style = "font-size: 0.82em; padding-top: 0;",
              paste0(
                "Separately, the design's own baseline has itself been revised at least once: original baseline at fielding start (", format(BASELINE_TARGET_DATE, "%d %b %Y"), "): ", comma(BASELINE_TARGET_SAMPLE), ". ",
                "Revised ", format(LATEST_TARGET_REVISION$date, "%d %b %Y"), ": now ", comma(LATEST_TARGET_REVISION$total_target),
                " — ", LATEST_TARGET_REVISION$reason, ". (A different thing from Original vs. Revised Target above — this is a deliberate, reasoned change to the design itself; Revised Target above is recomputed automatically every refresh against the live accessible population, and can rise or fall on its own.)"
              )
            )
          )
        },
        tags$tr(
          tags$td("Achieved so far", info_icon(paste0("Completed, matched interviews that are not a SETTLED (confirmed/contested) tracker deletion, capped at each cluster's own target. Policy changed 2026-09-11: a pending/unresolved flag (duplicate, unmatched, still-open tracker item) no longer excludes an interview from Achieved - only an actually-confirmed deletion does. See 'Pending Deletion' below for how much of this is still at risk of moving. Oversampled surplus never counts here. National total, not affected by the sidebar filters. The % here follows the sidebar's Target basis toggle (currently ", target_basis_label(target_basis()), ") - was hardcoded to Original under Decision A, now switchable."))),
          tags$td(strong(comma(total_achieved), " (", fmt_pct(total_achieved / active_planned_interviews(target_basis())), " of ", target_basis_label(target_basis()), ")"))
        ),
        tags$tr(
          tags$td("Collected so far", info_icon("Every completed interview actually done — includes oversampled surplus and any interview since removed by a confirmed deletion. Total field effort, not what counts toward target.")),
          tags$td(strong(comma(total_collected)))
        ),
        tags$tr(
          tags$td("Confirmed Deleted / Oversampling Surplus", info_icon("Of Collected but not Achieved (changed 2026-09-11 — see Achieved above): CONFIRMED DELETED is a settled tracker deletion — genuinely gone, feeds resampling. OVERSAMPLING SURPLUS is real, completed interviews beyond what a cluster's own target calls for — capped out of Achieved by design, not a data problem, but likely needs reviewing so a genuinely over-collected cluster doesn't keep being asked for more. Collected always equals Achieved + Confirmed Deleted + Oversampling Surplus, exactly.")),
          tags$td(strong(comma(total_confirmed_deletion), " / ", comma(total_oversampling_surplus)))
        ),
        tags$tr(
          tags$td("Pending Deletion", info_icon("Informational only (changed 2026-09-11 — no longer part of the Collected/Achieved/Confirmed/Surplus identity above): how many of the interviews already counted in Achieved still carry an unresolved tracker flag (duplicate, unmatched, a still-open recovery-workbook item) that could still result in a confirmed deletion later. Included in Achieved for now, per Jack's explicit decision — not subtracted.")),
          tags$td(strong(comma(total_pending_deletion)))
        ),
        tags$tr(
          tags$td("Oversampled clusters", info_icon("Clusters with more achieved interviews than their own target_households — the surplus never counts toward Achieved or masks under-coverage elsewhere, but represents field effort spent past target that will likely need reviewing for deletion. Not a new sample design; a cluster's target is unchanged.")),
          tags$td(strong(comma(nrow(oversampled_clusters)), " (", comma(sum(oversampled_clusters$surplus)), " surplus interviews)"))
        ),
        tags$tr(tags$td("Target by population group"), tags$td(strong("Non-IDP: ", comma(target_non_idp), " / IDP: ", comma(target_idp)))),
        tags$tr(tags$td("Covered LGAs"), tags$td(strong(TOTAL_COVERED_LGAS))),
        tags$tr(tags$td("States / regions"), tags$td(strong(n_states, " states across ", n_regions, " regions (", paste(sort(unique(strata_frame$adm1_name)), collapse = ", "), ")"))),
        tags$tr(tags$td("Field partners"), tags$td(strong(length(setdiff(unique(partner_lga_assignment$org_id), "other"))))),
        tags$tr(
          tags$td("Partners with zero submissions", info_icon("Partners assigned at least one LGA who haven't submitted any interviews yet — worth a direct follow-up.")),
          tags$td(strong(if (length(PARTNERS_NOT_STARTED) == 0) "None" else paste(unname(ORG_LABELS[PARTNERS_NOT_STARTED]), collapse = ", ")))
        )
      )
    })

    output$snapshot <- renderUI({
      today_n <- max(submissions_raw$submission_date, na.rm = TRUE)
      # "that day"/"the day before" are activity counts, not a cumulative
      # figure with a target to cap against — left on the per-row
      # is_achieved() flag deliberately, unlike total_achieved below.
      achieved_mask <- is_achieved(submissions_raw)
      # FIX 2026-09-17 (real bug, reported live: this was showing NA):
      # submission_date is deliberately nulled for a handful of real,
      # kept, achieved rows with an implausible original date (see
      # prep_real_submissions.R's own "implausible submission_date"
      # warning) - for those rows `submission_date == today_n` is NA, and
      # NA & TRUE is NA, so without na.rm the whole sum() collapsed to NA
      # the moment even one such row was also achieved. na.rm=TRUE just
      # drops those unknown-day rows from both counts (correct - their
      # real day is unknown, so they can't be attributed to either).
      yesterday_n <- sum(submissions_raw$submission_date == (today_n - 1) & achieved_mask, na.rm = TRUE)
      today_count <- sum(submissions_raw$submission_date == today_n & achieved_mask, na.rm = TRUE)
      # capped (progress_by_stratum), not sum(achieved_mask) directly — see
      # the matching note in output$glance above. Also excludes Dropped
      # strata (2026-09-14, same rule as output$glance) so this stays
      # exactly "same figure as Achieved so far above", as the info_icon
      # below claims.
      total_achieved <- sum(progress_active()$achieved_n[progress_active()$status != "Dropped"])
      total_collected <- sum(is_collected(submissions_raw))
      # FIX 2026-09-16 (Decision A), extended 2026-09-19 (global toggle):
      # follows the sidebar's Target basis toggle, matching output$glance
      # above and every other headline % on the dashboard now.
      total_target <- active_planned_interviews(target_basis())
      last_upload <- max(submissions_raw$uploaded_at, na.rm = TRUE)

      tags$table(
        class = "table table-sm",
        tags$tr(tags$td("Latest submission date in the data"), tags$td(strong(format(today_n, "%d %b %Y")))),
        tags$tr(tags$td("Submissions that day"), tags$td(strong(comma(today_count)))),
        tags$tr(tags$td("Submissions the day before"), tags$td(strong(comma(yesterday_n)))),
        tags$tr(
          tags$td("Total achieved to date", info_icon(paste0("Completed, matched interviews that are not a SETTLED (confirmed/contested) tracker deletion, capped at each cluster's own target. Policy changed 2026-09-11: a pending/unresolved flag no longer excludes an interview here, only a confirmed deletion does — same figure resampling now uses too. Oversampled surplus never counts here. National total, not affected by the sidebar filters — same figure as \"Achieved so far\" above, shown again here alongside today's daily activity for context. Denominator follows the sidebar's Target basis toggle (currently ", target_basis_label(target_basis()), ")."))),
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
      worst_lgas <- progress_active() %>%
        filter(status != "Complete", target_active > 0) %>%
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
              tags$li(paste0(r$adm2_name, ", ", r$adm1_name, " (", unname(POP_TYPE_LABELS[r$pop_type]), ") — ", fmt_pct(r$pct_achieved), " (", r$achieved_n, "/", r$target_active, ")"))
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
