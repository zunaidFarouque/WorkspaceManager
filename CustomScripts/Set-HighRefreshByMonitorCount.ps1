$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

$singleShortcut = Join-Path $scriptRoot "Monitors Refresh 90hz.lnk"
$dualShortcut = Join-Path $scriptRoot "Monitors Refresh 75hz (Dual).lnk"
$fallbackSingle = Join-Path $repoRoot "CustomScripts\\Monitors Refresh 90hz.lnk"
$fallbackDual = Join-Path $repoRoot "CustomScripts\\Monitors Refresh 75hz (Dual).lnk"

if (-not (Test-Path -LiteralPath $singleShortcut)) { $singleShortcut = $fallbackSingle }
if (-not (Test-Path -LiteralPath $dualShortcut)) { $dualShortcut = $fallbackDual }

$activeMonitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue |
    Where-Object { $_.Active -eq $true })
$monitorCount = $activeMonitors.Count
if ($monitorCount -lt 1) { $monitorCount = 1 }

$targetShortcut = if ($monitorCount -ge 2) { $dualShortcut } else { $singleShortcut }

if (Test-Path -LiteralPath $targetShortcut) {
    Start-Process -FilePath $targetShortcut | Out-Null
}
