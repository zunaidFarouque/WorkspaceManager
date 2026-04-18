#Requires -Version 7.0
<#
.SYNOPSIS
Creates a double-clickable shortcut (with custom icon) to the WorkspaceManager dashboard.

.DESCRIPTION
Windows .cmd files cannot show a custom Explorer icon. This script writes a .lnk that
targets Scripts/Run-Dashboard.cmd and uses Assets/Dashboard.ico when present.

.PARAMETER ShortcutPath
Full path to the .lnk file to create. Default: Desktop\Workspace Manager Dashboard.lnk
#>
[CmdletBinding()]
param(
    [string]$ShortcutPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$launcher = Join-Path -Path $PSScriptRoot -ChildPath "Run-Dashboard.cmd"
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Missing Scripts/Run-Dashboard.cmd at '$launcher'."
}

$iconIco = Join-Path -Path $repoRoot -ChildPath "Assets\Dashboard.ico"
$iconFallback = (Get-Command -Name "pwsh.exe" -ErrorAction Stop).Source

if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $ShortcutPath = Join-Path -Path $desktop -ChildPath "Workspace Manager Dashboard.lnk"
}

if (-not (Test-Path -LiteralPath $iconIco)) {
    Write-Warning "Custom icon not found at '$iconIco'. Using pwsh.exe icon instead."
    $iconLocation = "$iconFallback,0"
} else {
    $iconLocation = "$iconIco,0"
}

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $launcher
$shortcut.WorkingDirectory = $repoRoot
$shortcut.IconLocation = $iconLocation
$shortcut.Description = "WorkspaceManager interactive dashboard (PowerShell 7)"
$shortcut.Save()

Write-Host "[ SUCCESS ] Shortcut created:" -ForegroundColor Green
Write-Host "  $ShortcutPath" -ForegroundColor Cyan
