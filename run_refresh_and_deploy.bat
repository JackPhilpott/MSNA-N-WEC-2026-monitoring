@echo off
rem ==========================================================================================
rem  MSNA N-WEC 2026 - refresh the data, deploy the dashboard, update frames + partner packages.
rem  Double-click to run. The window stays open at the end so you can read the result; the full
rem  report is saved in 2_monitoring\runs_log\<date_time>\RUN_REPORT.md.
rem  To try everything WITHOUT publishing, double-click run_refresh_and_deploy_DRYRUN.bat instead.
rem ==========================================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

rem ---- find Rscript.exe: MSNA_RSCRIPT if set, else on the PATH, else the newest standard R install ----
set "RSCRIPT="
if defined MSNA_RSCRIPT if exist "%MSNA_RSCRIPT%" set "RSCRIPT=%MSNA_RSCRIPT%"
if not defined RSCRIPT for /f "delims=" %%R in ('where Rscript.exe 2^>nul') do if not defined RSCRIPT set "RSCRIPT=%%R"
if not defined RSCRIPT for /d %%D in ("%LOCALAPPDATA%\Programs\R\R-*" "%ProgramFiles%\R\R-*") do if exist "%%~D\bin\Rscript.exe" set "RSCRIPT=%%~D\bin\Rscript.exe"
if not defined RSCRIPT (
  echo.
  echo Could not find R on this computer. Install R, or set MSNA_RSCRIPT to the full path of Rscript.exe,
  echo then run this again. See DO_HANDOVER_RUNBOOK.md, "One-time setup".
  echo.
  pause
  exit /b 10
)
echo Using R: !RSCRIPT!
echo.

"!RSCRIPT!" run_refresh_and_deploy.R %*
set "RC=!ERRORLEVEL!"
set "DRY="
echo %* | find /i "--dry-run" >nul && set "DRY=1"

echo.
if "!RC!"=="0"  echo FINISHED OK.
if "!RC!"=="10" echo STOPPED AT THE PRE-FLIGHT CHECKS - nothing ran, nothing changed. See the items marked FAIL above.
if "!RC!"=="20" echo THE DASHBOARD STEP FAILED - the dashboard that was live is still live. See the run report.
if "!RC!"=="30" if defined DRY echo DRY RUN: THE FRAME/PARTNER UPDATE WOULD NOT COMPLETE - see the run report before doing the real run.
if "!RC!"=="30" if not defined DRY echo THE DASHBOARD WAS UPDATED, BUT THE FRAME/PARTNER UPDATE DID NOT COMPLETE - partners keep their last good files.
if "!RC!"=="40" echo EVERYTHING RAN, BUT THE VALIDITY SUITE FOUND A FAIL - see the run report.
if "!RC!"=="50" echo THE LAUNCHER HIT AN ERROR - see the run report.
echo The run report is in the newest folder under 2_monitoring\runs_log\
echo.
pause
exit /b !RC!
