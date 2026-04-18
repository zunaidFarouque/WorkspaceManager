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
$prefixStart = "!Start-"
$prefixStop = "!Stop-"
if ($null -ne $configObject) {
    $consoleStyleProperty = $configObject.PSObject.Properties["console_style"]
    if ($null -ne $consoleStyleProperty -and $consoleStyleProperty.Value -eq "Hidden") {
        $consoleStyle = "Hidden"
    }

    $prefixStartProperty = $configObject.PSObject.Properties["shortcut_prefix_start"]
    if ($null -ne $prefixStartProperty -and -not [string]::IsNullOrWhiteSpace([string]$prefixStartProperty.Value)) {
        $prefixStart = [string]$prefixStartProperty.Value
    }

    $prefixStopProperty = $configObject.PSObject.Properties["shortcut_prefix_stop"]
    if ($null -ne $prefixStopProperty -and -not [string]::IsNullOrWhiteSpace([string]$prefixStopProperty.Value)) {
        $prefixStop = [string]$prefixStopProperty.Value
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
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$iconIco = Join-Path -Path $repoRoot -ChildPath "Assets\Dashboard.ico"
$iconFallback = (Get-Command -Name "pwsh.exe" -ErrorAction Stop).Source
if (-not (Test-Path -LiteralPath $iconIco)) {
    Write-Warning "Custom icon not found at '$iconIco'. Using pwsh.exe icon for Start Menu shortcuts."
    $iconLocation = "$iconFallback,0"
} else {
    $iconLocation = "$iconIco,0"
}
$metadataKeys = @("_config", "comment", "description")

function Get-ShortcutModeFromNode {
    param([object]$Node)

    if ($null -eq $Node -or $Node -isnot [pscustomobject]) {
        return "both"
    }
    $createForProperty = $Node.PSObject.Properties["create_shortcut_for"]
    if ($null -eq $createForProperty) {
        return "both"
    }
    $raw = [string]$createForProperty.Value
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return "both"
    }
    $normalized = $raw.Trim().ToLowerInvariant()
    switch ($normalized) {
        "none" { return "none" }
        "start" { return "start" }
        "stop" { return "stop" }
        default {
            throw "Invalid create_shortcut_for: '$raw'. Allowed values: none, start, stop."
        }
    }
}

function Add-ShortcutTarget {
    param(
        [Parameter(Mandatory)][string]$Name,
        [object]$Node,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, object]]$Seen
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }
    if ($Seen.ContainsKey($Name)) {
        Write-Warning (
            "Skipping duplicate shortcut name '$Name'. " +
            "The orchestrator resolves workloads by name across domains in definition order; only one shortcut can use this filename."
        )
        return
    }
    [void]$Seen.Add($Name, $true)
    return [pscustomobject]@{
        Name = $Name
        Node = $Node
    }
}

$targets = [System.Collections.Generic.List[object]]::new()
$seenNames = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

$systemModesProp = $db.PSObject.Properties["System_Modes"]
if ($null -ne $systemModesProp -and $null -ne $systemModesProp.Value) {
    foreach ($modeProp in $systemModesProp.Value.PSObject.Properties) {
        $t = Add-ShortcutTarget -Name $modeProp.Name -Node $modeProp.Value -Seen $seenNames
        if ($null -ne $t) { $targets.Add($t) }
    }
}

$appWorkloadsProp = $db.PSObject.Properties["App_Workloads"]
if ($null -ne $appWorkloadsProp -and $null -ne $appWorkloadsProp.Value) {
    foreach ($domainProp in $appWorkloadsProp.Value.PSObject.Properties) {
        if ($null -eq $domainProp.Value) { continue }
        foreach ($workloadProp in $domainProp.Value.PSObject.Properties) {
            $t = Add-ShortcutTarget -Name $workloadProp.Name -Node $workloadProp.Value -Seen $seenNames
            if ($null -ne $t) { $targets.Add($t) }
        }
    }
}

foreach ($target in $targets) {
    $workspaceName = [string]$target.Name
    try {
        $shortcutMode = Get-ShortcutModeFromNode -Node $target.Node
    } catch {
        throw ("Invalid create_shortcut_for for shortcut target '{0}': {1}" -f $workspaceName, $_.Exception.Message)
    }

    if ($shortcutMode -eq "both" -or $shortcutMode -eq "start") {
        $startShortcutPath = Join-Path -Path $shortcutDir -ChildPath "$prefixStart$workspaceName.lnk"
        $startShortcut = $wshShell.CreateShortcut($startShortcutPath)
        $startShortcut.TargetPath = "pwsh.exe"
        $startShortcut.WorkingDirectory = $PSScriptRoot
        $startShortcut.Arguments = "-WindowStyle $consoleStyle -ExecutionPolicy Bypass -File `"$orchestratorPath`" -WorkspaceName `"$workspaceName`" -Action `"Start`""
        $startShortcut.IconLocation = $iconLocation
        $startShortcut.Save()
    }

    if ($shortcutMode -eq "both" -or $shortcutMode -eq "stop") {
        $stopShortcutPath = Join-Path -Path $shortcutDir -ChildPath "$prefixStop$workspaceName.lnk"
        $stopShortcut = $wshShell.CreateShortcut($stopShortcutPath)
        $stopShortcut.TargetPath = "pwsh.exe"
        $stopShortcut.WorkingDirectory = $PSScriptRoot
        $stopShortcut.Arguments = "-WindowStyle $consoleStyle -ExecutionPolicy Bypass -File `"$orchestratorPath`" -WorkspaceName `"$workspaceName`" -Action `"Stop`""
        $stopShortcut.IconLocation = $iconLocation
        $stopShortcut.Save()
    }
}

Write-Host "[ SUCCESS ] Workspace shortcuts generated and indexed in the Start Menu." -ForegroundColor Green
