# ==============================================================================
# run_refresh_and_deploy.R - ONE COMMAND for the MSNA N-WEC 2026 data refresh, dashboard deploy and frame/partner
# update. Built 2026-10-04 for the data officer, who runs it on his own laptop from the shared workspace.
#
#   Double-click run_refresh_and_deploy.bat           (the real run)
#   Double-click run_refresh_and_deploy_DRYRUN.bat    (everything except publishing - safe to try any time)
# or, from a terminal in 2_monitoring:
#   Rscript run_refresh_and_deploy.R [--dry-run] [--preflight-only] [--skip-phase2] [--skip-checks]
#
# Phase 0  PRE-FLIGHT - stops before touching anything if a must-have is missing: the workspace, R and its packages,
#          the shinyapps.io account, the newest anonymised export, no OneDrive conflict copies of the files the run
#          reads. Phase 2's needs (Python with openpyxl, its own --check-env) are warnings: they cannot stop the
#          dashboard refresh, but they show up now rather than after phase 1.
# Phase 1  DATA REFRESH + DASHBOARD DEPLOY - deploy_dashboard.R in its own R process: newest export -> checks ->
#          deletion overlays -> partner digest -> bundle (allowlist-checked) -> upload. Anything failing stops it
#          BEFORE the upload, so the dashboard that is live stays live. After a real upload the live app must answer.
# Phase 2  FRAME + PARTNER UPDATE - only after phase 1 succeeded: 1_sampling's
#          scripts/daily_update/run_frame_and_partner_update.py. Its result is reported; it never undoes or blocks
#          phase 1 (Jack, 4 Oct: "a second sequential process that gets triggered from the first").
# Phase 3  VALIDITY SUITE - validity_checks/run_all_checks.R (dashboard vs frames vs partner workbooks).
# REPORT   runs_log/<date_time>/RUN_REPORT.md in plain English, plus one complete log per phase.
#
# --dry-run         phase 1 refreshes and checks the data on this computer and builds the bundle, but skips the
#                   upload (MSNA_DEPLOY_DRY_RUN=1); phase 2 runs with --dry-run (writes nothing).
# --preflight-only  only phase 0, judged as for a REAL run (a missing shinyapps.io account is a FAIL; add --dry-run
#                   to judge readiness for a dry run). Changes no data; writes only its own report.
# --skip-phase2     stop after phase 1.            --skip-checks  don't run the validity suite.
#
# Exit codes: 0 everything OK | 10 pre-flight failed (nothing ran) | 20 phase 1 failed (live dashboard unchanged) |
#             30 phase 2 blocked, errored or could not start (dashboard updated, partner files unchanged) |
#             40 validity suite found a FAIL or could not run | 50 the launcher itself errored.
#
# Credentials: the shinyapps.io token is set up ONCE per laptop with rsconnect::setAccountInfo() (see
# DO_HANDOVER_RUNBOOK.md) and lives only in that Windows user's profile - never in this shared folder or in git.
# ==============================================================================

ARGS <- commandArgs(trailingOnly = TRUE)
PREFLIGHT_ONLY <- "--preflight-only" %in% ARGS  # just check this computer is ready for a REAL run; changes no data
DRY_RUN <- "--dry-run" %in% ARGS
SKIP_PHASE2 <- "--skip-phase2" %in% ARGS
SKIP_CHECKS <- "--skip-checks" %in% ARGS
APP_URL <- "https://impact-nga-jp.shinyapps.io/dashboard_app/"
SHINYAPPS_ACCOUNT <- "impact-nga-jp"
EXPORT_DIR <- "cleaning/MSNA_Data_Cleaning/output/anonymised_data"
EXPORT_PATTERN <- "^NGA2605_MSNA_anonymised_(\\d{4}-\\d{2}-\\d{2})\\.xlsx$"
EXPORT_STALE_DAYS <- 3
PHASE2_SCRIPT <- "1_sampling/scripts/daily_update/run_frame_and_partner_update.py"
PHASE2_SUMMARY <- "1_sampling/output/daily_update_runs/LATEST_SUMMARY.json"
VALIDITY_DIR <- "validity_checks"
REQUIRED_PACKAGES <- c("bslib", "cleaningtools", "cowplot", "data.table", "dplyr", "DT", "ggplot2", "htmltools",
                       "htmlwidgets", "jsonlite", "leaflet", "lubridate", "openxlsx", "plotly", "readr", "readxl",
                       "rsconnect", "scales", "sf", "shiny", "shinyWidgets", "stringdist", "stringr", "tidyr", "uuid")

# ---- where am I: the workspace, from MSNA_WORKSPACE or this file's own location (scripts/shared/project_root.R) ----
local({
  me <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  here <- if (length(me)) dirname(normalizePath(me[1], winslash = "/")) else getwd()
  source(file.path(here, "scripts/shared/project_root.R"))
})
Sys.setenv(MSNA_WORKSPACE = WORKSPACE_DIR)
RSCRIPT <- if (nzchar(Sys.getenv("MSNA_RSCRIPT"))) Sys.getenv("MSNA_RSCRIPT") else
  file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
Sys.setenv(MSNA_RSCRIPT = RSCRIPT)

STARTED <- Sys.time()
RUN_ID <- format(STARTED, "%Y-%m-%d_%H%M%S")
RUN_DIR <- file.path(MONITORING_DIR, "runs_log", paste0(RUN_ID, if (PREFLIGHT_ONLY) "_preflight" else if (DRY_RUN) "_dryrun" else ""))
MODE_LABEL <- if (PREFLIGHT_ONLY) "PRE-FLIGHT ONLY" else if (DRY_RUN) "DRY RUN" else ""
dir.create(RUN_DIR, recursive = TRUE, showWarnings = FALSE)
LAUNCHER_LOG <- file.path(RUN_DIR, "launcher.log")

say <- function(...) {
  msg <- paste0(...)
  cat(msg, "\n", sep = "")
  cat(format(Sys.time(), "%H:%M:%S"), " ", msg, "\n", sep = "", file = LAUNCHER_LOG, append = TRUE)
}
mins <- function(t0) sprintf("%.1f min", as.numeric(difftime(Sys.time(), t0, units = "mins")))
report <- list(phase0 = list(), phase1 = list(status = "not run"), phase2 = list(status = "not run"),
               phase3 = list(status = "not run"))
exit_code <- 0L

# Runs a command with everything it prints (stdout + stderr) going to a log file; returns its exit status.
# On Windows through cmd /c, which needs the whole command line wrapped in one more pair of quotes.
run_to_log <- function(exe, args, log, workdir = NULL) {
  q <- function(x) paste0('"', x, '"')
  line <- paste(c(q(exe), args, ">", q(log), "2>&1"), collapse = " ")
  if (!is.null(workdir)) line <- paste("cd /d", q(workdir), "&&", line)
  if (.Platform$OS.type == "windows") {
    system2("cmd", c("/c", q(line)), stdout = "", stderr = "")
  } else {
    system(line)
  }
}
log_tail <- function(log, n = 15) {
  if (!file.exists(log)) return(character())
  x <- readLines(log, warn = FALSE)
  utils::tail(x[nzchar(trimws(x))], n)
}

# ---- run lock: two runs at once would fight over the same files ---------------------------------------------------
LOCK <- file.path(MONITORING_DIR, "runs_log", "RUNNING.lock")
if (file.exists(LOCK) && difftime(Sys.time(), file.mtime(LOCK), units = "hours") < 3) {
  say("STOPPED: another run started at ", format(file.mtime(LOCK), "%Y-%m-%d %H:%M"), " and is still marked as running ",
      "(", LOCK, "). If no other run is going, delete that file and start again.")
  quit(status = 10, save = "no")
}
writeLines(c(RUN_ID, Sys.getenv("USERNAME"), Sys.info()[["nodename"]]), LOCK)
# Windows command-line quoting (double quotes) - shQuote()'s default single quotes mean nothing to Windows, and this
# workspace's path has spaces in it
qq <- function(x) if (.Platform$OS.type == "windows") shQuote(x, type = "cmd") else shQuote(x)

main <- function() {
  say("=== MSNA N-WEC 2026 - refresh and deploy",
      if (PREFLIGHT_ONLY) " (PRE-FLIGHT ONLY - checks this computer is ready for a real run; runs nothing else)" else
        if (DRY_RUN) " (DRY RUN - nothing will be published)" else "",
      " - ", format(STARTED, "%d %b %Y %H:%M"), " ===")
  say("Workspace: ", WORKSPACE_DIR)
  say("Run folder: ", RUN_DIR)

  # ======================= PHASE 0 - PRE-FLIGHT =======================
  say("\n--- Phase 0: pre-flight checks ---")
  checks <- list()
  chk <- function(name, ok, detail, severity = "FAIL") {
    status <- if (isTRUE(ok)) "OK" else severity
    checks[[length(checks) + 1]] <<- list(check = name, status = status, detail = detail)
    say(sprintf("  [%-4s] %s - %s", status, name, detail))
  }
  setwd(WORKSPACE_DIR)
  chk("Workspace", dir.exists("1_sampling") && dir.exists("2_monitoring"),
      if (dir.exists("1_sampling")) "1_sampling/ and 2_monitoring/ found" else "1_sampling/ is missing next to 2_monitoring/")
  chk("Validity suite", file.exists(file.path(VALIDITY_DIR, "run_all_checks.R")),
      if (file.exists(file.path(VALIDITY_DIR, "run_all_checks.R"))) "validity_checks/run_all_checks.R found" else
        "validity_checks/run_all_checks.R not found - phase 3 will be skipped", severity = "WARN")
  setwd(MONITORING_DIR)

  lock_r <- tryCatch(jsonlite::fromJSON("renv.lock")$R$Version, error = function(e) NA_character_)
  r_ok <- !is.na(lock_r) && identical(sub("\\.\\d+$", "", lock_r), sub("\\.\\d+$", "", paste(R.version$major, R.version$minor, sep = ".")))
  chk("R version", r_ok, sprintf("running R %s.%s; the project's packages are locked for R %s", R.version$major,
                                 R.version$minor, lock_r), severity = "WARN")
  renv_on <- nzchar(Sys.getenv("RENV_PROJECT"))
  chk("Project package library (renv)", renv_on,
      if (renv_on) paste("active:", .libPaths()[1]) else "not active - start R inside 2_monitoring/ so .Rprofile activates renv")
  missing <- REQUIRED_PACKAGES[!vapply(REQUIRED_PACKAGES, function(p) requireNamespace(p, quietly = TRUE), logical(1))]
  chk("R packages", length(missing) == 0,
      if (length(missing) == 0) sprintf("all %d needed packages installed", length(REQUIRED_PACKAGES)) else
        paste0("missing: ", paste(missing, collapse = ", "), " - open R in 2_monitoring/ and run renv::restore() once"))

  acct <- tryCatch(rsconnect::accounts(), error = function(e) NULL)
  has_acct <- !is.null(acct) && SHINYAPPS_ACCOUNT %in% acct$name
  chk("shinyapps.io account", has_acct,
      if (has_acct) paste0("'", SHINYAPPS_ACCOUNT, "' is set up on this computer") else
        paste0("'", SHINYAPPS_ACCOUNT, "' is not set up for this Windows user - run the one-time rsconnect::setAccountInfo() step in DO_HANDOVER_RUNBOOK.md"),
      severity = if (DRY_RUN) "WARN" else "FAIL")

  exports <- list.files(EXPORT_DIR, pattern = EXPORT_PATTERN)
  override <- Sys.getenv("MSNA_ANON_EXPORT")  # one-time path override (prep_real_submissions.R); reported, never silent
  if (nzchar(override)) {
    ok_o <- file.exists(override) && grepl(EXPORT_PATTERN, basename(override)) && isTRUE(file.info(override)$size > 10e6)
    chk("Export OVERRIDE (MSNA_ANON_EXPORT)", ok_o, if (ok_o) sprintf("this run uses %s (%.0f MB) instead of the newest export in %s",
        override, file.info(override)$size / 1e6, EXPORT_DIR) else paste0("'", override, "' is missing, misnamed or too small"))
    if (ok_o) { report$phase0$export <<- paste(override, "(OVERRIDE)"); exports <- character() }
  }
  if (nzchar(override)) {
    # override checked above; the newest-export checks below don't apply
  } else if (length(exports) == 0) {
    chk("Newest anonymised export", FALSE, paste0("no NGA2605_MSNA_anonymised_<date>.xlsx in ", EXPORT_DIR))
  } else {
    dates <- as.Date(sub(EXPORT_PATTERN, "\\1", exports))
    newest <- exports[which.max(dates)]
    info <- file.info(file.path(EXPORT_DIR, newest))
    age <- as.numeric(Sys.Date() - max(dates))
    ok_file <- isTRUE(info$size > 10e6) && file.access(file.path(EXPORT_DIR, newest), 4) == 0
    chk("Newest anonymised export", ok_file, sprintf("%s (%.0f MB)%s", newest, info$size / 1e6,
                                                     if (ok_file) "" else " - too small or unreadable: is it still syncing?"))
    chk("Export freshness", age <= EXPORT_STALE_DAYS, sprintf("newest export is %d day(s) old", as.integer(age)), severity = "WARN")
    report$phase0$export <<- newest
  }

  # the KoBo audit logs: the duration check (cleaning/real/audit_duration.R) cannot run without them (4 Oct: missing)
  audit_zip <- "cleaning/MSNA_Data_Cleaning/audit/audit.zip"
  audit_fb <- Sys.getenv("MSNA_AUDIT_FALLBACK_CACHE")  # one-time fallback (cleaning/real/audit_duration.R); reported, never silent
  if (!file.exists(audit_zip) && nzchar(audit_fb)) {
    chk("KoBo audit logs - FALLBACK (MSNA_AUDIT_FALLBACK_CACHE)", file.exists(audit_fb),
        if (file.exists(audit_fb)) paste(audit_zip, "is missing; durations for interviews our own cache lacks come from", audit_fb,
                                         "(used only if it matches our cache exactly)") else paste0("'", audit_fb, "' does not exist"))
  } else {
    chk("KoBo audit logs (audit.zip)", file.exists(audit_zip) && isTRUE(file.info(audit_zip)$size > 1e6),
        if (file.exists(audit_zip)) sprintf("%s (%.0f MB)", audit_zip, file.info(audit_zip)$size / 1e6) else
          paste(audit_zip, "is missing - the interview-duration check needs it. Put the latest audit.zip from the cleaning pipeline back there."))
  }

  # OneDrive conflict copies (1_sampling/scripts/shared/onedrive_conflict_guard.R's rule): "<name>-<COMPUTERNAME>.<ext>"
  # next to a file this run reads. The un-suffixed file is not necessarily the right one, so this stops, it never picks.
  guard_dirs <- c("data", "input_data/sampling_frame", "input_data/accessibility", "input_data/partner_coverage", "config",
                  "reports/partner_data_recovery/scripts", "cleaning/real", EXPORT_DIR)
  conflicts <- unlist(lapply(guard_dirs[dir.exists(guard_dirs)], function(d) {
    present <- list.files(d)
    base <- present[!grepl("-[A-Za-z0-9-]{1,20}\\.[^.]+$", present) | present %in% exports]
    hits <- unlist(lapply(base, function(f) {
      stem <- tools::file_path_sans_ext(f)
      ext <- tools::file_ext(f)
      cand <- present[startsWith(present, paste0(stem, "-")) & tools::file_ext(present) == ext]
      cand[grepl("^[A-Za-z0-9-]{1,20}$", substring(tools::file_path_sans_ext(cand), nchar(stem) + 2L))]
    }))
    if (length(hits)) file.path(d, unique(hits)) else character()
  }))
  chk("OneDrive conflict copies", length(conflicts) == 0,
      if (length(conflicts) == 0) "none next to the files this run reads" else
        paste0(length(conflicts), " found: ", paste(conflicts, collapse = "; "),
               " - compare each with the file of the same name without the '-<COMPUTERNAME>' part, keep the right one, move the other into an _archive folder"))

  py <- resolve_python()
  py_ok <- !is.na(py$path) && py$openpyxl
  env_py <- Sys.getenv("MSNA_PYTHON")
  chk("Python (phase 2)", py_ok,
      if (py_ok) py$path else if (!is.na(py$path)) paste0(py$path, " has no openpyxl - run once: \"", py$path, "\" -m pip install openpyxl") else
        if (nzchar(env_py)) paste0("MSNA_PYTHON is set to '", env_py, "', which does not start Python - correct it or remove it") else
          "no Python 3 found - install it from python.org, then run once: py -3 -m pip install openpyxl",
      severity = "WARN")
  report$phase0$python <<- if (py_ok) py$path else NA_character_
  if (py_ok) Sys.setenv(MSNA_PYTHON = py$path)
  p2 <- file.path(WORKSPACE_DIR, PHASE2_SCRIPT)
  chk("Phase 2 script", file.exists(p2), if (file.exists(p2)) PHASE2_SCRIPT else paste(PHASE2_SCRIPT, "not found - phase 2 cannot run"),
      severity = "WARN")
  # Phase 2's own environment check (reads only; it logs to its run folder in 1_sampling/output/daily_update_runs/):
  # R packages it needs, its input files, its baseline, the frame not changed outside it, the partner folder synced.
  # A problem here is a warning - the dashboard can still be refreshed - but it is found now, not after phase 1.
  if (!SKIP_PHASE2 && py_ok && file.exists(p2)) {
    say("  ... asking the frame/partner update (phase 2) whether it can run here - about a minute")
    t0 <- Sys.time()
    log0 <- file.path(RUN_DIR, "phase0_phase2_check_env.log")
    st0 <- run_to_log(py$path, c(qq(p2), "--check-env"), log0)
    s0 <- read_phase2_summary(t0)
    chk("Phase 2 readiness", identical(as.integer(st0), 0L),
        if (identical(as.integer(st0), 0L)) "the frame/partner update can run on this computer" else
          paste0(s0$message %||% paste0("exit code ", st0, " - see ", basename(log0)),
                 " - the dashboard can still be refreshed, but phase 2 will probably stop at the same point"),
        severity = "WARN")
  }
  zips <- nzchar(Sys.which("unzip")) && nzchar(Sys.which("zip"))
  chk("zip/unzip (fallback only)", zips, if (zips) "found" else
    "not on PATH - only needed if an export is malformed (install Rtools to get them)", severity = "WARN")

  report$phase0$checks <<- checks
  if (any(vapply(checks, function(x) x$status == "FAIL", logical(1)))) {
    report$phase0$status <<- "FAILED"
    say("\nPre-flight FAILED - nothing was run, nothing changed. Fix the item(s) marked FAIL above and start again.")
    return(10L)
  }
  report$phase0$status <<- "OK"
  if (PREFLIGHT_ONLY) {
    say("\nPre-flight OK - this computer is ready (--preflight-only: nothing else was run).")
    report$phase1$status <<- report$phase2$status <<- report$phase3$status <<- "not run (--preflight-only)"
    return(0L)
  }

  # ======================= PHASE 1 - DATA REFRESH + DASHBOARD DEPLOY =======================
  say("\n--- Phase 1: data refresh + dashboard ", if (DRY_RUN) "build (dry run - no upload)" else "deploy",
      " - usually 15-25 minutes; progress shows below and in phase1_refresh_deploy.log ---")
  t1 <- Sys.time()
  log1 <- file.path(RUN_DIR, "phase1_refresh_deploy.log")
  Sys.setenv(MSNA_DEPLOY_DRY_RUN = if (DRY_RUN) "1" else "")
  setwd(MONITORING_DIR)
  st1 <- system2(RSCRIPT, c(qq("scripts/shared/run_logged.R"), qq(log1), qq("deploy_dashboard.R")))
  Sys.unsetenv("MSNA_DEPLOY_DRY_RUN")
  report$phase1$minutes <<- mins(t1)
  report$phase1$log <<- basename(log1)
  if (!identical(as.integer(st1), 0L)) {
    report$phase1$status <<- "FAILED"
    report$phase1$tail <<- log_tail(log1)
    say("\nPhase 1 FAILED after ", mins(t1), " - nothing was uploaded, the dashboard that was live is still live. ",
        "The end of the log:\n    ", paste(log_tail(log1), collapse = "\n    "))
    return(20L)
  }
  l1 <- readLines(log1, warn = FALSE)
  bundle <- regmatches(l1, regexpr("Uploaded bundle with id [0-9]+", l1))
  report$phase1$bundle <<- if (length(bundle)) sub("^.* ", "", bundle[length(bundle)]) else NA_character_
  report$phase1$data <<- summarise_data()
  if (DRY_RUN) {
    report$phase1$status <<- "OK (dry run - built and checked, not uploaded)"
  } else {
    live <- tryCatch(attr(curlGetHeaders(APP_URL), "status"), error = function(e) NA_integer_)
    report$phase1$live_http <<- live
    report$phase1$status <<- if (identical(as.integer(live), 200L)) "OK - deployed and answering" else
      paste0("DEPLOYED, BUT the live app did not answer normally (HTTP ", live, ") - open ", APP_URL, " and check")
  }
  say("Phase 1 done in ", mins(t1), ": ", report$phase1$status,
      if (!is.na(report$phase1$bundle)) paste0(" (bundle ", report$phase1$bundle, ")") else "")

  # ======================= PHASE 2 - FRAME + PARTNER UPDATE =======================
  if (SKIP_PHASE2) {
    report$phase2$status <<- "skipped (--skip-phase2)"
  } else if (is.na(report$phase0$python %||% NA) || !file.exists(file.path(WORKSPACE_DIR, PHASE2_SCRIPT))) {
    report$phase2$status <<- "NOT RUN - Python (with openpyxl) or the phase 2 script is missing on this computer; see pre-flight"
  } else {
    say("\n--- Phase 2: sampling frame + partner package update", if (DRY_RUN) " (dry run)" else "", " - usually 10-15 minutes ---")
    t2 <- Sys.time()
    log2 <- file.path(RUN_DIR, "phase2_frame_partner_update.log")
    st2 <- run_to_log(report$phase0$python, c(qq(file.path(WORKSPACE_DIR, PHASE2_SCRIPT)), if (DRY_RUN) "--dry-run"), log2)
    report$phase2$minutes <<- mins(t2)
    report$phase2$log <<- basename(log2)
    report$phase2$exit <<- st2
    report$phase2$status <<- switch(as.character(st2),
      "0" = if (DRY_RUN) "OK (dry run - nothing written)" else "OK - frames and partner packages updated",
      "1" = "BLOCKED by one of its checks - partners keep their last good files",
      "2" = "ERROR - it could not run; partners keep their last good files",
      paste0("ERROR - unexpected exit code ", st2))
    report$phase2$summary <<- read_phase2_summary(t2)
    if (!identical(as.integer(st2), 0L)) report$phase2$tail <<- log_tail(log2)
    say("Phase 2 done in ", mins(t2), ": ", report$phase2$status,
        if (!is.null(report$phase2$summary$message)) paste0("\n    ", report$phase2$summary$message) else "")
  }

  # ======================= PHASE 3 - VALIDITY SUITE =======================
  if (SKIP_CHECKS) {
    report$phase3$status <<- "skipped (--skip-checks)"
  } else if (!file.exists(file.path(WORKSPACE_DIR, VALIDITY_DIR, "run_all_checks.R"))) {
    report$phase3$status <<- "NOT RUN - validity_checks/run_all_checks.R not found"
  } else {
    say("\n--- Phase 3: validity suite ---")
    t3 <- Sys.time()
    log3 <- file.path(RUN_DIR, "phase3_validity_suite.log")
    csv3 <- file.path(RUN_DIR, "validity_results.csv")
    st3 <- run_to_log(RSCRIPT, c("run_all_checks.R", "--out", paste0('"', csv3, '"')), log3,
                      workdir = file.path(WORKSPACE_DIR, VALIDITY_DIR))
    l3 <- if (file.exists(log3)) readLines(log3, warn = FALSE) else character()
    summary_line <- utils::tail(grep("SUMMARY:", l3, value = TRUE), 1)
    report$phase3$minutes <<- mins(t3)
    report$phase3$log <<- basename(log3)
    report$phase3$summary <<- if (length(summary_line)) trimws(summary_line) else NA_character_
    report$phase3$status <<- switch(as.character(st3), "0" = "OK - no FAIL", "1" = "FAIL - at least one check failed",
                                    "2" = "ERROR - the suite could not run", paste0("ERROR - exit code ", st3))
    if (file.exists(csv3)) {
      res <- tryCatch(read.csv(csv3, stringsAsFactors = FALSE), error = function(e) NULL)
      if (!is.null(res) && "status" %in% names(res)) report$phase3$failed <<- res[res$status == "FAIL", intersect(c("module", "check", "detail"), names(res)), drop = FALSE]
    }
    say("Phase 3 done in ", mins(t3), ": ", report$phase3$status, if (length(summary_line)) paste0(" (", trimws(summary_line), ")") else "")
  }

  # "skipped" = asked for (--skip-phase2/--skip-checks); "NOT RUN" = could not run here, which is a problem to report
  code <- 0L
  if (!grepl("^(OK|skipped)", report$phase2$status)) code <- 30L
  if (code == 0L && grepl("^(FAIL|ERROR|NOT RUN)", report$phase3$status)) code <- 40L
  if (!DRY_RUN && grepl("^DEPLOYED, BUT", report$phase1$status)) code <- max(code, 20L)
  code
}

# Python for phase 2. MSNA_PYTHON if set (a python.exe, or a command such as "py -3") is used as given - an explicit
# setting is never second-guessed. Otherwise the first of py -3 / python / python3 that has openpyxl, the one module
# phase 2 needs beyond the standard library (several Pythons on one laptop is common, and not all have it).
resolve_python <- function() {
  ask <- function(cmd, code) {
    out <- tryCatch(suppressWarnings(system2(cmd[1], c(cmd[-1], "-c", paste0('"', code, '"')), stdout = TRUE, stderr = FALSE)),
                    error = function(e) character())
    trimws(out[nzchar(trimws(out))])
  }
  env <- trimws(Sys.getenv("MSNA_PYTHON"))
  cands <- if (nzchar(env)) list(if (file.exists(env)) env else strsplit(env, "\\s+")[[1]]) else list(c("py", "-3"), "python", "python3")
  first <- list(path = NA_character_, openpyxl = FALSE)
  for (cmd in cands) {
    exe <- utils::tail(ask(cmd, "import sys; print(sys.executable)"), 1)
    if (!length(exe) || !file.exists(exe)) next
    exe <- normalizePath(exe, winslash = "/")
    found <- list(path = exe, openpyxl = "OK" %in% ask(exe, "import openpyxl; print('OK')"))
    if (found$openpyxl) return(found)
    if (is.na(first$path)) first <- found
  }
  first
}

# Phase 2's LATEST_SUMMARY.json - only if it was written by the call that started at `since`. If that call died before
# writing its summary, the file on disk is an older run's, which must never be reported as this run's result.
read_phase2_summary <- function(since) {
  f <- file.path(WORKSPACE_DIR, PHASE2_SUMMARY)
  if (!file.exists(f) || file.mtime(f) < since - 2) return(NULL)
  tryCatch(jsonlite::fromJSON(f, simplifyVector = TRUE), error = function(e) NULL)
}

summarise_data <- function() {
  subs <- tryCatch(read.csv(file.path(MONITORING_DIR, "data/real_submissions.csv"), stringsAsFactors = FALSE,
                            colClasses = "character"), error = function(e) NULL)
  ov <- tryCatch(read.csv(file.path(MONITORING_DIR, "data/CONFIRMED_DELETIONS_OVERLAY.csv"), stringsAsFactors = FALSE,
                          colClasses = "character"), error = function(e) NULL)
  if (is.null(subs)) return(NULL)
  settled <- if (!is.null(ov)) ov$uuid[ov$status %in% c("confirmed", "contested")] else character()
  done <- subs$interview_outcome == "completed"
  ach <- done & !(subs$matched_survey_id %in% c("", "NA")) & !(subs$submission_uuid %in% settled)
  d <- suppressWarnings(as.Date(subs$submission_date))
  list(submissions = nrow(subs), completed = sum(done), achieved = sum(ach), confirmed_deletions = length(settled),
       latest_interview = if (any(!is.na(d))) format(max(d, na.rm = TRUE)) else NA_character_)
}

write_report <- function(code) {
  L <- character()
  add <- function(...) L <<- c(L, paste0(...))
  verdict <- c("0" = "EVERYTHING OK", "10" = "STOPPED AT PRE-FLIGHT - nothing ran, nothing changed",
               "20" = "DASHBOARD STEP FAILED - the dashboard that was live is still live",
               "30" = if (DRY_RUN) "THE FRAME/PARTNER UPDATE WOULD NOT COMPLETE - fix this before the real run" else
                 "DASHBOARD UPDATED - the frame/partner update did not complete (partners keep their last good files)",
               "40" = "ALL STEPS RAN - the validity suite found a FAIL to look at (or could not run)",
               "50" = "THE LAUNCHER ITSELF HIT AN ERROR")[[as.character(code)]]
  add("# MSNA N-WEC 2026 - refresh and deploy run", if (nzchar(MODE_LABEL)) paste0(" (", MODE_LABEL, ")") else "")
  add("")
  add("- **Started:** ", format(STARTED, "%d %b %Y %H:%M"), " | **took:** ", mins(STARTED), " | **by:** ", Sys.getenv("USERNAME"),
      " on ", Sys.info()[["nodename"]])
  add("- **Result:** ", verdict, " (exit code ", code, ")")
  if (PREFLIGHT_ONLY) add("- **Pre-flight only:** this computer was checked for a real run; no data was refreshed and nothing was published.")
  if (DRY_RUN && !PREFLIGHT_ONLY) add("- **Dry run:** the data was refreshed and checked on this computer, but nothing was published: the live dashboard, frames and partner folders are unchanged.")
  add("")
  add("## Phase 0 - pre-flight: ", report$phase0$status %||% "not run")
  for (x in report$phase0$checks) add("- ", c(OK = "OK  ", WARN = "WARN", FAIL = "FAIL")[[x$status]], " - **", x$check, "**: ", x$detail)
  add("")
  add("## Phase 1 - data refresh + dashboard: ", report$phase1$status)
  if (!is.null(report$phase1$data)) {
    d <- report$phase1$data
    add("- The dashboard data now holds ", format(d$submissions, big.mark = ","), " submissions (", format(d$completed, big.mark = ","),
        " completed); **national Achieved = ", format(d$achieved, big.mark = ","), "** after ", format(d$confirmed_deletions, big.mark = ","),
        " confirmed deletions; latest interview date ", d$latest_interview, ".")
  }
  if (!is.null(report$phase0$export)) add("- Export used: ", report$phase0$export)
  if (!is.na(report$phase1$bundle %||% NA)) add("- Deployed bundle: ", report$phase1$bundle, " - ", APP_URL)
  if (!is.null(report$phase1$minutes)) add("- Took ", report$phase1$minutes, "; full log: ", report$phase1$log)
  if (length(report$phase1$tail)) { add("- End of the log:"); add("```"); L <- c(L, report$phase1$tail); add("```") }
  add("")
  add("## Phase 2 - frame + partner update: ", report$phase2$status)
  s <- report$phase2$summary
  if (!is.null(s)) {
    if (length(s$message)) add("- ", s$message)
    fr <- s$frame
    if (length(fr$working_rows_before)) {
      add("- Sampling frame (WORKING): ", fr$working_rows_before, " -> ", fr$working_rows_after, " rows (", fr$removed, " removed, ",
          fr$added, " added", if (isTRUE(fr$unexplained > 0)) paste0(", ", fr$unexplained, " NOT explained by an achieved-status change") else "",
          ")", if (isTRUE(fr$restored)) " - the frame was put back as it was before the run" else "")
    }
    pk <- s$packages
    if (length(pk$staged_files)) {
      add("- Partner packages: ", pk$staged_files, " files built - ", pk$changed, " changed, ", pk$new, " new, ", pk$identical,
          " unchanged, ", pk$leftover_to_archive, " no longer produced", if (isTRUE(pk$published)) " - published" else " - not published")
    }
    if (length(s$gate$counts)) add("- Validity gate on the new packages: ", paste(unlist(s$gate$counts), names(s$gate$counts), collapse = ", "))
    for (k in c("failed_checks", "warnings")) {
      x <- s[[k]]
      if (is.data.frame(x) && nrow(x) && "check" %in% names(x)) {
        add("- ", if (k == "failed_checks") "What stopped it:" else "Warnings:")
        for (i in seq_len(nrow(x))) add("  - ", x$check[i], if ("detail" %in% names(x) && nzchar(x$detail[i] %||% "")) paste0(" - ", x$detail[i]) else "")
      }
    }
    if (length(s$actions)) { add("- What it did:"); for (a in s$actions) add("  - ", a) }
    add("- Its own logs and change lists: ", s$run_dir %||% "1_sampling/output/daily_update_runs/", " (summary: ", PHASE2_SUMMARY, ")")
  }
  if (!is.null(report$phase2$minutes)) add("- Took ", report$phase2$minutes, "; full log: ", report$phase2$log)
  if (length(report$phase2$tail)) { add("- End of the log:"); add("```"); L <- c(L, report$phase2$tail); add("```") }
  add("")
  add("## Phase 3 - validity suite: ", report$phase3$status)
  if (!is.na(report$phase3$summary %||% NA)) add("- ", report$phase3$summary)
  if (!is.null(report$phase3$failed) && nrow(report$phase3$failed)) {
    add("- Checks that FAILED:")
    for (i in seq_len(nrow(report$phase3$failed))) add("  - ", paste(report$phase3$failed[i, ], collapse = " | "))
  }
  if (!is.null(report$phase3$minutes)) add("- Took ", report$phase3$minutes, "; full log: ", report$phase3$log, "; results table: validity_results.csv")
  add("")
  add("## What to do next")
  add(switch(as.character(code),
    "0" = if (PREFLIGHT_ONLY) "- This computer is ready. Run run_refresh_and_deploy.bat (or run_refresh_and_deploy_DRYRUN.bat first, to try it without publishing)." else
      if (DRY_RUN) "- Nothing - the dry run passed. Run run_refresh_and_deploy.bat to publish for real." else "- Nothing - all done.",
    "10" = "- Fix the item(s) marked FAIL under Phase 0 (DO_HANDOVER_RUNBOOK.md has the fixes), then run again.",
    "20" = "- Read the end of the phase 1 log above. The live dashboard was not changed. Fix the cause and run again; DO_HANDOVER_RUNBOOK.md lists the common ones.",
    "30" = if (DRY_RUN) "- Nothing was published. Send this report and the phase 2 log to the sampling team before the real run." else
      "- The dashboard is updated. Send the phase 2 log and LATEST_SUMMARY.json to the sampling team; partner files are unchanged until it is resolved.",
    "40" = if (DRY_RUN) "- Nothing was published. Look at the failed checks above and send this report to the MSNA team before the real run." else
      "- Everything was published. Look at the failed checks above and send this report to the MSNA team.",
    "50" = "- Send this report and launcher.log to the MSNA team."))
  add("")
  add("Logs in this folder: launcher.log", if (!is.null(report$phase1$log)) paste0(", ", report$phase1$log) else "",
      if (!is.null(report$phase2$log)) paste0(", ", report$phase2$log) else "",
      if (!is.null(report$phase3$log)) paste0(", ", report$phase3$log) else "")
  writeLines(L, file.path(RUN_DIR, "RUN_REPORT.md"))
  jsonlite::write_json(list(run = RUN_ID, dry_run = DRY_RUN, exit_code = code, report = report), file.path(RUN_DIR, "run_summary.json"),
                       auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", force = TRUE)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

code <- tryCatch(main(), error = function(e) {
  say("\nLAUNCHER ERROR: ", conditionMessage(e))
  50L
})
setwd(MONITORING_DIR)
write_report(code)
say("\n=== ", c("0" = "EVERYTHING OK", "10" = "STOPPED AT PRE-FLIGHT", "20" = "DASHBOARD STEP FAILED",
               "30" = if (DRY_RUN) "PHASE 2 WOULD NOT COMPLETE" else "DASHBOARD UPDATED, PHASE 2 DID NOT COMPLETE",
               "40" = "VALIDITY SUITE FOUND A FAIL", "50" = "LAUNCHER ERROR")[[as.character(code)]],
    " - report: ", file.path(RUN_DIR, "RUN_REPORT.md"), " ===")
unlink(LOCK)
quit(status = code, save = "no")
