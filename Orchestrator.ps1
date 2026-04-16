[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Start", "Stop")]
    [string]$Action,

    [ValidateSet("App_Workload", "System_Mode", "Hardware_Override")]
    [string]$ProfileType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command -Name Show-Notification -CommandType Function -ErrorAction SilentlyContinue)) {
    function Show-Notification {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Title,
            [Parameter(Mandatory = $true)]
            [string]$Message
        )

        try {
            $xmlPayload = @"
<toast>
  <visual>
    <binding template='ToastGeneric'>
      <text>$Title</text>
      <text>$Message</text>
    </binding>
  </visual>
</toast>
"@

            $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xmlDoc.LoadXml($xmlPayload)
            $toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("WorkspaceManager")
            $notifier.Show($toast)
        } catch {
            return
        }
    }
}

$dbPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
if (-not (Test-Path -Path $dbPath -PathType Leaf)) {
    throw "Fatal: workspaces.json not found."
}

$script:OrchestratorRepoRoot = [System.IO.Path]::GetDirectoryName($dbPath)
try {
    $workspaces = Get-Content -Path $dbPath -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
    $parseDetail = $_.Exception.Message
    throw "Fatal: Failed to parse workspaces.json. $parseDetail"
}

$showNotifications = $false
$configProperty = $workspaces.PSObject.Properties["_config"]
if ($null -ne $configProperty) {
    $notificationsProperty = $configProperty.Value.PSObject.Properties["notifications"]
    if ($null -ne $notificationsProperty -and $notificationsProperty.Value -eq $true) {
        $showNotifications = $true
    }
}

$script:ExecutionWaitTimeoutMs = 15000

function Wait-ProcessWithTimeout {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][string]$OperationName
    )

    if ($TimeoutMs -le 0) {
        $Process.WaitForExit()
        return
    }

    $finished = $Process.WaitForExit($TimeoutMs)
    if (-not $finished) {
        try {
            if (-not $Process.HasExited) {
                $Process.Kill($true)
            }
        } catch {
            # Best effort cleanup; continue with warning below.
        }
        Write-Warning "Timeout while waiting for '$OperationName'. Continuing after $TimeoutMs ms."
    }
}

function Resolve-QuotedRelativeExecutionToken {
    param([Parameter(Mandatory)][string]$ExecutionToken)
    $root = $script:OrchestratorRepoRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $PSScriptRoot
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    [regex]::Replace($ExecutionToken, "^'\.[\/\\](.*?)'", {
        param($match)
        $relativeRemainder = $match.Groups[1].Value -replace '/', $sep
        "'" + (Join-Path $root $relativeRemainder) + "'"
    })
}

function Resolve-RepoRelativeFilePath {
    param([Parameter(Mandatory)][string]$Path)
    $root = $script:OrchestratorRepoRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $PSScriptRoot
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $t = $Path.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq [char]'.' -and ($t[1] -eq [char]'/' -or $t[1] -eq '\')) {
        $rest = $t.Substring(2).TrimStart([char[]]@('/', '\'))
        $rest = $rest -replace '/', [System.IO.Path]::DirectorySeparatorChar
        return (Join-Path $root $rest)
    }
    return $Path
}

function Start-ShortcutOrUrlShellExecute {
    param(
        [Parameter(Mandatory)][string]$ItemPath,
        [string]$Arguments,
        [switch]$Wait
    )

    $full = [System.IO.Path]::GetFullPath($ItemPath)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = $script:OrchestratorRepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = $PSScriptRoot
        }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $full
    $psi.WorkingDirectory = $dir
    $psi.UseShellExecute = $true
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $psi.Arguments = $Arguments
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($Wait -and $null -ne $proc) {
        Wait-ProcessWithTimeout -Process $proc -TimeoutMs $script:ExecutionWaitTimeoutMs -OperationName $full
    }
}

function Invoke-ExecutionToken {
    param(
        [Parameter(Mandatory)][string]$ExecutionToken,
        [switch]$Wait
    )

    $token = Resolve-QuotedRelativeExecutionToken -ExecutionToken $ExecutionToken
    $filePath = $token
    $argumentList = ""
    $tokenWasQuotedPath = $false
    if ($token -match "^'(.*?)'\s*(.*)$") {
        $filePath = $matches[1]
        $argumentList = $matches[2]
        $tokenWasQuotedPath = $true
    } elseif ($token -match "^(\S+)\s+(.+)$") {
        # Support command tokens like: gsudo taskkill /F /IM GCC.exe
        $filePath = $matches[1]
        $argumentList = $matches[2]
    }

    $shouldResolveAsPath = $tokenWasQuotedPath -or
        $filePath.StartsWith(".\") -or
        $filePath.StartsWith("./") -or
        $filePath -match '^[a-zA-Z]:[\\/]' -or
        $filePath.Contains("\") -or
        $filePath.Contains("/")

    if ($shouldResolveAsPath) {
        $filePath = Resolve-RepoRelativeFilePath -Path $filePath
        $filePath = [System.IO.Path]::GetFullPath($filePath)
    }

    $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()

    if ($filePath -match '\.ps1$') {
        $pwshArg = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$filePath`""
        if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
            $pwshArg = "$pwshArg $argumentList"
        }

        if ($Wait) {
            Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg -Wait -NoNewWindow 2>&1 | Out-Null
        } else {
            Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg 2>&1 | Out-Null
        }
        return
    }

    if ($ext -eq ".lnk" -or $ext -eq ".url") {
        if ([string]::IsNullOrWhiteSpace($argumentList)) {
            Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Wait:$Wait
        } else {
            Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Arguments $argumentList -Wait:$Wait
        }
        return
    }

    if ($Wait) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $filePath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
            $psi.Arguments = $argumentList
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $proc) {
            $opName = if ([string]::IsNullOrWhiteSpace($argumentList)) { $filePath } else { "$filePath $argumentList" }
            Wait-ProcessWithTimeout -Process $proc -TimeoutMs $script:ExecutionWaitTimeoutMs -OperationName $opName
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($argumentList)) {
            Start-Process -FilePath $filePath 2>&1 | Out-Null
        } else {
            Start-Process -FilePath $filePath -ArgumentList $argumentList 2>&1 | Out-Null
        }
    }
}

function Set-PowerPlanByName {
    param([Parameter(Mandatory)][string]$PlanName)

    $plansOutput = powercfg /l
    foreach ($line in @($plansOutput)) {
        if ($line -match [regex]::Escape($PlanName)) {
            $guidMatch = [regex]::Match([string]$line, "([0-9a-fA-F-]{36})")
            if ($guidMatch.Success) {
                powercfg /setactive $guidMatch.Groups[1].Value | Out-Null
            }
            break
        }
    }
}

function Invoke-HardwareDefinitionTransition {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][psobject]$Definition,
        [Parameter(Mandatory = $true)][string]$DesiredState
    )

    $overrideEntries = $null
    if ($DesiredState -eq "ON" -and $null -ne $Definition.PSObject.Properties["action_override_on"]) {
        $overrideEntries = @($Definition.action_override_on)
    } elseif ($DesiredState -eq "OFF" -and $null -ne $Definition.PSObject.Properties["action_override_off"]) {
        $overrideEntries = @($Definition.action_override_off)
    }

    if ($null -ne $overrideEntries -and $overrideEntries.Count -gt 0) {
        foreach ($entry in $overrideEntries) {
            if ([string]::IsNullOrWhiteSpace([string]$entry)) { continue }
            Invoke-ExecutionToken -ExecutionToken ([string]$entry -replace "^'+|'+$", "") -Wait
        }
        return
    }

    switch ([string]$Definition.type) {
        "pnp_device" {
            foreach ($matchPattern in @($Definition.match)) {
                if ([string]::IsNullOrWhiteSpace([string]$matchPattern)) { continue }
                $verb = if ($DesiredState -eq "ON") { "Enable-PnpDevice" } else { "Disable-PnpDevice" }
                $psCmd = 'Get-PnpDevice -FriendlyName "{0}" -ErrorAction SilentlyContinue | {1} -Confirm:$false -ErrorAction SilentlyContinue' -f ([string]$matchPattern), $verb
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCmd))
                gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1 | Out-Null
            }
        }
        "service" {
            $serviceName = [string]$Definition.name
            if ([string]::IsNullOrWhiteSpace($serviceName)) { break }
            if ($DesiredState -eq "ON") {
                gsudo Start-Service -Name $serviceName 2>&1 | Out-Null
            } else {
                gsudo Stop-Service -Name $serviceName -Force 2>&1 | Out-Null
            }
        }
        "registry" {
            $valueToSet = if ($DesiredState -eq "ON") { $Definition.value_on } else { $Definition.value_off }
            $path = [string]$Definition.path
            $name = [string]$Definition.name
            if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($name)) { break }
            $propertyType = "DWord"
            if ($null -ne $Definition.PSObject.Properties["value_type"] -and -not [string]::IsNullOrWhiteSpace([string]$Definition.value_type)) {
                $propertyType = [string]$Definition.value_type
            }
            gsudo New-ItemProperty -Path $path -Name $name -Value $valueToSet -PropertyType $propertyType -Force 2>&1 | Out-Null
        }
        "process" {
            # No native command path for process targets; rely on action overrides.
        }
        "stateless" {
            # No native command path for stateless targets.
        }
    }
}

# Phase 1 routing: resolve profile type and data
$resolvedProfileType = $null
$resolvedProfileData = $null
$systemModesProperty = $workspaces.PSObject.Properties["System_Modes"]
$appWorkloadsProperty = $workspaces.PSObject.Properties["App_Workloads"]
$hardwareDefsProperty = $workspaces.PSObject.Properties["Hardware_Definitions"]

if (-not [string]::IsNullOrWhiteSpace($ProfileType)) {
    if ($ProfileType -eq "Hardware_Override") {
        if ($null -eq $hardwareDefsProperty -or $null -eq $hardwareDefsProperty.Value.PSObject.Properties[$WorkspaceName]) {
            throw "Fatal: Hardware override component '$WorkspaceName' not defined in workspaces.json."
        }
        $resolvedProfileType = "Hardware_Override"
        $resolvedProfileData = $hardwareDefsProperty.Value.PSObject.Properties[$WorkspaceName].Value
    } elseif ($ProfileType -eq "System_Mode") {
        if ($null -eq $systemModesProperty -or $null -eq $systemModesProperty.Value.PSObject.Properties[$WorkspaceName]) {
            throw "Fatal: Workspace '$WorkspaceName' not defined under System_Modes in workspaces.json."
        }
        $resolvedProfileType = "System_Mode"
        $resolvedProfileData = $systemModesProperty.Value.PSObject.Properties[$WorkspaceName].Value
    } elseif ($ProfileType -eq "App_Workload") {
        if ($null -eq $appWorkloadsProperty -or $null -eq $appWorkloadsProperty.Value.PSObject.Properties[$WorkspaceName]) {
            throw "Fatal: Workspace '$WorkspaceName' not defined under App_Workloads in workspaces.json."
        }
        $resolvedProfileType = "App_Workload"
        $resolvedProfileData = $appWorkloadsProperty.Value.PSObject.Properties[$WorkspaceName].Value
    }
} elseif ($null -ne $systemModesProperty -and $null -ne $systemModesProperty.Value.PSObject.Properties[$WorkspaceName]) {
    $resolvedProfileType = "System_Mode"
    $resolvedProfileData = $systemModesProperty.Value.PSObject.Properties[$WorkspaceName].Value
} elseif ($null -ne $appWorkloadsProperty -and $null -ne $appWorkloadsProperty.Value.PSObject.Properties[$WorkspaceName]) {
    $resolvedProfileType = "App_Workload"
    $resolvedProfileData = $appWorkloadsProperty.Value.PSObject.Properties[$WorkspaceName].Value
} else {
    throw "Fatal: Workspace '$WorkspaceName' not defined in workspaces.json."
}

# Phase 3/4 execution
if ($resolvedProfileType -eq "App_Workload") {
    if ($Action -eq "Start") {
        foreach ($serviceName in @($resolvedProfileData.services)) {
            if ([string]::IsNullOrWhiteSpace([string]$serviceName)) { continue }
            gsudo Start-Service -Name ([string]$serviceName) 2>&1 | Out-Null
        }
        foreach ($executionToken in @($resolvedProfileData.executables)) {
            if ([string]::IsNullOrWhiteSpace([string]$executionToken)) { continue }
            Invoke-ExecutionToken -ExecutionToken ([string]$executionToken)
        }

        if ($showNotifications) {
            Show-Notification -Title "Workspace Ready" -Message "$WorkspaceName is now active."
        }
    } else {
        $executables = @($resolvedProfileData.executables)
        for ($i = $executables.Count - 1; $i -ge 0; $i--) {
            $executionToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken ([string]$executables[$i])
            $filePath = $executionToken
            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
            }
            $filePath = Resolve-RepoRelativeFilePath -Path $filePath
            $exeName = Split-Path -Path $filePath -Leaf
            if (-not [string]::IsNullOrWhiteSpace($exeName)) {
                gsudo taskkill /F /IM $exeName /T 2>&1 | Out-Null
            }
        }
        foreach ($serviceName in @($resolvedProfileData.services)) {
            if ([string]::IsNullOrWhiteSpace([string]$serviceName)) { continue }
            gsudo Stop-Service -Name ([string]$serviceName) -Force 2>&1 | Out-Null
        }

        if ($showNotifications) {
            Show-Notification -Title "Workspace Stopped" -Message "$WorkspaceName has been cleanly terminated."
        }
    }
} elseif ($resolvedProfileType -eq "System_Mode") {
    $powerPlanProp = $resolvedProfileData.PSObject.Properties["power_plan"]
    if ($Action -eq "Start" -and $null -ne $powerPlanProp -and -not [string]::IsNullOrWhiteSpace([string]$powerPlanProp.Value)) {
        Set-PowerPlanByName -PlanName ([string]$powerPlanProp.Value)
    }

    foreach ($target in $resolvedProfileData.targets.PSObject.Properties) {
        $componentName = $target.Name
        $targetState = [string]$target.Value
        if ($targetState -eq "ANY") {
            continue
        }

        $desiredState = $targetState
        if ($Action -eq "Stop") {
            $desiredState = if ($targetState -eq "ON") { "OFF" } else { "ON" }
        }

        $hardwareDefs = $workspaces.PSObject.Properties["Hardware_Definitions"]
        if ($null -eq $hardwareDefs -or $null -eq $hardwareDefs.Value.PSObject.Properties[$componentName]) {
            continue
        }
        $def = $hardwareDefs.Value.PSObject.Properties[$componentName].Value
        Invoke-HardwareDefinitionTransition -ComponentName $componentName -Definition $def -DesiredState $desiredState
    }

    if ($Action -eq "Start" -and $showNotifications) {
        Show-Notification -Title "Workspace Ready" -Message "$WorkspaceName is now active."
    }
    if ($Action -eq "Stop" -and $showNotifications) {
        Show-Notification -Title "Workspace Stopped" -Message "$WorkspaceName has been cleanly terminated."
    }
} elseif ($resolvedProfileType -eq "Hardware_Override") {
    $targetState = if ($null -ne $resolvedProfileData.PSObject.Properties["target_state"]) { [string]$resolvedProfileData.target_state } else { "" }
    if ([string]::IsNullOrWhiteSpace($targetState)) {
        $targetState = if ($Action -eq "Start") { "ON" } else { "OFF" }
    }
    if ($targetState -eq "ANY") {
        $resolvedProfileData
        return
    }

    $desiredState = $targetState

    Invoke-HardwareDefinitionTransition -ComponentName $WorkspaceName -Definition $resolvedProfileData -DesiredState $desiredState
}

$resolvedProfileData
