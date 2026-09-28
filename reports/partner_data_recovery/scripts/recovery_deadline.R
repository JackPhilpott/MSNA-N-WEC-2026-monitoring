# The one place the recovery "return by" date lives (2026-09-25, Jack, decision Q).
#
# EMAIL_DEADLINE is the date a partner must RETURN its recovery workbook by. It is used
# verbatim in BOTH the covering email (run_full_batch_emails.R -> build_partner_email_html())
# and the workbook's own READ ME sheet (run_full_batch.R -> build_partner_workbook()), so the
# two can never disagree. Before this file the email carried "28 September 2026" (a constant in
# run_full_batch_emails.R) while the workbook silently kept build_workbook_fn.R's stale
# "4 September 2026" default, because run_full_batch.R never passed a deadline.
#
# This is NOT the end of field collection and is deliberately not linked to
# FIELDING_PLANNED_END (dashboard_app/global.R, the Round 1 / IPC-CH cut-off, 27 Sep): the return
# date is a hand-set choice per recovery round. Bump it here, by hand, for the next round.
EMAIL_DEADLINE <- "28 September 2026"
