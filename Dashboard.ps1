Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Host.UI.RawUI.WindowTitle = "WorkspaceManager Dashboard"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path -Path $PSScriptRoot -ChildPath "WorkspaceState.ps1")

$script:ComplianceData = @()
$script:WorkloadStates = @()
$script:ModeStates = @()
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

    $color = switch ($State) {
        "Inactive" { "Green" }
        "Active" { "Red" }
        "Mixed" { "Yellow" }
        default { "Gray" }
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

        if ($PendingHardwareChanges.ContainsKey($component)) {
            $row.DesiredState = [string]$PendingHardwareChanges[$component]
        } elseif ($targetState -eq "ON" -or $targetState -eq "OFF") {
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
        $desired = $queued
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
        [int]$CurrentTab
    )

    if ($CurrentTab -eq 1) {
        return "[1][2][3] Tab | [Up/Down] Nav | [Space] Toggle Workload | [Enter] Commit | [Esc] Cancel"
    }
    if ($CurrentTab -eq 2) {
        return "[1][2][3] Tab | [Up/Down] Nav | [Space] Set Blueprint | [A] Queue Ideal States | [Enter] Commit | [Esc] Cancel"
    }
    return "[1][2][3] Tab | [Up/Down] Nav | [Space] Toggle Override | [Bksp] Clear Queue | [Enter] Commit | [Esc] Cancel"
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
        [string]$OrchestratorPath
    )

    if (@($PendingStates).Count -gt 0) {
        Invoke-WorkspaceCommit -UIStates $PendingStates -OrchestratorPath $OrchestratorPath
    }
    $PendingHardwareChanges.Clear()
}

function Get-DashboardPostCommitMessages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
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
        [array]$ModeStates
    )

    if ($CurrentTab -eq 1) { return ,@($WorkloadStates) }
    if ($CurrentTab -eq 2) { return ,@($ModeStates) }
    return ,@()
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

function Start-Dashboard {
    $jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
    if (-not (Test-Path -Path $jsonPath -PathType Leaf)) {
        throw "Fatal: workspaces.json not found."
    }

    $workspaces = Get-Content -Path $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
    $stateFilePath = Join-Path -Path $PSScriptRoot -ChildPath "state.json"
    Ensure-DashboardStateMemoryFile -StateFilePath $stateFilePath
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

    if ($script:WorkloadStates.Count -eq 0 -and $script:ModeStates.Count -eq 0) {
        Write-Host "No profiles found in workspaces.json."
        exit
    }

    $CurrentTab = Get-FirstTab -HasMultipleModes $script:HasMultipleModes
    $cursorIndex = 0
    $isRendering = $true
    $needsRedraw = $true
    $abortDueToInputUnavailable = $false
    $nameColumnWidth = 42
    $descLineWidth = [Math]::Max(20, (Get-SafeConsoleWidth) - 4)

    while ($isRendering) {
        $activeStates = if ($CurrentTab -eq 3) { @($script:ComplianceData) } else { Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates }
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
                    if ($displayCurrentState -eq $displayDesiredState) {
                        Write-StateText -State $displayCurrentState
                    } else {
                        $currentText = $displayCurrentState
                        Write-StateText -State $currentText
                        $currentPadCount = 10 - $currentText.Length
                        if ($currentPadCount -gt 0) { Write-Host -NoNewline (" " * $currentPadCount) }
                        Write-Host -NoNewline "->  "
                        Write-StateText -State $displayDesiredState
                    }
                    Write-Host ""
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
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab) -ForegroundColor Gray
            } else {
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
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab) -ForegroundColor Gray
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
                "UpArrow" {
                    if (($CurrentTab -eq 1 -or $CurrentTab -eq 2 -or $CurrentTab -eq 3) -and $cursorIndex -gt 0) { $cursorIndex-- }
                }
                "DownArrow" {
                    if ($CurrentTab -eq 1 -or $CurrentTab -eq 2 -or $CurrentTab -eq 3) {
                        $active = Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates
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
                    }
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

    $pendingStates = Get-DashboardPendingCommitStates -WorkloadStates $script:WorkloadStates -PendingHardwareChanges $script:PendingHardwareChanges
    Invoke-DashboardCommit -PendingStates $pendingStates -PendingHardwareChanges $script:PendingHardwareChanges -OrchestratorPath $OrchestratorPath

    $pendingMessages = @(Get-DashboardPostCommitMessages -UIStates $pendingStates -Workspaces $workspaces)
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
    Start-Dashboard
}
