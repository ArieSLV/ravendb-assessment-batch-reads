<#
    Preflight for the stand. Verifies the toolchain, builds the server and the job, and reports
    whether a server is already listening. Does not build the full solution.
#>

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dotnet = if ($env:RAVEN_DOTNET) { $env:RAVEN_DOTNET } else { "dotnet" }
$serverUrl = if ($env:RECONCILIATION_URL) { $env:RECONCILIATION_URL } else { "http://127.0.0.1:8080" }

function Step($name, $ok, $detail) {
    $mark = if ($ok) { "OK  " } else { "FAIL" }
    Write-Output ("[{0}] {1,-28} {2}" -f $mark, $name, $detail)
    if (-not $ok) { $script:failed = $true }
}

$script:failed = $false

Write-Output "stand root: $root"
Write-Output ""

$sdk = & $dotnet --version 2>&1
Step "dotnet sdk" ($LASTEXITCODE -eq 0) $sdk

$runtimes = (& $dotnet --list-runtimes 2>&1 | Select-String "Microsoft.NETCore.App 10\.") -ne $null
Step "net10.0 runtime" $runtimes "required by the server and the job"

# A stale MSBuildSDKsPath pins MSBuild to one specific SDK, and every net10.0 project then fails
# with NETSDK1045. Drop it for this process only - the persistent value is not touched.
$sdkVersion = ($sdk | Out-String).Trim()
if ($env:MSBuildSDKsPath) {
    if ($env:MSBuildSDKsPath -match [regex]::Escape("sdk\$sdkVersion\Sdks")) {
        Step "MSBuildSDKsPath" $true "set, and it matches the active SDK"
    }
    else {
        Remove-Item Env:MSBuildSDKsPath -ErrorAction SilentlyContinue
        Step "MSBuildSDKsPath" $true "pins MSBuild to another SDK - ignored for this run, your environment is unchanged"
    }
}

$license = Join-Path $root "license.json"
if (Test-Path $license) {
    Step "license" $true "license.json found in the stand root"
}
else {
    Step "license" $false "no license.json in the stand root - request a free developer license at https://ravendb.net/license/request/dev and save it there"
}

$projects = @(
    @{ Name = "Raven.Server"; Path = "src\Raven.Server\Raven.Server.csproj" },
    @{ Name = "the job";      Path = "assessment\reconciliation-job\ReconciliationJob.csproj" }
)

foreach ($proj in $projects) {
    $out = & $dotnet build (Join-Path $root $proj.Path) -c Release -v q --nologo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Step "build $($proj.Name)" $true ""
    }
    else {
        $errors = ($out -split "`r?`n") |
            Where-Object { $_ -match '(?i):\s*error\s' } |
            ForEach-Object { ($_ -replace '\s*\[[^\]]*proj\]\s*$', '').Trim() } |
            Select-Object -Unique -First 10
        Step "build $($proj.Name)" $false ""
        if ($errors) { $errors | ForEach-Object { Write-Output "       $_" } }
    }
}

$listening = $false
try {
    $probe = Invoke-WebRequest -Uri "$($serverUrl.TrimEnd('/'))/build/version" -TimeoutSec 5 -UseBasicParsing
    $listening = $probe.StatusCode -eq 200
}
catch {
    $listening = $false
}
Step "server at $serverUrl" $true $(if ($listening) { "listening" } else { "not running yet - start it before the job" })

Write-Output ""
if ($script:failed) {
    Write-Output "preflight FAILED"
    exit 1
}

Write-Output "preflight OK"
Write-Output ""
if ($listening -eq $false) {
    Write-Output "next, in a separate terminal:"
    Write-Output "  .\assessment\scripts\start-server.ps1"
    Write-Output ""
}
Write-Output "then:"
Write-Output "  .\assessment\scripts\run-incident.ps1"
