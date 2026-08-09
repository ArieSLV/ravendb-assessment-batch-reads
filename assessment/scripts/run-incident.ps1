<#
    Runs the customer's reconciliation pass against a RavenDB server and refreshes
    assessment/EVIDENCE from what the run actually produced.

    A server has to be listening first - see .\assessment\scripts\start-server.ps1.

    The pass stops at the first anomaly, or when its time budget runs out. Exit code 1 means
    it reproduced; exit code 0 means this run produced no anomaly - what that tells you depends
    on whether you have changed any code yet, and the run prints both readings.

    application.log, client-stack-traces.txt and runtime-and-counters.txt are overwritten by
    every run. run-history.txt is appended to, so the variation between runs stays visible.
#>

param(
    [double] $Minutes = 5,
    [int] $Workers = 16
)

$ErrorActionPreference = "Stop"

$assessment = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $assessment
$evidence = Join-Path $assessment "EVIDENCE"
$dotnet = if ($env:RAVEN_DOTNET) { $env:RAVEN_DOTNET } else { "dotnet" }
$serverUrl = if ($env:RECONCILIATION_URL) { $env:RECONCILIATION_URL } else { "http://127.0.0.1:8080" }

$jobProject = Join-Path $root "assessment\reconciliation-job\ReconciliationJob.csproj"

New-Item -ItemType Directory -Force -Path $evidence | Out-Null

# A stale MSBuildSDKsPath pins MSBuild to one specific SDK, and every net10.0 project then fails
# with NETSDK1045. Drop it for this process only - the persistent value is not touched.
$sdkVersion = (& $dotnet --version 2>&1 | Out-String).Trim()
if ($env:MSBuildSDKsPath -and $env:MSBuildSDKsPath -notmatch [regex]::Escape("sdk\$sdkVersion\Sdks")) {
    Write-Output "note: ignoring MSBuildSDKsPath for this run, it pins MSBuild to a different SDK than $sdkVersion"
    Remove-Item Env:MSBuildSDKsPath -ErrorAction SilentlyContinue
}

Write-Output "building the job..."
$buildLog = & $dotnet build $jobProject -c Release -v q --nologo 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    $lines = $buildLog -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    # MSBuild's canonical form is "<file>(<line>,<col>): error <CODE>: <text> [<project>]". Match on
    # that rather than on the bare word, otherwise the NU19xx vulnerability warnings bury the error.
    # One broken thing is usually reported once per project, so collapse on the message alone.
    $errors = $lines |
        Where-Object { $_ -match '(?i):\s*error\s' } |
        ForEach-Object { ($_ -replace '\s*\[[^\]]*proj\]\s*$', '').Trim() } |
        Group-Object |
        ForEach-Object { if ($_.Count -gt 1) { "$($_.Name)`n      (the same error was reported for $($_.Count) projects)" } else { $_.Name } }

    Write-Output ""
    Write-Output "the build did not succeed. what the compiler reported:"
    Write-Output "------------------------------------------------------"
    if ($errors) { $errors | Select-Object -First 40 | ForEach-Object { Write-Output "  $_" } }
    else { $lines | Select-Object -Last 40 | ForEach-Object { Write-Output "  $_" } }
    Write-Output "------------------------------------------------------"
    Write-Output ""
    Write-Output "to see the whole thing, run it yourself:"
    Write-Output "  $dotnet build `"$jobProject`" -c Release"
    exit 1
}

Write-Output "running the pass against $serverUrl, budget $Minutes minute(s), $Workers workers ..."
Write-Output "it stops at the first anomaly, so a run that reproduces early finishes early."
$raw = & $dotnet run --project $jobProject -c Release --no-build -- --url $serverUrl --minutes $Minutes --workers $Workers 2>&1 | Out-String
$jobExit = $LASTEXITCODE

$lines = $raw -split "`r?`n" | ForEach-Object { $_.TrimEnd() }
$timeline = $lines | Where-Object { $_ -match '^\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}Z\s' } | ForEach-Object { $_.Trim() }

if ($timeline.Count -eq 0) {
    Write-Output ""
    Write-Output "the pass produced no timeline. its output was:"
    Write-Output "--------------------------------------------"
    $lines | Select-Object -Last 30 | ForEach-Object { Write-Output "  $_" }
    Write-Output "--------------------------------------------"
    if ($jobExit -eq 2) {
        Write-Output ""
        Write-Output "no server was reachable. start one in a separate terminal:"
        Write-Output "  .\assessment\scripts\start-server.ps1"
    }
    exit 1
}

# --- application.log : what the pass logged -------------------------------
$timeline | Out-File -FilePath (Join-Path $evidence "application.log") -Encoding utf8

# --- client-stack-traces.txt : the exception the pass reported ------------
$inBlock = $false
$stack = @()
foreach ($line in $lines) {
    if ($line -match '---- client exception ----') { $inBlock = $true; continue }
    if ($line -match '---- end client exception ----') { $inBlock = $false; continue }
    if ($inBlock) { $stack += $line.Trim() }
}
if ($stack.Count -eq 0) { $stack = @("(this run produced no client exception - either it stayed clean, or the anomaly it hit was a wrong value rather than a throw)") }
$stack | Out-File -FilePath (Join-Path $evidence "client-stack-traces.txt") -Encoding utf8

# --- runtime-and-counters.txt ---------------------------------------------
$anomalies = $timeline | Where-Object { $_ -match 'anomaly\s+\|' } | ForEach-Object { ($_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}Z\s+', '') }

$counters = @()
$counters += "captured: " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss'Z'")
$counters += "os:       " + [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()
$counters += "arch:     " + [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$counters += "cpus:     " + [System.Environment]::ProcessorCount
$counters += "dotnet:   " + $sdkVersion
$counters += "server:   " + $serverUrl
$counters += "budget:   $Minutes minute(s), $Workers workers"
$counters += ""
$counters += "counters reported by the pass"
$counters += "-----------------------------"
$counters += ($timeline |
    Where-Object { $_ -match 'requests=|rounds=|cacheItems=' } |
    ForEach-Object { ($_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}Z\s+', '') })
$counters += ""
$counters += "anomalies this run"
$counters += "------------------"
if ($anomalies) { $counters += $anomalies } else { $counters += "(none - the pass stayed clean within its budget)" }
$counters += ""
$counters += "job exit code: $jobExit"
$counters | Out-File -FilePath (Join-Path $evidence "runtime-and-counters.txt") -Encoding utf8

# --- run-history.txt : one line per capture, appended --------------------
$historyFile = Join-Path $evidence "run-history.txt"
if ((Test-Path $historyFile) -eq $false) {
    @(
        "One line per capture, oldest first. The point of this file is the variation:",
        "the failing account, the exception and the time to failure differ on every run.",
        ""
    ) | Out-File -FilePath $historyFile -Encoding utf8
}

$endLine = ($timeline | Where-Object { $_ -match 'job end\s+\|\s+exit=' } | Select-Object -First 1)
$summary = if ($anomalies) { ($anomalies | Select-Object -First 1) -replace '^anomaly\s+\|\s+', '' } else { "no anomaly within the budget" }
$stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss'Z'")
$totals = if ($endLine) { ($endLine -replace '^.*job end\s+\|\s+exit=\d+\s+', '') } else { "(no summary line)" }

"$stamp  exit=$jobExit  $totals" | Out-File -FilePath $historyFile -Encoding utf8 -Append
"                        $summary" | Out-File -FilePath $historyFile -Encoding utf8 -Append

Write-Output ""
if ($jobExit -eq 1) {
    Write-Output "reproduced. job exit code: $jobExit"
}
elseif ($jobExit -eq 0) {
    Write-Output "no anomaly within the budget. job exit code: $jobExit"
    Write-Output ""
    Write-Output "  If you have not changed any code yet, this stand did not surface the problem on"
    Write-Output "  your machine on this run. Try a few more times. If it keeps coming back clean,"
    Write-Output "  stop retrying and tell us - we will sort it out with you."
    Write-Output ""
    Write-Output "  If you have already changed code, this run is consistent with your change having"
    Write-Output "  removed the problem. It is not proof on its own. Make that case in your write-up"
    Write-Output "  and back it with the regression test you are asked to supply, not with this exit"
    Write-Output "  code."
}
else {
    Write-Output "job exit code: $jobExit"
}
Write-Output "evidence refreshed under $evidence"
Get-ChildItem $evidence | ForEach-Object { Write-Output ("  {0,-26} {1,6} bytes" -f $_.Name, $_.Length) }
