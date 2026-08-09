<#
    Starts a RavenDB server from this tree, in the foreground, on http://127.0.0.1:8080.

    Leave it running in its own terminal and use another one for the job. Ctrl+C stops it.
    Its data lives under src/Raven.Server/RavenData and can be deleted between runs.
#>

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dotnet = if ($env:RAVEN_DOTNET) { $env:RAVEN_DOTNET } else { "dotnet" }

$sdkVersion = (& $dotnet --version 2>&1 | Out-String).Trim()
if ($env:MSBuildSDKsPath -and $env:MSBuildSDKsPath -notmatch [regex]::Escape("sdk\$sdkVersion\Sdks")) {
    Write-Output "note: ignoring MSBuildSDKsPath for this run, it pins MSBuild to a different SDK than $sdkVersion"
    Remove-Item Env:MSBuildSDKsPath -ErrorAction SilentlyContinue
}

$license = Join-Path $root "license.json"
if (-not (Test-Path $license)) {
    Write-Output ""
    Write-Output "No license found at $license"
    Write-Output ""
    Write-Output "RavenDB needs a license to run. A free developer license is enough:"
    Write-Output "  https://ravendb.net/license/request/dev"
    Write-Output ""
    Write-Output "Save the file you receive as license.json in the root of this repository,"
    Write-Output "next to RavenDB.sln, and run this script again."
    Write-Output ""
    exit 1
}

Write-Output "starting RavenDB on http://127.0.0.1:8080 (Ctrl+C to stop)"
Write-Output ""

& $dotnet run --project (Join-Path $root "src\Raven.Server\Raven.Server.csproj") -c Release -- --License.Path="$license"
