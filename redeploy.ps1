# Full data refresh + dashboard deploy - the same sequence deploy_dashboard.R
# always runs (refresh submissions -> sanity checks -> partner digest ->
# bundle dashboard_app mirrors -> deploy live to shinyapps.io).
#
# Run from a PowerShell prompt:
#   .\redeploy.ps1
# (right-click > "Run with PowerShell" also works; a plain double-click may
# just open it in an editor depending on Windows' file association).

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$RscriptExe = "C:\Users\JackPHILPOTT\AppData\Local\Programs\R\R-4.6.0\bin\Rscript.exe"

Write-Host "Running full refresh + deploy from $PSScriptRoot ..."
& $RscriptExe -e "source('deploy_dashboard.R')"

if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED - exit code $LASTEXITCODE. Check the output above." -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "Done - refreshed, reported, and deployed." -ForegroundColor Green
