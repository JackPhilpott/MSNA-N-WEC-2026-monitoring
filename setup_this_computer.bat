@echo off
rem ==========================================================================================
rem  MSNA N-WEC 2026 - ONE-TIME SETUP of a computer for run_refresh_and_deploy.bat.
rem  First install R 4.6 (https://cran.r-project.org/bin/windows/base/) and Python 3
rem  (https://www.python.org/downloads/ - tick "Add python.exe to PATH"). Then double-click this
rem  once. It needs internet and takes 10-30 minutes the first time. Safe to run again: it only
rem  adds what is missing.
rem    1. finds R
rem    2. installs the dashboard's R packages at the exact versions in renv.lock. On a new
rem       computer they go in a library on THAT computer (%LOCALAPPDATA%\R\renv-library), never
rem       in the shared OneDrive folder, where one person's packages would clash with another's.
rem    3. installs openpyxl for Python (used by the frame/partner update)
rem    4. runs the launcher's pre-flight check and lists anything still missing
rem  The shinyapps.io token is a separate manual step: DO_HANDOVER_RUNBOOK.md, section 1.
rem ==========================================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

rem ---- 1. R: MSNA_RSCRIPT if set, else on the PATH, else the newest standard R install ----
set "RSCRIPT="
if defined MSNA_RSCRIPT if exist "%MSNA_RSCRIPT%" set "RSCRIPT=%MSNA_RSCRIPT%"
if not defined RSCRIPT for /f "delims=" %%R in ('where Rscript.exe 2^>nul') do if not defined RSCRIPT set "RSCRIPT=%%R"
if not defined RSCRIPT for /d %%D in ("%LOCALAPPDATA%\Programs\R\R-*" "%ProgramFiles%\R\R-*") do if exist "%%~D\bin\Rscript.exe" set "RSCRIPT=%%~D\bin\Rscript.exe"
if not defined RSCRIPT (
  echo R is not installed. Install R 4.6 from https://cran.r-project.org/bin/windows/base/ and run this again.
  pause
  exit /b 1
)
echo [1/4] R found: !RSCRIPT!

rem ---- 2. R packages. A computer whose shared project library already holds every locked package (the computer
rem      that built it) is left alone. Any other computer gets its own library, set once for its Windows user. The
rem      check reads files only (R --vanilla, no renv), so nothing is written into the shared folder. ----
echo [2/4] Checking the dashboard's R packages ...
if defined RENV_PATHS_LIBRARY_ROOT goto :restore
"!RSCRIPT!" --vanilla -e "pk <- sub('.*Package.: .([A-Za-z0-9.]+).*', '\\1', grep('Package.: ', readLines('renv.lock'), value = TRUE)); lib <- file.path('renv/library/windows', paste0('R-', R.version$major, '.', strsplit(R.version$minor, '.', fixed = TRUE)[[1]][1]), R.version$platform); hi <- rownames(installed.packages(.Library, priority = 'high')); miss <- pk[file.exists(file.path(lib, pk, 'DESCRIPTION')) == FALSE & is.element(pk, hi) == FALSE]; cat('      ', length(pk) - length(miss), 'of', length(pk), 'locked packages found in the shared project library or among R own packages\n'); quit(status = as.integer(length(miss) > 0))"
if !ERRORLEVEL! EQU 0 (
  echo       Nothing to install - this computer already uses the shared project library.
  goto :python
)
set "RENV_PATHS_LIBRARY_ROOT=%LOCALAPPDATA%\R\renv-library"
setx RENV_PATHS_LIBRARY_ROOT "%LOCALAPPDATA%\R\renv-library" >nul
echo       The packages will live in !RENV_PATHS_LIBRARY_ROOT! - on this computer, for this Windows user only.
:restore
echo       Installing the exact versions in renv.lock where missing - needs internet, 10-30 minutes the first time ...
"!RSCRIPT!" -e "options(renv.consent = TRUE); renv::restore(prompt = FALSE)"
set "RESTORE_RC=!ERRORLEVEL!"
rem cleaningtools is the one package that comes from GitHub, not CRAN - checked by name so its failure is named
"!RSCRIPT!" -e "quit(status = as.integer(!requireNamespace('cleaningtools', quietly = TRUE)))"
set "CT_RC=!ERRORLEVEL!"
if not "!CT_RC!"=="0" (
  echo.
  echo R PACKAGE INSTALL FAILED: cleaningtools ^(from github.com/impact-initiatives^) is not installed.
  echo It is the only package that downloads from GitHub instead of CRAN. Usually one of:
  echo   - this network blocks github.com: try another network ^(e.g. a phone hotspot^) and run this again;
  echo   - GitHub's limit on anonymous downloads was hit: wait an hour and run this again.
  echo If it still fails, send the messages above to the MSNA team.
  pause
  exit /b 1
)
if not "!RESTORE_RC!"=="0" (
  echo.
  echo R PACKAGE INSTALL FAILED - see the messages above. Check the internet connection and run this again.
  pause
  exit /b 1
)

:python

rem ---- 3. Python + openpyxl (MSNA_PYTHON if set, else py -3, else python) ----
echo [3/4] Checking Python for the frame/partner update ...
set "PYEXE="
if defined MSNA_PYTHON if exist "%MSNA_PYTHON%" set "PYEXE=%MSNA_PYTHON%"
if not defined PYEXE for /f "delims=" %%P in ('py -3 -c "import sys; print(sys.executable)" 2^>nul') do set "PYEXE=%%P"
if not defined PYEXE for /f "delims=" %%P in ('python -c "import sys; print(sys.executable)" 2^>nul') do set "PYEXE=%%P"
if not defined PYEXE (
  echo       Python 3 is not installed. Install it from https://www.python.org/downloads/ ^(tick "Add python.exe to PATH"^)
  echo       and run this again. The dashboard can be updated without it, but not the frame and partner folders.
) else (
  "!PYEXE!" -c "import openpyxl" >nul 2>&1
  if !ERRORLEVEL! NEQ 0 (
    if exist "%~dp0..\1_sampling\requirements.txt" (
      "!PYEXE!" -m pip install --user -r "%~dp0..\1_sampling\requirements.txt"
    ) else (
      "!PYEXE!" -m pip install --user openpyxl
    )
  )
  "!PYEXE!" -c "import openpyxl, sys; print('      openpyxl', openpyxl.__version__, 'OK in', sys.executable)"
)

rem ---- 4. the launcher's pre-flight, judged as for a real run ----
echo [4/4] Pre-flight check ...
echo.
"!RSCRIPT!" run_refresh_and_deploy.R --preflight-only
set "RC=!ERRORLEVEL!"
echo.
if "!RC!"=="0" (
  echo SETUP COMPLETE - this computer is ready. Try run_refresh_and_deploy_DRYRUN.bat first, then run_refresh_and_deploy.bat.
) else (
  echo SETUP NOT COMPLETE - fix the items marked FAIL above. If the only FAIL is the shinyapps.io account, do the
  echo one-time token step in DO_HANDOVER_RUNBOOK.md, section 1, then run this again.
)
echo.
pause
exit /b !RC!
