Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
if (-not (Test-Path -Path $jsonPath -PathType Leaf)) {
    throw "Fatal: workspaces.json not found at '$jsonPath'."
}

$db = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
$configProperty = $db.PSObject.Properties["_config"]
$configObject = $null
if ($null -ne $configProperty) {
    $configObject = $configProperty.Value
}

$consoleStyle = "Normal"
if ($null -ne $configObject) {
    $consoleStyleProperty = $configObject.PSObject.Properties["console_style"]
    if ($null -ne $consoleStyleProperty -and $consoleStyleProperty.Value -eq "Hidden") {
        $consoleStyle = "Hidden"
    }
}

$shortcutDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\WorkspaceManager"
if (-not (Test-Path -Path $shortcutDir -PathType Container)) {
    New-Item -ItemType Directory -Path $shortcutDir -Force | Out-Null
}

Get-ChildItem -Path $shortcutDir -Filter "*.lnk" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$wshShell = New-Object -ComObject WScript.Shell
$orchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"

foreach ($workspaceName in $db.PSObject.Properties.Name) {
    if ($workspaceName -eq "_config") {
        continue
    }

    $startShortcutPath = Join-Path -Path $shortcutDir -ChildPath "!Start-$workspaceName.lnk"
    $startShortcut = $wshShell.CreateShortcut($startShortcutPath)
    $startShortcut.TargetPath = "pwsh.exe"
    $startShortcut.Arguments = "-WindowStyle $consoleStyle -ExecutionPolicy Bypass -File `"$orchestratorPath`" -WorkspaceName `"$workspaceName`" -Action `"Start`""
    $startShortcut.Save()

    $stopShortcutPath = Join-Path -Path $shortcutDir -ChildPath "!Stop-$workspaceName.lnk"
    $stopShortcut = $wshShell.CreateShortcut($stopShortcutPath)
    $stopShortcut.TargetPath = "pwsh.exe"
    $stopShortcut.Arguments = "-WindowStyle $consoleStyle -ExecutionPolicy Bypass -File `"$orchestratorPath`" -WorkspaceName `"$workspaceName`" -Action `"Stop`""
    $stopShortcut.Save()
}

Write-Host "[ SUCCESS ] Workspace shortcuts generated and indexed in the Start Menu." -ForegroundColor Green
