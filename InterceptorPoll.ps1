Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
    [Parameter(Mandatory = $true)]
    [string]$WorkloadName,

    [Parameter(Mandatory = $true)]
    [string]$RequiredServicesJson,

    [Parameter(Mandatory = $true)]
    [string]$RequiredExecutablesJson,

    [Parameter(Mandatory = $true)]
    [int]$MaxSeconds,

    [Parameter(Mandatory = $true)]
    [int]$PollIntervalSeconds,

    [Parameter(Mandatory = $false)]
    [string]$PollMarker = "WorkspaceManager_InterceptorPoll"
)

try {
    $title = "WorkspaceManager InterceptorPoll ($WorkloadName)"
    $Host.UI.RawUI.WindowTitle = $title
} catch {
    # Hidden windows may not expose RawUI; ignore best-effort.
}

. (Join-Path -Path $PSScriptRoot -ChildPath "Interceptor.ps1")

function ConvertFrom-JsonAsArray {
    param([Parameter(Mandatory = $true)][string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return @()
    }

    $parsed = $JsonText | ConvertFrom-Json
    return @($parsed)
}

$requiredServices = ConvertFrom-JsonAsArray -JsonText $RequiredServicesJson
$requiredExecutables = ConvertFrom-JsonAsArray -JsonText $RequiredExecutablesJson

# Enforce absolute readiness polling cap (defense-in-depth).
$maxSeconds = [Math]::Min([int]$MaxSeconds, 15)
$pollIntervalSeconds = [int]$PollIntervalSeconds
if ($pollIntervalSeconds -lt 0) { $pollIntervalSeconds = 0 }

$isReady = Wait-ForInterceptorRuleActive `
    -RequiredServices $requiredServices `
    -RequiredExecutables $requiredExecutables `
    -MaxSeconds $maxSeconds `
    -PollIntervalSeconds $pollIntervalSeconds

if ($isReady) {
    exit 0
}

exit 1

