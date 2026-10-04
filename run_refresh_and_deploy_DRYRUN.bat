@echo off
rem ==========================================================================================
rem  MSNA N-WEC 2026 - DRY RUN: everything run_refresh_and_deploy.bat does, EXCEPT publishing.
rem  The data is refreshed and fully checked on this computer and the dashboard bundle is built,
rem  but nothing is uploaded to shinyapps.io and the frame/partner update writes nothing.
rem  Safe to run any time, e.g. to test a new laptop or a new export before the real run.
rem ==========================================================================================
call "%~dp0run_refresh_and_deploy.bat" --dry-run
