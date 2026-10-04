# Full data refresh + dashboard deploy - the same sequence deploy_dashboard.R
# always runs (sync 1_sampling's frame/accessibility mirrors -> rebuild
# accessibility_strata_level.csv via prep_accessibility_layer.R -> refresh
# submissions -> sanity checks -> partner digest -> bundle dashboard_app
# mirrors -> deploy live to shinyapps.io). Updated 2026-09-14 - this list had
# drifted from deploy_dashboard.R's actual steps (missing the mirror syncs
# and the accessibility-layer rebuild entirely).
#
# Run from a PowerShell prompt:
#   .\redeploy.ps1
# (right-click > "Run with PowerShell" also works; a plain double-click may
# just open it in an editor depending on Windows' file association).
#
# 2026-10-04: for the data officer's routine runs, use run_refresh_and_deploy.bat instead - the same deploy plus
# pre-flight checks, the frame/partner update and a run report. This script stays as the bare deploy, and no longer
# hard-codes one person's R install: MSNA_RSCRIPT if set, else Rscript on the PATH, else the newest standard install.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$RscriptExe = $null
if ($env:MSNA_RSCRIPT -and (Test-Path $env:MSNA_RSCRIPT)) { $RscriptExe = $env:MSNA_RSCRIPT }
if (-not $RscriptExe) { $cmd = Get-Command Rscript.exe -ErrorAction SilentlyContinue; if ($cmd) { $RscriptExe = $cmd.Source } }
if (-not $RscriptExe) {
    $installs = foreach ($root in @("$env:LOCALAPPDATA\Programs\R", "$env:ProgramFiles\R")) {
        if (Test-Path $root) { Get-ChildItem $root -Directory -Filter "R-*" | Where-Object { Test-Path (Join-Path $_.FullName "bin\Rscript.exe") } }
    }
    $newest = $installs | Sort-Object { [version]($_.Name -replace '^R-', '') } -Descending | Select-Object -First 1
    if ($newest) { $RscriptExe = Join-Path $newest.FullName "bin\Rscript.exe" }
}
if (-not $RscriptExe) { throw "Rscript.exe not found - install R, or set MSNA_RSCRIPT to its full path." }

Write-Host "Running full refresh + deploy from $PSScriptRoot ..."
& $RscriptExe -e "source('deploy_dashboard.R')"

if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED - exit code $LASTEXITCODE. Check the output above." -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "Done - refreshed, reported, and deployed." -ForegroundColor Green
