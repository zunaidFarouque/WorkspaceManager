param(
    [string]$AutoCommitWorkloadName,
    [string]$ObserveWorkloadName,
    [int]$ObserveSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Host.UI.RawUI.WindowTitle = "WorkspaceManager Dashboard"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path -Path $PSScriptRoot -ChildPath "WorkspaceState.ps1")

$script:ComplianceData = @()
$script:WorkloadStates = @()
$script:ModeStates = @()
$script:SettingsStates = @()
$script:HasMultipleModes = $false
$script:PendingHardwareChanges = @{}

function Invoke-OrchestratorScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Start", "Stop")]
        [string]$Action,
        [ValidateSet("App_Workload", "System_Mode", "Hardware_Override")]
        [string]$ProfileType
    )

    if ([string]::IsNullOrWhiteSpace($ProfileType)) {
        & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action
    } else {
        & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action -ProfileType $ProfileType
    }
}

function Write-StateText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$State
    )

    if ([string]::IsNullOrWhiteSpace($State)) {
        Write-Host -NoNewline "-" -ForegroundColor DarkGray
        return
    }

    $color = if ($State -like "Mixed*") {
        "Yellow"
    } else {
        switch ($State) {
            "Inactive" { "Green" }
            "Active" { "Red" }
            "Mixed" { "Yellow" }
            default { "Gray" }
        }
    }
    Write-Host -NoNewline $State -ForegroundColor $color
}

function Update-DashboardDesiredStateOnSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CurrentState,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DesiredState
    )

    if ($CurrentState -eq "Mixed") {
        if ($DesiredState -eq "Active") { return "Inactive" }
        return "Active"
    }
    if ($DesiredState -eq "Active") { return "Inactive" }
    return "Active"
}

function Update-DashboardHardwareDesiredStateOnSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DesiredState
    )

    if ($DesiredState -eq "ON") { return "OFF" }
    return "ON"
}

function Save-DashboardStateMemory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ModeStates,
        [Parameter(Mandatory = $true)]
        [string]$StateFilePath
    )

    $activeMode = @($ModeStates | Where-Object { $_.DesiredState -eq "Active" } | Select-Object -First 1)
    if ($activeMode.Count -eq 0) {
        return
    }

    $payload = [pscustomobject]@{
        Active_System_Mode = [string]$activeMode[0].Name
    }
    $payload | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFilePath -Encoding utf8
}

function Ensure-DashboardStateMemoryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateFilePath
    )

    if (-not (Test-Path -Path $StateFilePath -PathType Leaf)) {
        ([pscustomobject]@{ Active_System_Mode = $null } | ConvertTo-Json -Depth 3) | Set-Content -Path $StateFilePath -Encoding utf8
    }
}

function Normalize-DashboardComplianceRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ComplianceRows,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges
    )

    foreach ($row in @($ComplianceRows)) {
        $component = [string]$row.Component
        $targetState = [string]$row.TargetState

        if ($targetState -eq "ON" -or $targetState -eq "OFF") {
            $row.DesiredState = $targetState
        } else {
            $row.DesiredState = ""
        }

        if ($null -eq $row.PSObject.Properties["ProfileType"]) {
            $row | Add-Member -NotePropertyName ProfileType -NotePropertyValue "Hardware_Override"
        } else {
            $row.ProfileType = "Hardware_Override"
        }
        if ($null -eq $row.PSObject.Properties["Name"]) {
            $row | Add-Member -NotePropertyName Name -NotePropertyValue $component
        } else {
            $row.Name = $component
        }
    }
}

function Get-DashboardTab3RowPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,
        [Parameter(Mandatory = $true)]
        [bool]$IsSelected,
        [hashtable]$PendingHardwareChanges = $null
    )

    $status = "[UNKNOWN]"
    $color = "Gray"
    $physical = if ($null -eq $Row.PhysicalState) { "-" } else { [string]$Row.PhysicalState }
    $desired = [string]$Row.DesiredState
    $target = [string]$Row.TargetState

    if ($null -ne $PendingHardwareChanges -and $PendingHardwareChanges.ContainsKey([string]$Row.Component)) {
        $queued = [string]$PendingHardwareChanges[[string]$Row.Component]
        $status = "[QUEUED: $queued]"
        $color = "Yellow"
    } elseif ($target -eq "ON" -or $target -eq "OFF") {
        $desired = $target
        if ($Row.IsCompliant -eq $true) {
            $status = "✓"
            $color = "Green"
        } elseif ($Row.IsCompliant -eq $false) {
            $status = "[VIOLATION]"
            $color = "Red"
        }
    } elseif ($target -eq "ANY") {
        $desired = ""
        $status = "-"
        $color = "DarkGray"
    }

    return [pscustomobject]@{
        Prefix   = if ($IsSelected) { " > " } else { "   " }
        Physical = $physical
        Desired  = $desired
        Target   = $target
        Status   = $status
        Color    = $color
    }
}

function Add-DashboardIdealHardwareToQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ComplianceData,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges
    )

    foreach ($item in @($ComplianceData)) {
        if ($item.IsCompliant -eq $false -and [string]$item.TargetState -ne "ANY") {
            $PendingHardwareChanges[[string]$item.Component] = [string]$item.TargetState
        }
    }
}

function Toggle-DashboardQueueOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Component,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges
    )

    $next = "ON"
    if ($PendingHardwareChanges.ContainsKey($Component) -and [string]$PendingHardwareChanges[$Component] -eq "ON") {
        $next = "OFF"
    } elseif ($PendingHardwareChanges.ContainsKey($Component) -and [string]$PendingHardwareChanges[$Component] -eq "OFF") {
        $next = "ON"
    }
    $PendingHardwareChanges[$Component] = $next
}

function Clear-DashboardQueueOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Component,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges
    )

    if ($PendingHardwareChanges.ContainsKey($Component)) {
        $PendingHardwareChanges.Remove($Component) | Out-Null
    }
}

function Set-DashboardActiveBlueprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ModeStates,
        [Parameter(Mandatory = $true)]
        [string]$SelectedModeName,
        [Parameter(Mandatory = $true)]
        [string]$StateFilePath
    )

    foreach ($mode in @($ModeStates)) {
        if ([string]$mode.Name -eq $SelectedModeName) {
            $mode.CurrentState = "Active"
            $mode.DesiredState = "Active"
        } else {
            $mode.CurrentState = "Inactive"
            $mode.DesiredState = "Inactive"
        }
    }

    $payload = [pscustomobject]@{
        Active_System_Mode = $SelectedModeName
    }
    $payload | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFilePath -Encoding utf8
}

function Get-DashboardFooterText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$CurrentTab,
        [string]$WorkloadDetailMode = "None"
    )

    if ($CurrentTab -eq 1) {
        return "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Toggle Workload | [``] Details: $WorkloadDetailMode | [Enter] Commit | [Esc] Cancel"
    }
    if ($CurrentTab -eq 2) {
        return "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Set Blueprint | [A] Queue Ideal States | [Enter] Commit | [Esc] Cancel"
    }
    if ($CurrentTab -eq 4) {
        return "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Queue Toggle/Cycle | [Right] Edit | [Left or +/-] Poll Seconds | [Enter] Commit | [Esc] Cancel"
    }
    return "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Toggle Override | [Bksp] Clear Queue | [Enter] Commit | [Esc] Cancel"
}

function Get-NextWorkloadDetailMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentMode
    )

    switch ($CurrentMode) {
        "None" { return "MixedOnly" }
        "MixedOnly" { return "All" }
        "All" { return "None" }
        default { return "None" }
    }
}

function Update-WorkloadDetailModeForKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$CurrentTab,
        [Parameter(Mandatory = $true)]
        [string]$CurrentMode,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($CurrentTab -eq 1 -and $Key -eq "Oem3") {
        $nextMode = Get-NextWorkloadDetailMode -CurrentMode $CurrentMode
        return [pscustomobject]@{
            Mode    = $nextMode
            Changed = $true
        }
    }
    return [pscustomobject]@{
        Mode    = $CurrentMode
        Changed = $false
    }
}

function Should-RenderWorkloadDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DetailMode,
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    switch ($DetailMode) {
        "All" { return $true }
        "MixedOnly" { return ($State -eq "Mixed") }
        default { return $false }
    }
}

function Get-WorkloadDetailLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$WorkloadRow
    )

    $details = $WorkloadRow.PSObject.Properties["RuntimeDetails"]
    if ($null -eq $details -or $null -eq $details.Value) {
        return @()
    }

    $runtime = $details.Value
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($svc in @($runtime.Services)) {
        $svcName = [string]$svc.Name
        if ([string]::IsNullOrWhiteSpace($svcName)) { continue }
        $rows.Add([pscustomobject]@{
            Label = ("svc {0}" -f $svcName)
            IsRunning = ($svc.IsRunning -eq $true)
        })
    }
    foreach ($exe in @($runtime.Executables)) {
        $exeName = [string]$exe.DisplayName
        if ([string]::IsNullOrWhiteSpace($exeName)) {
            $exeName = [string]$exe.Token
        }
        if ([string]::IsNullOrWhiteSpace($exeName)) { continue }
        $rows.Add([pscustomobject]@{
            Label = ("exe {0}" -f $exeName)
            IsRunning = ($exe.IsRunning -eq $true)
        })
    }

    return @($rows)
}

function Get-WorkloadStateText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$State,
        [Parameter(Mandatory = $true)]
        [psobject]$WorkloadRow
    )

    if ($State -ne "Mixed") {
        return $State
    }
    $details = $WorkloadRow.PSObject.Properties["RuntimeDetails"]
    if ($null -eq $details -or $null -eq $details.Value) {
        return $State
    }

    $runtime = $details.Value
    $matchedChecks = if ($null -eq $runtime.PSObject.Properties["MatchedChecks"]) { $null } else { $runtime.MatchedChecks }
    $totalChecks = if ($null -eq $runtime.PSObject.Properties["TotalChecks"]) { $null } else { $runtime.TotalChecks }
    if ($null -eq $matchedChecks -or $null -eq $totalChecks) {
        return $State
    }

    return ("Mixed ({0}/{1})" -f [int]$matchedChecks, [int]$totalChecks)
}

function Get-DashboardPendingCommitStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$WorkloadStates,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges
    )

    $pendingStates = @()
    $pendingStates += @(
        $WorkloadStates |
            Where-Object { $_.DesiredState -ne $_.CurrentState } |
            ForEach-Object {
                [pscustomobject]@{
                    Name         = [string]$_.Name
                    CurrentState = [string]$_.CurrentState
                    DesiredState = [string]$_.DesiredState
                    ProfileType  = [string]$_.ProfileType
                    Action       = if ([string]$_.DesiredState -eq "Active") { "Start" } else { "Stop" }
                }
            }
    )
    foreach ($component in @($PendingHardwareChanges.Keys)) {
        $pendingStates += [pscustomobject]@{
            Name         = [string]$component
            CurrentState = ""
            DesiredState = [string]$PendingHardwareChanges[$component]
            ProfileType  = "Hardware_Override"
            Action       = if ([string]$PendingHardwareChanges[$component] -eq "ON") { "Start" } else { "Stop" }
        }
    }
    return @($pendingStates)
}

function Invoke-DashboardCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$PendingStates,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath,
        [Parameter(Mandatory = $false)]
        [string]$JsonPath = "",
        [Parameter(Mandatory = $false)]
        [psobject]$Workspaces = $null,
        [Parameter(Mandatory = $false)]
        [array]$SettingsRows = @()
    )

    $settingsRowsArray = @($SettingsRows)
    if (-not [string]::IsNullOrWhiteSpace([string]$JsonPath) -and $null -ne $Workspaces -and $settingsRowsArray.Count -gt 0) {
        Save-DashboardConfigSettings -JsonPath $JsonPath -Workspaces $Workspaces -SettingsRows $settingsRowsArray
    }

    if (@($PendingStates).Count -gt 0) {
        Invoke-WorkspaceCommit -UIStates $PendingStates -OrchestratorPath $OrchestratorPath
    } else {
        # Settings-only commit path: run orchestrator once so it can apply config-driven
        # side effects (e.g. interceptor sync/cleanup) and print status.
        try {
            Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName "__SYNC_ONLY__" -Action "Start"
        } catch {
            # Expected when using dummy workspace name; sync still runs before resolution.
            if ([string]$_.Exception.Message -notmatch "Fatal: Workspace '__SYNC_ONLY__' not defined in workspaces\.json\.") {
                throw
            }
        }
    }
    $PendingHardwareChanges.Clear()
}

function Get-DashboardPostCommitMessages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$UIStates,
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    $systemModes = $Workspaces.PSObject.Properties["System_Modes"]
    $hardwareDefs = $Workspaces.PSObject.Properties["Hardware_Definitions"]

    foreach ($state in $UIStates) {
        if ($state.DesiredState -eq $state.CurrentState -or $state.DesiredState -eq "Mixed") {
            continue
        }

        $action = if ($state.DesiredState -eq "Active") { "Start" } else { "Stop" }
        $nameKey = [string]$state.Name
        $nodes = @()

        if ($null -ne $systemModes -and $null -ne $systemModes.Value.PSObject.Properties[$nameKey]) {
            $nodes += $systemModes.Value.PSObject.Properties[$nameKey].Value
        }
        if ($null -ne $hardwareDefs -and $null -ne $hardwareDefs.Value.PSObject.Properties[$nameKey]) {
            $nodes += $hardwareDefs.Value.PSObject.Properties[$nameKey].Value
        }

        foreach ($node in $nodes) {
            $postChange = $node.PSObject.Properties["post_change_message"]
            if ($null -ne $postChange -and $null -ne $postChange.Value) {
                $messages.Add("[$nameKey] $($postChange.Value)")
            }

            $postStart = $node.PSObject.Properties["post_start_message"]
            if ($action -eq "Start" -and $null -ne $postStart -and $null -ne $postStart.Value) {
                $messages.Add("[$nameKey] $($postStart.Value)")
            }

            $postStop = $node.PSObject.Properties["post_stop_message"]
            if ($action -eq "Stop" -and $null -ne $postStop -and $null -ne $postStop.Value) {
                $messages.Add("[$nameKey] $($postStop.Value)")
            }
        }
    }

    return $messages.ToArray()
}

function Invoke-WorkspaceCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$UIStates,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath
    )

    foreach ($state in $UIStates) {
        if ($state.DesiredState -eq $state.CurrentState -or $state.DesiredState -eq "Mixed") {
            continue
        }

        $action = $null
        if ($state.DesiredState -eq "Active" -or $state.DesiredState -eq "ON") {
            $action = "Start"
        } elseif ($state.DesiredState -eq "Inactive" -or $state.DesiredState -eq "OFF") {
            $action = "Stop"
        }

        if ($null -ne $action) {
            Write-Host "--> Orchestrating $($state.Name) to $action..."
            $profileType = if ($null -ne $state.PSObject.Properties["ProfileType"]) { [string]$state.ProfileType } else { "" }
            if ([string]::IsNullOrWhiteSpace($profileType)) {
                Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName $state.Name -Action $action
            } else {
                Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName $state.Name -Action $action -ProfileType $profileType
            }
            Start-Sleep -Seconds 1
        }
    }
}

function Get-FirstTab {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$HasMultipleModes
    )
    return 1
}

function Get-ActiveStateArray {
    param(
        [Parameter(Mandatory = $true)]
        [int]$CurrentTab,
        [Parameter(Mandatory = $true)]
        [array]$WorkloadStates,
        [Parameter(Mandatory = $true)]
        [array]$ModeStates,
        [Parameter(Mandatory = $false)]
        [array]$SettingsStates = @()
    )

    if ($CurrentTab -eq 1) { return ,@($WorkloadStates) }
    if ($CurrentTab -eq 2) { return ,@($ModeStates) }
    if ($CurrentTab -eq 4) { return ,@($SettingsStates) }
    return ,@()
}

function Get-DashboardSettingsDefinitions {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Key = "console_style"; Type = "choice"; Choices = @("Normal", "Compact"); Min = $null; Example = "Example: Normal = full spacing, Compact = tighter output."; Description = "Controls how much spacing/detail the console UI shows." }
        [pscustomobject]@{ Key = "enable_interceptors"; Type = "bool"; Choices = @(); Min = $null; Example = "Example: true = interceptor hooks are managed, false = managed hooks are cleaned."; Description = "Enable or disable executable interceptors managed by WorkspaceManager." }
        [pscustomobject]@{ Key = "notifications"; Type = "bool"; Choices = @(); Min = $null; Example = "Example: true shows `"Workspace Ready`" toast after commits."; Description = "Show Windows toast notifications for dashboard/orchestrator actions." }
        [pscustomobject]@{ Key = "interceptor_poll_max_seconds"; Type = "int"; Choices = @(); Min = 1; Example = "Example: 15 waits up to 15 seconds before timing out."; Description = "Maximum seconds an interceptor waits for required service/process readiness." }
        [pscustomobject]@{ Key = "shortcut_prefix_start"; Type = "string"; Choices = @(); Min = $null; Example = "Example: !Start- creates names like !Start-Office.lnk"; Description = "Prefix used when generating Start shortcut names." }
        [pscustomobject]@{ Key = "shortcut_prefix_stop"; Type = "string"; Choices = @(); Min = $null; Example = "Example: !Stop- creates names like !Stop-Office.lnk"; Description = "Prefix used when generating Stop shortcut names." }
    )
}

function Get-DashboardSettingValueDisplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )

    if ($Row.Type -eq "bool") {
        if ($Row.Value -eq $true) { return "true" }
        return "false"
    }
    return [string]$Row.Value
}

function Test-DashboardSettingsRowPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )

    if ($null -eq $Row.PSObject.Properties["CurrentValue"]) {
        return $false
    }

    if ($Row.Type -eq "bool") {
        return ([bool]$Row.CurrentValue -ne [bool]$Row.Value)
    }

    return ([string]$Row.CurrentValue -ne [string]$Row.Value)
}

function Get-DashboardSettingsRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces
    )

    $defs = Get-DashboardSettingsDefinitions
    $rows = @()
    $config = $Workspaces._config

    foreach ($def in @($defs)) {
        $raw = $null
        if ($null -ne $config -and $null -ne $config.PSObject.Properties[$def.Key]) {
            $raw = $config.PSObject.Properties[$def.Key].Value
        }

        $typed = $raw
        switch ([string]$def.Type) {
            "bool" { $typed = ($raw -eq $true) }
            "int" {
                $num = 0
                if (-not [int]::TryParse([string]$raw, [ref]$num)) { $num = [int]$def.Min }
                if ($def.Min -ne $null -and $num -lt [int]$def.Min) { $num = [int]$def.Min }
                $typed = $num
            }
            "choice" {
                $candidate = [string]$raw
                if ([string]::IsNullOrWhiteSpace($candidate) -or @($def.Choices) -notcontains $candidate) {
                    $candidate = [string]$def.Choices[0]
                }
                $typed = $candidate
            }
            default {
                $typed = [string]$raw
            }
        }

        $rows += [pscustomobject]@{
            Key         = [string]$def.Key
            Type        = [string]$def.Type
            CurrentValue = $typed
            Value       = $typed
            Choices     = @($def.Choices)
            Min         = $def.Min
            Example     = [string]$def.Example
            Description = [string]$def.Description
        }
    }
    return @($rows)
}

function Update-DashboardSettingsIntegerFromInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputText
    )

    if ($Row.Type -ne "int") { return $false }
    if ([string]::IsNullOrWhiteSpace($InputText)) { return $false }

    $parsed = 0
    if (-not [int]::TryParse([string]$InputText, [ref]$parsed)) {
        return $false
    }

    $min = if ($null -eq $Row.Min) { 1 } else { [int]$Row.Min }
    if ($parsed -lt $min) { $parsed = $min }
    $Row.Value = $parsed
    return $true
}

function Save-DashboardConfigSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonPath,
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [array]$SettingsRows
    )

    if ($null -eq $Workspaces.PSObject.Properties["_config"]) {
        $Workspaces | Add-Member -NotePropertyName _config -NotePropertyValue ([pscustomobject]@{})
    }
    foreach ($row in @($SettingsRows)) {
        $key = [string]$row.Key
        $value = $row.Value
        if ($null -eq $Workspaces._config.PSObject.Properties[$key]) {
            $Workspaces._config | Add-Member -NotePropertyName $key -NotePropertyValue $value
        } else {
            $Workspaces._config.PSObject.Properties[$key].Value = $value
        }
        if ($null -ne $row.PSObject.Properties["CurrentValue"]) {
            $row.CurrentValue = $value
        }
    }
    $Workspaces | ConvertTo-Json -Depth 8 | Set-Content -Path $JsonPath -Encoding utf8
}

function Update-DashboardSettingsValueOnSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )

    if ($Row.Type -eq "bool") {
        $Row.Value = (-not [bool]$Row.Value)
        return $true
    }
    if ($Row.Type -eq "choice") {
        $choices = @($Row.Choices)
        if ($choices.Count -eq 0) { return $false }
        $idx = [Array]::IndexOf($choices, [string]$Row.Value)
        if ($idx -lt 0) { $idx = 0 }
        $Row.Value = $choices[(($idx + 1) % $choices.Count)]
        return $true
    }
    return $false
}

function Update-DashboardSettingsNumericValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,
        [Parameter(Mandatory = $true)]
        [int]$Delta
    )
    if ($Row.Type -ne "int") { return $false }
    $next = [int]$Row.Value + $Delta
    $min = if ($null -eq $Row.Min) { 1 } else { [int]$Row.Min }
    if ($next -lt $min) { $next = $min }
    $Row.Value = $next
    return $true
}

function Test-DashboardSettingRequiresNonEmpty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )

    $key = [string]$Row.Key
    return ($key -eq "shortcut_prefix_start" -or $key -eq "shortcut_prefix_stop")
}

function Apply-DashboardSettingEditInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputText
    )

    if ($Row.Type -eq "int") {
        return [pscustomobject]@{
            Applied = (Update-DashboardSettingsIntegerFromInput -Row $Row -InputText $InputText)
            ValidationError = $false
        }
    }

    if ($Row.Type -ne "string") {
        return [pscustomobject]@{
            Applied = $false
            ValidationError = $false
        }
    }

    if (Test-DashboardSettingRequiresNonEmpty -Row $Row) {
        if ([string]::IsNullOrWhiteSpace($InputText)) {
            return [pscustomobject]@{
                Applied = $false
                ValidationError = $true
            }
        }
        $Row.Value = $InputText
        return [pscustomobject]@{
            Applied = $true
            ValidationError = $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($InputText)) {
        $Row.Value = $InputText
        return [pscustomobject]@{
            Applied = $true
            ValidationError = $false
        }
    }

    return [pscustomobject]@{
        Applied = $false
        ValidationError = $false
    }
}

function Read-DashboardLineWithEscCancel {
    [CmdletBinding()]
    param(
        [string]$PromptText = ""
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$PromptText)) {
        Write-Host -NoNewline ("{0}: " -f [string]$PromptText)
    }

    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        if ($keyInfo.Key -eq [ConsoleKey]::Escape) {
            Write-Host ""
            return [pscustomobject]@{ Cancelled = $true; Text = "" }
        }
        if ($keyInfo.Key -eq [ConsoleKey]::Enter) {
            Write-Host ""
            return [pscustomobject]@{ Cancelled = $false; Text = $buffer.ToString() }
        }
        if ($keyInfo.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                [void]$buffer.Remove($buffer.Length - 1, 1)
                Write-Host -NoNewline "`b `b"
            }
            continue
        }
        $char = $keyInfo.KeyChar
        if ([int][char]$char -ge 32) {
            [void]$buffer.Append($char)
            Write-Host -NoNewline $char
        }
    }
}

function Get-DashboardDisplayState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$CurrentTab,
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    if ($CurrentTab -eq 2 -and $State -eq "Inactive") {
        return ""
    }
    return $State
}

function Write-TabHeader {
    param(
        [Parameter(Mandatory = $true)]
        [int]$CurrentTab,
        [Parameter(Mandatory = $true)]
        [bool]$HasMultipleModes
    )

    $tabs = @(
        [pscustomobject]@{ Id = 1; Label = "App Workloads" }
    )
    if ($HasMultipleModes) {
        $tabs += [pscustomobject]@{ Id = 2; Label = "System Modes" }
        $tabs += [pscustomobject]@{ Id = 3; Label = "Hardware Compliance" }
    } else {
        $tabs += [pscustomobject]@{ Id = 3; Label = "System Health" }
    }
    $tabs += [pscustomobject]@{ Id = 4; Label = "Settings" }

    foreach ($tab in $tabs) {
        $text = "[{0}] {1}  " -f $tab.Id, $tab.Label
        if ($CurrentTab -eq $tab.Id) {
            Write-Host -NoNewline $text -ForegroundColor Cyan
        } else {
            Write-Host -NoNewline $text
        }
    }
    Write-Host ""
}

function Get-SafeConsoleWidth {
    [CmdletBinding()]
    param()

    try {
        $w = [Console]::WindowWidth
        if ($w -gt 0) { return $w }
    } catch {
        # Ignore and continue to fallback.
    }

    try {
        $bw = [Console]::BufferWidth
        if ($bw -gt 0) { return $bw }
    } catch {
        # Ignore and continue to hard fallback.
    }

    return 120
}

function Invoke-SafeClearHost {
    [CmdletBinding()]
    param()

    try {
        Clear-Host
    } catch {
        # Non-interactive host can throw "The handle is invalid."
    }
}

function Start-DashboardAutoCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$WorkloadStates,
        [Parameter(Mandatory = $true)]
        [string]$WorkloadName,
        [Parameter(Mandatory = $true)]
        [string]$StateFilePath,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath,
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces
    )

    $selected = @($WorkloadStates | Where-Object { [string]$_.Name -eq $WorkloadName } | Select-Object -First 1)
    if ($selected.Count -eq 0) {
        throw "Fatal: App workload '$WorkloadName' was not found."
    }

    $selected[0].DesiredState = "Active"

    Invoke-SafeClearHost
    Write-Host "=== WORKSPACEMANAGER DASHBOARD ==="
    Write-Host ""
    Write-Host ("Auto-enabling workload: {0}" -f $WorkloadName) -ForegroundColor Cyan
    Write-Host "Committing state changes..."

    Save-DashboardStateMemory -ModeStates $script:ModeStates -StateFilePath $StateFilePath
    $pendingStates = Get-DashboardPendingCommitStates -WorkloadStates $WorkloadStates -PendingHardwareChanges $script:PendingHardwareChanges
    Invoke-DashboardCommit -PendingStates $pendingStates -PendingHardwareChanges $script:PendingHardwareChanges -OrchestratorPath $OrchestratorPath -JsonPath $jsonPath -Workspaces $workspaces -SettingsRows $script:SettingsStates

    $pendingMessages = @(Get-DashboardPostCommitMessages -UIStates $pendingStates -Workspaces $Workspaces)
    if ($pendingMessages.Count -gt 0) {
        Write-Host ""
        Write-Host "=== REQUIRED ACTIONS ===" -ForegroundColor Yellow
        foreach ($msg in $pendingMessages) {
            Write-Host $msg -ForegroundColor Cyan
        }
    }

    Write-Host ""
    Write-Host "[ SUCCESS ] Workspaces updated."
    Write-Host ("Waiting briefly for '{0}' to settle..." -f $WorkloadName) -ForegroundColor DarkGray
    Start-Sleep -Seconds 8
}

function Start-Dashboard {
    param(
        [string]$AutoCommitWorkloadName,
        [string]$ObserveWorkloadName,
        [int]$ObserveSeconds = 10
    )

    $jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
    if (-not (Test-Path -Path $jsonPath -PathType Leaf)) {
        throw "Fatal: workspaces.json not found."
    }

    $workspaces = Get-Content -Path $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
    $stateFilePath = Join-Path -Path $PSScriptRoot -ChildPath "state.json"
    Ensure-DashboardStateMemoryFile -StateFilePath $stateFilePath

    if (-not [string]::IsNullOrWhiteSpace($ObserveWorkloadName)) {
        $globalPnpCache = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds([int]$ObserveSeconds)
        while ((Get-Date) -lt $deadline) {
            $stateEngine = Get-WorkspaceState -Workspace $workspaces -PnpCache $globalPnpCache
            $workloadResults = $stateEngine.AppWorkloads
            $row = $workloadResults.PSObject.Properties[$ObserveWorkloadName]
            if ($null -ne $row) {
                $status = [string]$row.Value.Status
                $details = $row.Value.RuntimeDetails
                $svcMatch = @($details.Services | Where-Object { $_.IsRunning -eq $true }).Count
                $exeMatch = @($details.Executables | Where-Object { $_.IsRunning -eq $true }).Count
                Write-Host ("[Observe] {0}: {1} (services running={2}, executables running={3})" -f $ObserveWorkloadName, $status, $svcMatch, $exeMatch) -ForegroundColor DarkGray
            } else {
                Write-Host ("[Observe] {0}: not found in workspaces.json" -f $ObserveWorkloadName) -ForegroundColor Yellow
            }
            Start-Sleep -Seconds 1
        }
        exit
    }

    Write-Host "Scanning hardware devices..." -ForegroundColor DarkGray
    $globalPnpCache = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue

    $stateEngine = Get-WorkspaceState -Workspace $workspaces -PnpCache $globalPnpCache
    $script:ComplianceData = @($stateEngine.Compliance)
    Normalize-DashboardComplianceRows -ComplianceRows $script:ComplianceData -PendingHardwareChanges $script:PendingHardwareChanges

    $workloadResults = $stateEngine.AppWorkloads
    $modeResults = $stateEngine.SystemModes
    $workloadsNode = $workspaces.PSObject.Properties["App_Workloads"]
    $modesNode = $workspaces.PSObject.Properties["System_Modes"]

    $script:WorkloadStates = @()
    if ($null -ne $workloadResults) {
        foreach ($prop in $workloadResults.PSObject.Properties) {
            $desc = ""
            if ($null -ne $workloadsNode -and $null -ne $workloadsNode.Value.PSObject.Properties[$prop.Name]) {
                $wlData = $workloadsNode.Value.PSObject.Properties[$prop.Name].Value
                if ($null -ne $wlData.PSObject.Properties["description"]) {
                    $desc = [string]$wlData.description
                }
            }
            $curr = [string]$prop.Value.Status
            $script:WorkloadStates += [pscustomobject]@{
                Name         = $prop.Name
                CurrentState = $curr
                DesiredState = $curr
                Description  = $desc
                RuntimeDetails = $prop.Value.RuntimeDetails
                ProfileType  = "App_Workload"
            }
        }
    }

    $script:ModeStates = @()
    if ($null -ne $modeResults) {
        foreach ($prop in $modeResults.PSObject.Properties) {
            $desc = ""
            if ($null -ne $modesNode -and $null -ne $modesNode.Value.PSObject.Properties[$prop.Name]) {
                $modeData = $modesNode.Value.PSObject.Properties[$prop.Name].Value
                if ($null -ne $modeData.PSObject.Properties["description"]) {
                    $desc = [string]$modeData.description
                }
            }
            $curr = [string]$prop.Value.Status
            $script:ModeStates += [pscustomobject]@{
                Name         = $prop.Name
                CurrentState = $curr
                DesiredState = $curr
                Description  = $desc
                ProfileType  = "System_Mode"
            }
        }
    }

    $script:HasMultipleModes = ($script:ModeStates.Count -gt 1)
    $script:SettingsStates = Get-DashboardSettingsRows -Workspaces $workspaces

    if ($script:WorkloadStates.Count -eq 0 -and $script:ModeStates.Count -eq 0) {
        Write-Host "No profiles found in workspaces.json."
        exit
    }

    if (-not [string]::IsNullOrWhiteSpace($AutoCommitWorkloadName)) {
        $OrchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"
        Start-DashboardAutoCommit -WorkloadStates $script:WorkloadStates -WorkloadName $AutoCommitWorkloadName -StateFilePath $stateFilePath -OrchestratorPath $OrchestratorPath -Workspaces $workspaces
        exit
    }

    $CurrentTab = Get-FirstTab -HasMultipleModes $script:HasMultipleModes
    $workloadDetailMode = "None"
    $cursorIndex = 0
    $isRendering = $true
    $needsRedraw = $true
    $abortDueToInputUnavailable = $false
    $nameColumnWidth = 42
    $descLineWidth = [Math]::Max(20, (Get-SafeConsoleWidth) - 4)

    while ($isRendering) {
        $activeStates = if ($CurrentTab -eq 3) { @($script:ComplianceData) } else { Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates -SettingsStates $script:SettingsStates }
        if (@($activeStates).Count -eq 0) {
            $cursorIndex = 0
        } elseif ($cursorIndex -ge @($activeStates).Count) {
            $cursorIndex = 0
        }

        if ($needsRedraw) {
            Invoke-SafeClearHost
            Write-Host "=== WORKSPACEMANAGER DASHBOARD ==="
            Write-Host " "
            Write-TabHeader -CurrentTab $CurrentTab -HasMultipleModes $script:HasMultipleModes
            Write-Host ""

            if ($CurrentTab -eq 1 -or $CurrentTab -eq 2) {
                $title = if ($CurrentTab -eq 1) { "App Workloads" } else { "System Modes" }
                Write-Host ("   {0}" -f $title).PadRight($nameColumnWidth)
                Write-Host "------------------------------------------+-------------------------"
                if (@($activeStates).Count -eq 0) {
                    Write-Host "   (No items available)" -ForegroundColor DarkGray
                }

                for ($i = 0; $i -lt @($activeStates).Count; $i++) {
                    $state = $activeStates[$i]
                    $prefix = if ($i -eq $cursorIndex) { " > " } else { "   " }
                    $paddedName = $state.Name.PadRight($nameColumnWidth - 3)
                    Write-Host -NoNewline $prefix
                    Write-Host -NoNewline $paddedName -ForegroundColor Cyan
                    Write-Host -NoNewline "|  "
                    $displayCurrentState = Get-DashboardDisplayState -CurrentTab $CurrentTab -State ([string]$state.CurrentState)
                    $displayDesiredState = Get-DashboardDisplayState -CurrentTab $CurrentTab -State ([string]$state.DesiredState)
                    $workloadCurrentText = $displayCurrentState
                    $workloadDesiredText = $displayDesiredState
                    if ($CurrentTab -eq 1) {
                        $workloadCurrentText = Get-WorkloadStateText -State $displayCurrentState -WorkloadRow $state
                        $workloadDesiredText = Get-WorkloadStateText -State $displayDesiredState -WorkloadRow $state
                    }
                    if ($displayCurrentState -eq $displayDesiredState) {
                        Write-StateText -State $workloadCurrentText
                    } else {
                        $currentText = $workloadCurrentText
                        Write-StateText -State $currentText
                        $currentPadCount = 10 - $currentText.Length
                        if ($currentPadCount -gt 0) { Write-Host -NoNewline (" " * $currentPadCount) }
                        Write-Host -NoNewline "->  "
                        Write-StateText -State $workloadDesiredText
                    }
                    Write-Host ""

                    if ($CurrentTab -eq 1 -and (Should-RenderWorkloadDetails -DetailMode $workloadDetailMode -State ([string]$state.CurrentState))) {
                        $detailRows = @(Get-WorkloadDetailLines -WorkloadRow $state)
                        foreach ($detail in $detailRows) {
                            $detailLabel = ("     {0}" -f [string]$detail.Label).PadRight($nameColumnWidth)
                            Write-Host -NoNewline $detailLabel -ForegroundColor DarkGray
                            Write-Host -NoNewline "|  "
                            if ($detail.IsRunning -eq $true) {
                                Write-Host "+" -ForegroundColor Green
                            } else {
                                Write-Host "-" -ForegroundColor DarkGray
                            }
                        }
                    }
                }

                Write-Host ""
                if (@($activeStates).Count -gt 0) {
                    $selected = $activeStates[$cursorIndex]
                    $desc = [string]$selected.Description
                    if ([string]::IsNullOrWhiteSpace($desc)) {
                        $desc = ""
                    }
                    $descLine = ("  " + $desc).PadRight($descLineWidth)
                    Write-Host $descLine.Substring(0, [Math]::Min($descLine.Length, $descLineWidth)) -ForegroundColor Cyan
                } else {
                    Write-Host ("").PadRight($descLineWidth)
                }
                Write-Host ""
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab -WorkloadDetailMode $workloadDetailMode) -ForegroundColor Gray
            } elseif ($CurrentTab -eq 3) {
                Write-Host "Component                      | Physical | Desired | Status"
                Write-Host "-------------------------------+----------+---------+------------"
                for ($i = 0; $i -lt @($script:ComplianceData).Count; $i++) {
                    $row = $script:ComplianceData[$i]
                    $view = Get-DashboardTab3RowPresentation -Row $row -IsSelected ($i -eq $cursorIndex) -PendingHardwareChanges $script:PendingHardwareChanges
                    $component = [string]$row.Component
                    $line = "{0}{1,-30} | {2,-8} | {3,-7} | {4}" -f $view.Prefix, $component, $view.Physical, $view.Desired, $view.Status
                    Write-Host $line -ForegroundColor $view.Color
                }
                Write-Host ""
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab -WorkloadDetailMode $workloadDetailMode) -ForegroundColor Gray
            } else {
                Write-Host ("   {0}" -f "Settings").PadRight($nameColumnWidth)
                Write-Host "------------------------------------------+-------------------------"
                if (@($script:SettingsStates).Count -eq 0) {
                    Write-Host "   (No items available)" -ForegroundColor DarkGray
                }
                for ($i = 0; $i -lt @($script:SettingsStates).Count; $i++) {
                    $row = $script:SettingsStates[$i]
                    $prefix = if ($i -eq $cursorIndex) { " > " } else { "   " }
                    $pendingMarker = if (Test-DashboardSettingsRowPending -Row $row) { "*" } else { " " }
                    $settingName = ("{0}{1}" -f $pendingMarker, [string]$row.Key)
                    $paddedName = $settingName.PadRight($nameColumnWidth - 3)
                    $currentText = [string]$row.CurrentValue
                    $desiredText = Get-DashboardSettingValueDisplay -Row $row
                    Write-Host -NoNewline $prefix
                    Write-Host -NoNewline $paddedName -ForegroundColor Cyan
                    Write-Host -NoNewline "|  "
                    if (Test-DashboardSettingsRowPending -Row $row) {
                        Write-Host -NoNewline $currentText -ForegroundColor DarkYellow
                        $currentPadCount = 10 - $currentText.Length
                        if ($currentPadCount -gt 0) { Write-Host -NoNewline (" " * $currentPadCount) }
                        Write-Host -NoNewline "->  "
                        Write-Host $desiredText -ForegroundColor Yellow
                    } else {
                        Write-Host $desiredText -ForegroundColor Yellow
                    }
                }
                Write-Host ""
                if (@($script:SettingsStates).Count -gt 0) {
                    $selectedSetting = $script:SettingsStates[$cursorIndex]
                    $descText = "  {0}  {1}" -f [string]$selectedSetting.Description, [string]$selectedSetting.Example
                    Write-Host ($descText).PadRight($descLineWidth) -ForegroundColor Cyan
                } else {
                    Write-Host ("").PadRight($descLineWidth)
                }
                Write-Host ""
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab -WorkloadDetailMode $workloadDetailMode) -ForegroundColor Gray
            }

            $needsRedraw = $false
        }

        $keyAvailable = $false
        try {
            $keyAvailable = [Console]::KeyAvailable
        } catch {
            Write-Host "Keyboard input is not available in this host. Run Dashboard.ps1 in an interactive console." -ForegroundColor Yellow
            $abortDueToInputUnavailable = $true
            $isRendering = $false
            break
        }

        if ($keyAvailable) {
            try {
                $key = [Console]::ReadKey($true).Key
            } catch {
                Write-Host "Input error: $($_.Exception.Message)" -ForegroundColor Red
                break
            }

            switch ($key) {
                "D1" { $CurrentTab = 1; $cursorIndex = 0; $needsRedraw = $true; continue }
                "NumPad1" { $CurrentTab = 1; $cursorIndex = 0; $needsRedraw = $true; continue }
                "D2" {
                    if ($script:HasMultipleModes) {
                        $CurrentTab = 2; $cursorIndex = 0; $needsRedraw = $true
                    }
                    continue
                }
                "NumPad2" {
                    if ($script:HasMultipleModes) {
                        $CurrentTab = 2; $cursorIndex = 0; $needsRedraw = $true
                    }
                    continue
                }
                "D3" { $CurrentTab = 3; $cursorIndex = 0; $needsRedraw = $true; continue }
                "NumPad3" { $CurrentTab = 3; $cursorIndex = 0; $needsRedraw = $true; continue }
                "D4" { $CurrentTab = 4; $cursorIndex = 0; $needsRedraw = $true; continue }
                "NumPad4" { $CurrentTab = 4; $cursorIndex = 0; $needsRedraw = $true; continue }
                "UpArrow" {
                    if (($CurrentTab -eq 1 -or $CurrentTab -eq 2 -or $CurrentTab -eq 3 -or $CurrentTab -eq 4) -and $cursorIndex -gt 0) { $cursorIndex-- }
                }
                "DownArrow" {
                    if ($CurrentTab -eq 1 -or $CurrentTab -eq 2 -or $CurrentTab -eq 3 -or $CurrentTab -eq 4) {
                        $active = Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates -SettingsStates $script:SettingsStates
                        if ($CurrentTab -eq 3) { $active = @($script:ComplianceData) }
                        if ($cursorIndex -lt (@($active).Count - 1)) { $cursorIndex++ }
                    }
                }
                "Spacebar" {
                    if ($CurrentTab -eq 1 -or $CurrentTab -eq 2) {
                        if ($CurrentTab -eq 1) {
                            $active = Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates
                            if (@($active).Count -gt 0) {
                                $selected = $active[$cursorIndex]
                                $selected.DesiredState = Update-DashboardDesiredStateOnSpace `
                                    -CurrentState ([string]$selected.CurrentState) `
                                    -DesiredState ([string]$selected.DesiredState)
                            }
                        } elseif ($CurrentTab -eq 2) {
                            $active = @($script:ModeStates)
                            if (@($active).Count -gt 0) {
                                $selected = $active[$cursorIndex]
                                Set-DashboardActiveBlueprint -ModeStates $script:ModeStates -SelectedModeName ([string]$selected.Name) -StateFilePath $stateFilePath
                                $stateEngine = Get-WorkspaceState -Workspace $workspaces -PnpCache $globalPnpCache
                                $script:ComplianceData = @($stateEngine.Compliance)
                                Normalize-DashboardComplianceRows -ComplianceRows $script:ComplianceData -PendingHardwareChanges $script:PendingHardwareChanges
                            }
                        }
                    } elseif ($CurrentTab -eq 3) {
                        if (@($script:ComplianceData).Count -gt 0) {
                            $selected = $script:ComplianceData[$cursorIndex]
                            Toggle-DashboardQueueOverride -Component ([string]$selected.Component) -PendingHardwareChanges $script:PendingHardwareChanges
                            Normalize-DashboardComplianceRows -ComplianceRows $script:ComplianceData -PendingHardwareChanges $script:PendingHardwareChanges
                        }
                    } elseif ($CurrentTab -eq 4) {
                        if (@($script:SettingsStates).Count -gt 0) {
                            $selected = $script:SettingsStates[$cursorIndex]
                            [void](Update-DashboardSettingsValueOnSpace -Row $selected)
                        }
                    }
                }
                "LeftArrow" {
                    if ($CurrentTab -eq 4 -and @($script:SettingsStates).Count -gt 0) {
                        $selected = $script:SettingsStates[$cursorIndex]
                        [void](Update-DashboardSettingsNumericValue -Row $selected -Delta -1)
                    }
                }
                "RightArrow" {
                    if ($CurrentTab -eq 4 -and @($script:SettingsStates).Count -gt 0) {
                        $selected = $script:SettingsStates[$cursorIndex]
                        if ($selected.Type -eq "string" -or $selected.Type -eq "int") {
                            try {
                                Invoke-SafeClearHost
                                Write-Host "=== WORKSPACEMANAGER SETTINGS ==="
                                Write-Host ""
                                Write-Host ("Editing: {0}" -f [string]$selected.Key) -ForegroundColor Cyan
                                Write-Host ([string]$selected.Description) -ForegroundColor DarkGray
                                Write-Host ([string]$selected.Example) -ForegroundColor DarkGray
                                Write-Host ("Current value: {0}" -f (Get-DashboardSettingValueDisplay -Row $selected)) -ForegroundColor Yellow
                                Write-Host "Enter = accept, Esc = cancel." -ForegroundColor DarkGray
                                $nextInput = Read-DashboardLineWithEscCancel -PromptText "New value"
                                if (-not [bool]$nextInput.Cancelled) {
                                    $nextValue = [string]$nextInput.Text
                                    $editResult = Apply-DashboardSettingEditInput -Row $selected -InputText $nextValue
                                    if ([bool]$editResult.ValidationError) {
                                        Write-Host "This setting cannot be empty. Press Esc to cancel." -ForegroundColor Yellow
                                        [void](Read-DashboardLineWithEscCancel -PromptText "")
                                    }
                                }
                            } catch {
                                # Keep dashboard responsive if prompt host is unavailable.
                            }
                        }
                    }
                }
                "Add" {
                    if ($CurrentTab -eq 4 -and @($script:SettingsStates).Count -gt 0) {
                        $selected = $script:SettingsStates[$cursorIndex]
                        [void](Update-DashboardSettingsNumericValue -Row $selected -Delta 1)
                    }
                }
                "Subtract" {
                    if ($CurrentTab -eq 4 -and @($script:SettingsStates).Count -gt 0) {
                        $selected = $script:SettingsStates[$cursorIndex]
                        [void](Update-DashboardSettingsNumericValue -Row $selected -Delta -1)
                    }
                }
                "Oem3" {
                    $detailUpdate = Update-WorkloadDetailModeForKey -CurrentTab $CurrentTab -CurrentMode $workloadDetailMode -Key "Oem3"
                    $workloadDetailMode = [string]$detailUpdate.Mode
                }
                "A" {
                    if ($CurrentTab -eq 2) {
                        Add-DashboardIdealHardwareToQueue -ComplianceData $script:ComplianceData -PendingHardwareChanges $script:PendingHardwareChanges
                    }
                }
                "Backspace" {
                    if ($CurrentTab -eq 3 -and @($script:ComplianceData).Count -gt 0) {
                        $selected = $script:ComplianceData[$cursorIndex]
                        Clear-DashboardQueueOverride -Component ([string]$selected.Component) -PendingHardwareChanges $script:PendingHardwareChanges
                        Normalize-DashboardComplianceRows -ComplianceRows $script:ComplianceData -PendingHardwareChanges $script:PendingHardwareChanges
                    }
                }
                "Escape" {
                    Invoke-SafeClearHost
                    Write-Host "Cancelled."
                    exit
                }
                "Enter" {
                    $isRendering = $false
                    break
                }
            }
            $needsRedraw = $true
        } else {
            Start-Sleep -Milliseconds 50
        }
    }

    if ($abortDueToInputUnavailable) {
        exit 1
    }

    Invoke-SafeClearHost
    Write-Host "Committing state changes..."
    $OrchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"
    Save-DashboardStateMemory -ModeStates $script:ModeStates -StateFilePath $stateFilePath

    $pendingStates = @(Get-DashboardPendingCommitStates -WorkloadStates $script:WorkloadStates -PendingHardwareChanges $script:PendingHardwareChanges)
    Invoke-DashboardCommit -PendingStates $pendingStates -PendingHardwareChanges $script:PendingHardwareChanges -OrchestratorPath $OrchestratorPath -JsonPath $jsonPath -Workspaces $workspaces -SettingsRows $script:SettingsStates

    $pendingMessages = @(Get-DashboardPostCommitMessages -UIStates @($pendingStates) -Workspaces $workspaces)
    if ($pendingMessages.Count -gt 0) {
        Write-Host ""
        Write-Host "=== REQUIRED ACTIONS ===" -ForegroundColor Yellow
        foreach ($msg in $pendingMessages) {
            Write-Host $msg -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "Press any key to exit..." -ForegroundColor White
        [Console]::ReadKey($true) | Out-Null
        exit
    }

    Write-Host "[ SUCCESS ] Workspaces updated."
    Start-Sleep -Seconds 2
    exit
}

if ($MyInvocation.InvocationName -ne ".") {
    Start-Dashboard -AutoCommitWorkloadName $AutoCommitWorkloadName -ObserveWorkloadName $ObserveWorkloadName -ObserveSeconds $ObserveSeconds
}
