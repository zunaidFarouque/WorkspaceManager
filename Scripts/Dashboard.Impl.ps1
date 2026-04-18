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
$script:ActionStates = @()
$script:HasMultipleModes = $false
$script:PendingHardwareChanges = @{}
$script:WorkloadFilterState = [pscustomobject]@{
    Query         = ""
    Domain        = ""
    FavoritesOnly = $false
    MixedOnly     = $false
}

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
        [string]$ProfileType,
        [switch]$SkipInterceptorSync
    )

    if ([string]::IsNullOrWhiteSpace($ProfileType)) {
        if ($SkipInterceptorSync.IsPresent) {
            & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action -SkipInterceptorSync
        } else {
            & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action
        }
    } else {
        if ($SkipInterceptorSync.IsPresent) {
            & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action -ProfileType $ProfileType -SkipInterceptorSync
        } else {
            & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action -ProfileType $ProfileType
        }
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
        [string]$WorkloadDetailMode = "None",
        [string]$CommitMode = "Exit"
    )

    $commitModeHint = ("[R] {0}" -f (Get-DashboardCommitModeText -CommitMode $CommitMode))
    $commitAction = if ($CommitMode -eq "Return") { "Return" } else { "Exit" }

    if ($CurrentTab -eq 1) {
        $domainText = "All"
        if (-not [string]::IsNullOrWhiteSpace([string]$script:WorkloadFilterState.Domain)) {
            $domainText = [string]$script:WorkloadFilterState.Domain
        }
        $favoriteText = "Off"
        if ($script:WorkloadFilterState.FavoritesOnly) {
            $favoriteText = "On"
        }
        $mixedText = "Off"
        if ($script:WorkloadFilterState.MixedOnly) {
            $mixedText = "On"
        }
        $filterText = "[``]Details: {0} | [M]ixed={1} | [/]Filters: q='{2}' | [G]roup='{3}' | [F]avourites={4}" -f `
            $WorkloadDetailMode, `
            $mixedText, `
            [string]$script:WorkloadFilterState.Query, `
            $domainText, `
            $favoriteText
        return "$filterText`n[1][2][3][4] Tab | [Up/Down] Nav | [Space] Toggle | [R] CommitMode`n[Enter] Commit & $commitAction | [Esc] Cancel"
    }
    if ($CurrentTab -eq 2) {
        return "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Set Blueprint | [A] Queue Ideal States | [Enter] Commit | $commitModeHint | [Esc] Cancel"
    }
    if ($CurrentTab -eq 4) {
        return "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Edit Setting | [Right] Edit | [Left or +/-] Poll Seconds | [Enter] Commit/Confirm Action | Actions are exclusive | $commitModeHint | [Esc] Cancel"
    }
    return "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Toggle Override | [Bksp] Clear Queue | [Enter] Commit | $commitModeHint | [Esc] Cancel"
}

function Get-DashboardCommitModeDefault {
    [CmdletBinding()]
    param()
    return "Exit"
}

function Toggle-DashboardCommitMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentMode
    )

    if ($CurrentMode -eq "Exit") {
        return "Return"
    }
    return "Exit"
}

function Get-DashboardCommitModeText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommitMode
    )

    $normalized = if ($CommitMode -eq "Return") { "Return" } else { "Exit" }
    return ("CommitMode: {0}" -f $normalized)
}

function Resolve-DashboardPostCommitAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommitMode,
        [Parameter(Mandatory = $true)]
        [bool]$HasPostCommitMessages,
        [Parameter(Mandatory = $false)]
        [scriptblock]$ReadKeyScript = $null
    )

    if ($CommitMode -ne "Return") {
        if ($HasPostCommitMessages) {
            Write-Host ""
            Write-Host "Press any key to exit..." -ForegroundColor White
            if ($null -ne $ReadKeyScript) {
                [void](& $ReadKeyScript)
            } else {
                [Console]::ReadKey($true) | Out-Null
            }
        }
        return "Exit"
    }

    Write-Host ""
    Write-Host "Press any key to return to dashboard. Press Esc to exit." -ForegroundColor White
    $keyInfo = if ($null -ne $ReadKeyScript) { & $ReadKeyScript } else { [Console]::ReadKey($true) }
    if ($null -ne $keyInfo -and $keyInfo.Key -eq [ConsoleKey]::Escape) {
        return "Exit"
    }
    return "ReturnToDashboard"
}

function Invoke-DashboardCommitFlow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$WorkloadStates,
        [Parameter(Mandatory = $true)]
        [array]$ModeStates,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath,
        [Parameter(Mandatory = $true)]
        [string]$StateFilePath,
        [Parameter(Mandatory = $true)]
        [string]$JsonPath,
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$SettingsRows,
        [Parameter(Mandatory = $true)]
        [string]$CommitMode,
        [Parameter(Mandatory = $false)]
        [scriptblock]$ReadKeyScript = $null
    )

    Invoke-SafeClearHost
    Write-Host "Committing state changes..."

    Save-DashboardStateMemory -ModeStates $ModeStates -StateFilePath $StateFilePath
    $pendingStates = @(Get-DashboardPendingCommitStates -WorkloadStates $WorkloadStates -PendingHardwareChanges $PendingHardwareChanges)
    Invoke-DashboardCommit -PendingStates $pendingStates -PendingHardwareChanges $PendingHardwareChanges -OrchestratorPath $OrchestratorPath -JsonPath $JsonPath -Workspaces $Workspaces -SettingsRows $SettingsRows

    $pendingMessages = @(Get-DashboardPostCommitMessages -UIStates @($pendingStates) -Workspaces $Workspaces)
    if ($pendingMessages.Count -gt 0) {
        Write-Host ""
        Write-Host "=== REQUIRED ACTIONS ===" -ForegroundColor Yellow
        foreach ($msg in $pendingMessages) {
            Write-Host $msg -ForegroundColor Cyan
        }
    } else {
        Write-Host "[ SUCCESS ] Workspaces updated."
    }

    return (Resolve-DashboardPostCommitAction -CommitMode $CommitMode -HasPostCommitMessages ($pendingMessages.Count -gt 0) -ReadKeyScript $ReadKeyScript)
}

function Test-WorkloadMatchesQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,
        [AllowEmptyString()]
        [string]$Query
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return $true
    }

    $needle = [string]$Query
    if ([string]$Row.Name -like "*$needle*") { return $true }
    if ([string]$Row.Domain -like "*$needle*") { return $true }
    foreach ($tag in @($Row.Tags)) {
        if ([string]$tag -like "*$needle*") { return $true }
    }
    foreach ($alias in @($Row.Aliases)) {
        if ([string]$alias -like "*$needle*") { return $true }
    }
    return $false
}

function Get-FilteredWorkloadStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$WorkloadStates,
        [Parameter(Mandatory = $true)]
        [psobject]$FilterState
    )

    return @(
        $WorkloadStates |
            Where-Object {
                if ($_.Hidden -eq $true -and [string]::IsNullOrWhiteSpace([string]$FilterState.Query)) { return $false }
                if (-not [string]::IsNullOrWhiteSpace([string]$FilterState.Domain) -and [string]$_.Domain -ne [string]$FilterState.Domain) { return $false }
                if ($FilterState.FavoritesOnly -and $_.Favorite -ne $true) { return $false }
                if ($FilterState.MixedOnly -and [string]$_.CurrentState -ne "Mixed") { return $false }
                if (-not (Test-WorkloadMatchesQuery -Row $_ -Query ([string]$FilterState.Query))) { return $false }
                return $true
            } |
            Sort-Object -Property `
                @{ Expression = { [int]$_.Priority }; Ascending = $true }, `
                @{ Expression = { [string]$_.Name }; Ascending = $true }
    )
}

function Get-WorkloadDomains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$WorkloadStates
    )

    return @(
        $WorkloadStates |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Domain) } |
            Select-Object -ExpandProperty Domain -Unique |
            Sort-Object
    )
}

function Update-WorkloadDomainFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$WorkloadStates,
        [Parameter(Mandatory = $true)]
        [psobject]$FilterState
    )

    $domains = @("") + @(Get-WorkloadDomains -WorkloadStates $WorkloadStates)
    $current = [string]$FilterState.Domain
    $idx = [array]::IndexOf($domains, $current)
    if ($idx -lt 0) { $idx = 0 }
    $next = ($idx + 1) % [Math]::Max($domains.Count, 1)
    $FilterState.Domain = [string]$domains[$next]
}

function Get-ViewportRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$TotalCount,
        [Parameter(Mandatory = $true)]
        [int]$CursorIndex,
        [Parameter(Mandatory = $true)]
        [int]$WindowSize
    )

    if ($TotalCount -le 0) {
        return [pscustomobject]@{ Start = 0; End = -1 }
    }
    $safeWindow = [Math]::Max(1, $WindowSize)
    if ($TotalCount -le $safeWindow) {
        return [pscustomobject]@{ Start = 0; End = ($TotalCount - 1) }
    }

    $half = [Math]::Floor($safeWindow / 2)
    $start = [Math]::Max(0, $CursorIndex - $half)
    $end = $start + $safeWindow - 1
    if ($end -ge $TotalCount) {
        $end = $TotalCount - 1
        $start = [Math]::Max(0, $end - $safeWindow + 1)
    }
    return [pscustomobject]@{ Start = $start; End = $end }
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

    # Perform one sync pass per commit, then suppress per-item resync calls.
    try {
        Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName "__SYNC_ONLY__" -Action "Start"
    } catch {
        # Expected when using dummy workspace name; sync still runs before resolution.
        if ([string]$_.Exception.Message -notmatch "Fatal: Workspace '__SYNC_ONLY__' not defined in workspaces\.json\.") {
            throw
        }
    }

    if (@($PendingStates).Count -gt 0) {
        Invoke-WorkspaceCommit -UIStates $PendingStates -OrchestratorPath $OrchestratorPath -SkipInterceptorSync
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
        [string]$OrchestratorPath,
        [switch]$SkipInterceptorSync
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
                Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName $state.Name -Action $action -SkipInterceptorSync:$SkipInterceptorSync.IsPresent
            } else {
                Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName $state.Name -Action $action -ProfileType $profileType -SkipInterceptorSync:$SkipInterceptorSync.IsPresent
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
        [array]$SettingsStates = @(),
        [Parameter(Mandatory = $false)]
        [array]$ActionStates = @()
    )

    if ($CurrentTab -eq 1) { return ,@(Get-FilteredWorkloadStates -WorkloadStates $WorkloadStates -FilterState $script:WorkloadFilterState) }
    if ($CurrentTab -eq 2) { return ,@($ModeStates) }
    if ($CurrentTab -eq 4) { return ,@(Get-DashboardTab4Rows -SettingsRows $SettingsStates -ActionRows $ActionStates) }
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
        [pscustomobject]@{ Key = "disable_startup_logo"; Type = "bool"; Choices = @(); Min = $null; Example = "Example: true skips the ASCII banner once before the hardware scan."; Description = "When true, skips the ASCII logo printed once before the PnP hardware scan at dashboard startup (Tab 4 can persist this in workspaces.json)." }
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

function Get-DashboardActionDefinitions {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{
            Key         = "Reset_Interceptors"
            ActionId    = "Reset_Interceptors"
            Description = "Resets managed IFEO hooks, disables interceptors, and stops interceptor helper polling processes."
            Example     = "Use when interception is stuck or looping."
        }
    )
}

function Get-DashboardActionRows {
    [CmdletBinding()]
    param()

    $rows = @()
    foreach ($def in @(Get-DashboardActionDefinitions)) {
        $rows += [pscustomobject]@{
            Key         = [string]$def.Key
            ActionId    = [string]$def.ActionId
            Type        = "action"
            Description = [string]$def.Description
            Example     = [string]$def.Example
        }
    }
    return @($rows)
}

function Get-DashboardTab4Rows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$SettingsRows,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$ActionRows
    )

    $rows = @()
    foreach ($setting in @($SettingsRows)) {
        $rows += $setting
    }

    if (@($ActionRows).Count -gt 0) {
        $rows += [pscustomobject]@{
            Type        = "section"
            Label       = "-------- Actions --------"
            Description = "One-time actions run exclusively and are not part of normal batch commit."
            Example     = "Press Enter once to confirm, then Enter again to run."
        }
        foreach ($action in @($ActionRows)) {
            $rows += $action
        }
    }

    return @($rows)
}

function Test-DashboardTab4RowIsAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )
    return ([string]$Row.Type -eq "action" -and -not [string]::IsNullOrWhiteSpace([string]$Row.ActionId))
}

function Test-DashboardTab4RowIsSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )
    return ([string]$Row.Type -eq "section")
}

function Test-DashboardTab4RowIsSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )
    return (-not (Test-DashboardTab4RowIsAction -Row $Row) -and -not (Test-DashboardTab4RowIsSection -Row $Row))
}

function Get-DashboardTab4RowValueDisplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,
        [AllowEmptyString()]
        [string]$PendingActionConfirmId = ""
    )

    if (Test-DashboardTab4RowIsSection -Row $Row) {
        return ""
    }
    if (Test-DashboardTab4RowIsAction -Row $Row) {
        if ([string]$PendingActionConfirmId -eq [string]$Row.ActionId) {
            return "Confirm: Enter"
        }
        return "Run"
    }
    return (Get-DashboardSettingValueDisplay -Row $Row)
}

function Test-DashboardHasPendingSettingsChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$SettingsRows
    )

    foreach ($row in @($SettingsRows)) {
        if (Test-DashboardSettingsRowPending -Row $row) {
            return $true
        }
    }
    return $false
}

function Resolve-DashboardActionEnterDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,
        [AllowEmptyString()]
        [string]$PendingActionConfirmId = "",
        [Parameter(Mandatory = $true)]
        [array]$SettingsRows
    )

    if (-not (Test-DashboardTab4RowIsAction -Row $Row)) {
        return [pscustomobject]@{
            Decision            = "Commit"
            NextPendingActionId = ""
            Message             = ""
        }
    }

    if (Test-DashboardHasPendingSettingsChanges -SettingsRows $SettingsRows) {
        return [pscustomobject]@{
            Decision            = "BlockedByPendingSettings"
            NextPendingActionId = ""
            Message             = "Action requires exclusive run. Commit or clear pending settings first."
        }
    }

    if ([string]$PendingActionConfirmId -eq [string]$Row.ActionId) {
        return [pscustomobject]@{
            Decision            = "ExecuteAction"
            NextPendingActionId = ""
            Message             = ""
        }
    }

    return [pscustomobject]@{
        Decision            = "ArmAction"
        NextPendingActionId = [string]$Row.ActionId
        Message             = "Press Enter again to run."
    }
}

function Invoke-DashboardActionById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActionId,
        [Parameter(Mandatory = $true)]
        [array]$SettingsRows,
        [Parameter(Mandatory = $true)]
        [string]$JsonPath,
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath
    )

    switch ($ActionId) {
        "Reset_Interceptors" {
            $result = Invoke-DashboardGlobalInterceptorReset `
                -SettingsRows $SettingsRows `
                -JsonPath $JsonPath `
                -Workspaces $Workspaces `
                -PendingHardwareChanges $PendingHardwareChanges `
                -OrchestratorPath $OrchestratorPath
            return [pscustomobject]@{
                Success = $true
                Message = ("Interceptors reset. Killed {0} helper process(es)." -f [int]$result.KilledProcessCount)
                Result  = $result
            }
        }
        default {
            throw "Fatal: Unknown dashboard action '$ActionId'."
        }
    }
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

function Get-DashboardSettingsRowByKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$SettingsRows,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    return @($SettingsRows | Where-Object { [string]$_.Key -eq $Key } | Select-Object -First 1)
}

function Stop-DashboardInterceptorHelperProcesses {
    [CmdletBinding()]
    param()

    $killedCount = 0
    $scan = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    foreach ($proc in $scan) {
        $name = [string]$proc.Name
        if ($name -ne "pwsh.exe" -and $name -ne "powershell.exe") { continue }
        $cmdLine = ""
        if ($null -ne $proc.PSObject.Properties["CommandLine"] -and $null -ne $proc.CommandLine) {
            $cmdLine = [string]$proc.CommandLine
        }
        if ([string]::IsNullOrWhiteSpace($cmdLine)) { continue }
        if ($cmdLine -notmatch "(?i)Interceptor(Poll)?\.ps1") { continue }
        try {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
            $killedCount++
        } catch {
            # Best effort cleanup only.
        }
    }

    return $killedCount
}

function Invoke-DashboardGlobalInterceptorReset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$SettingsRows,
        [Parameter(Mandatory = $true)]
        [string]$JsonPath,
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingHardwareChanges,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath
    )

    $enableRows = @(Get-DashboardSettingsRowByKey -SettingsRows $SettingsRows -Key "enable_interceptors")
    if ($enableRows.Count -eq 0) {
        throw "Fatal: Dashboard settings row 'enable_interceptors' was not found."
    }

    $row = $enableRows[0]
    $row.Value = $false
    if ($null -ne $row.PSObject.Properties["CurrentValue"]) {
        $row.CurrentValue = $false
    }

    Invoke-DashboardCommit `
        -PendingStates @() `
        -PendingHardwareChanges $PendingHardwareChanges `
        -OrchestratorPath $OrchestratorPath `
        -JsonPath $JsonPath `
        -Workspaces $Workspaces `
        -SettingsRows $SettingsRows

    $killedCount = Stop-DashboardInterceptorHelperProcesses
    return [pscustomobject]@{
        DisabledInterceptors = $true
        KilledProcessCount   = [int]$killedCount
    }
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

function Get-SafeConsoleHeight {
    [CmdletBinding()]
    param()

    try {
        $h = [Console]::WindowHeight
        if ($h -gt 0) { return $h }
    } catch {
    }

    try {
        $bh = [Console]::BufferHeight
        if ($bh -gt 0) { return $bh }
    } catch {
    }

    return 40
}

function Format-WorkloadDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$WorkloadRow
    )

    $name = [string]$WorkloadRow.Name
    $domain = ""
    if ($null -ne $WorkloadRow.PSObject.Properties["Domain"]) {
        $domain = [string]$WorkloadRow.Domain
    }

    if ([string]::IsNullOrWhiteSpace($domain)) {
        return $name
    }

    $group = $domain
    if ($group.Length -gt 8) {
        $group = $group.Substring(0, 8)
    } else {
        $group = $group.PadRight(8)
    }

    return ("[{0}] {1}" -f $group, $name)
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

function Update-DashboardRuntimeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [array]$PnpCache
    )

    $stateEngine = Get-WorkspaceState -Workspace $Workspaces -PnpCache $PnpCache
    $script:ComplianceData = @($stateEngine.Compliance)
    Normalize-DashboardComplianceRows -ComplianceRows $script:ComplianceData -PendingHardwareChanges $script:PendingHardwareChanges

    $workloadResults = $stateEngine.AppWorkloads
    $modeResults = $stateEngine.SystemModes
    $workloadsNode = $Workspaces.PSObject.Properties["App_Workloads"]
    $modesNode = $Workspaces.PSObject.Properties["System_Modes"]

    $script:WorkloadStates = @()
    if ($null -ne $workloadResults) {
        foreach ($prop in $workloadResults.PSObject.Properties) {
            $desc = ""
            $domain = ""
            $tags = @()
            $priority = 9999
            $favorite = $false
            $hidden = $false
            $aliases = @()
            if ($null -ne $prop.Value.PSObject.Properties["Domain"]) {
                $domain = [string]$prop.Value.Domain
            }
            if ($null -ne $prop.Value.PSObject.Properties["Tags"]) {
                $tags = @($prop.Value.Tags | ForEach-Object { [string]$_ })
            }
            if ($null -ne $prop.Value.PSObject.Properties["Priority"]) {
                $priority = [int]$prop.Value.Priority
            }
            if ($null -ne $prop.Value.PSObject.Properties["Favorite"]) {
                $favorite = ($prop.Value.Favorite -eq $true)
            }
            if ($null -ne $prop.Value.PSObject.Properties["Hidden"]) {
                $hidden = ($prop.Value.Hidden -eq $true)
            }
            if ($null -ne $prop.Value.PSObject.Properties["Aliases"]) {
                $aliases = @($prop.Value.Aliases | ForEach-Object { [string]$_ })
            }
            if ($null -ne $workloadsNode) {
                foreach ($domainProp in @($workloadsNode.Value.PSObject.Properties)) {
                    if ($null -eq $domainProp.Value) { continue }
                    if ($null -eq $domainProp.Value.PSObject.Properties[$prop.Name]) { continue }
                    $wlData = $domainProp.Value.PSObject.Properties[$prop.Name].Value
                    if ($null -ne $wlData.PSObject.Properties["description"]) {
                        $desc = [string]$wlData.description
                    }
                    break
                }
            }
            $curr = [string]$prop.Value.Status
            $script:WorkloadStates += [pscustomobject]@{
                Name           = $prop.Name
                CurrentState   = $curr
                DesiredState   = $curr
                Description    = $desc
                Domain         = $domain
                Tags           = @($tags)
                Priority       = $priority
                Favorite       = $favorite
                Hidden         = $hidden
                Aliases        = @($aliases)
                RuntimeDetails = $prop.Value.RuntimeDetails
                ProfileType    = "App_Workload"
            }
        }
    }
    $script:WorkloadStates = @(
        $script:WorkloadStates |
            Sort-Object -Property `
                @{ Expression = { [int]$_.Priority }; Ascending = $true }, `
                @{ Expression = { [string]$_.Name }; Ascending = $true }
    )

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
    $script:SettingsStates = Get-DashboardSettingsRows -Workspaces $Workspaces
    $script:ActionStates = Get-DashboardActionRows
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

function Write-DashboardAsciiLogo {
    $relative = Join-Path -Path $PSScriptRoot -ChildPath "..\Assets\ASCII_logo.txt"
    $logoPath = [System.IO.Path]::GetFullPath($relative)
    if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf)) {
        return
    }
    foreach ($line in Get-Content -LiteralPath $logoPath -Encoding utf8) {
        Write-Host $line
    }
    Write-Host ""
}

function Test-DashboardStartupLogoDisabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces
    )

    if ($null -eq $Workspaces.PSObject.Properties["_config"]) {
        return $false
    }
    $config = $Workspaces._config
    if ($null -eq $config -or $null -eq $config.PSObject.Properties["disable_startup_logo"]) {
        return $false
    }
    return $config.disable_startup_logo -eq $true
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

    if (-not (Test-DashboardStartupLogoDisabled -Workspaces $workspaces)) {
        Write-DashboardAsciiLogo
    }
    Write-Host "Scanning hardware devices..." -ForegroundColor DarkGray
    $globalPnpCache = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
    Update-DashboardRuntimeState -Workspaces $workspaces -PnpCache $globalPnpCache

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
    $commitMode = Get-DashboardCommitModeDefault
    $nameColumnWidth = 42
    $descLineWidth = [Math]::Max(20, (Get-SafeConsoleWidth) - 4)

    while ($true) {
        $isRendering = $true
        $needsRedraw = $true
        $abortDueToInputUnavailable = $false
        $commitRequested = $false
        $pendingActionConfirmId = ""

        while ($isRendering) {
        $activeStates = if ($CurrentTab -eq 3) { @($script:ComplianceData) } else { Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates -SettingsStates $script:SettingsStates -ActionStates $script:ActionStates }
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

                $windowStart = 0
                $windowEnd = @($activeStates).Count - 1
                if ($CurrentTab -eq 1) {
                    $windowSize = [Math]::Max(5, (Get-SafeConsoleHeight) - 14)
                    $viewport = Get-ViewportRange -TotalCount @($activeStates).Count -CursorIndex $cursorIndex -WindowSize $windowSize
                    $windowStart = [int]$viewport.Start
                    $windowEnd = [int]$viewport.End
                }

                for ($i = $windowStart; $i -le $windowEnd; $i++) {
                    if ($i -lt 0 -or $i -ge @($activeStates).Count) { continue }
                    $state = $activeStates[$i]
                    $prefix = if ($i -eq $cursorIndex) { " > " } else { "   " }
                    $displayName = if ($CurrentTab -eq 1) { Format-WorkloadDisplayName -WorkloadRow $state } else { [string]$state.Name }
                    $paddedName = $displayName.PadRight($nameColumnWidth - 3)
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
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab -WorkloadDetailMode $workloadDetailMode -CommitMode $commitMode) -ForegroundColor Gray
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
                if (@($script:ComplianceData).Count -gt 0) {
                    $selected = $script:ComplianceData[$cursorIndex]
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
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab -WorkloadDetailMode $workloadDetailMode -CommitMode $commitMode) -ForegroundColor Gray
            } else {
                Write-Host ("   {0}" -f "Settings").PadRight($nameColumnWidth)
                Write-Host "------------------------------------------+-------------------------"
                if (@($activeStates).Count -eq 0) {
                    Write-Host "   (No items available)" -ForegroundColor DarkGray
                }
                for ($i = 0; $i -lt @($activeStates).Count; $i++) {
                    $row = $activeStates[$i]
                    if (Test-DashboardTab4RowIsSection -Row $row) {
                        Write-Host ("   {0}" -f [string]$row.Label) -ForegroundColor DarkGray
                        continue
                    }
                    $prefix = if ($i -eq $cursorIndex) { " > " } else { "   " }
                    $pendingMarker = " "
                    if (Test-DashboardTab4RowIsSetting -Row $row) {
                        $pendingMarker = if (Test-DashboardSettingsRowPending -Row $row) { "*" } else { " " }
                    }
                    $settingName = ("{0}{1}" -f $pendingMarker, [string]$row.Key)
                    $paddedName = $settingName.PadRight($nameColumnWidth - 3)
                    $currentText = if (Test-DashboardTab4RowIsSetting -Row $row) { [string]$row.CurrentValue } else { "" }
                    $desiredText = Get-DashboardTab4RowValueDisplay -Row $row -PendingActionConfirmId $pendingActionConfirmId
                    Write-Host -NoNewline $prefix
                    $nameColor = if (Test-DashboardTab4RowIsAction -Row $row) { "Magenta" } else { "Cyan" }
                    Write-Host -NoNewline $paddedName -ForegroundColor $nameColor
                    Write-Host -NoNewline "|  "
                    if ((Test-DashboardTab4RowIsSetting -Row $row) -and (Test-DashboardSettingsRowPending -Row $row)) {
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
                if (@($activeStates).Count -gt 0) {
                    $selectedSetting = $activeStates[$cursorIndex]
                    $descText = "  {0}  {1}" -f [string]$selectedSetting.Description, [string]$selectedSetting.Example
                    Write-Host ($descText).PadRight($descLineWidth) -ForegroundColor Cyan
                } else {
                    Write-Host ("").PadRight($descLineWidth)
                }
                Write-Host ""
                Write-Host (Get-DashboardFooterText -CurrentTab $CurrentTab -WorkloadDetailMode $workloadDetailMode -CommitMode $commitMode) -ForegroundColor Gray
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
                "D1" { $CurrentTab = 1; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true; continue }
                "NumPad1" { $CurrentTab = 1; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true; continue }
                "D2" {
                    if ($script:HasMultipleModes) {
                        $CurrentTab = 2; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true
                    }
                    continue
                }
                "NumPad2" {
                    if ($script:HasMultipleModes) {
                        $CurrentTab = 2; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true
                    }
                    continue
                }
                "D3" { $CurrentTab = 3; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true; continue }
                "NumPad3" { $CurrentTab = 3; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true; continue }
                "D4" { $CurrentTab = 4; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true; continue }
                "NumPad4" { $CurrentTab = 4; $cursorIndex = 0; $pendingActionConfirmId = ""; $needsRedraw = $true; continue }
                "UpArrow" {
                    if (($CurrentTab -eq 1 -or $CurrentTab -eq 2 -or $CurrentTab -eq 3 -or $CurrentTab -eq 4) -and $cursorIndex -gt 0) { $cursorIndex-- }
                    $pendingActionConfirmId = ""
                }
                "DownArrow" {
                    if ($CurrentTab -eq 1 -or $CurrentTab -eq 2 -or $CurrentTab -eq 3 -or $CurrentTab -eq 4) {
                        $active = Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates -SettingsStates $script:SettingsStates -ActionStates $script:ActionStates
                        if ($CurrentTab -eq 3) { $active = @($script:ComplianceData) }
                        if ($cursorIndex -lt (@($active).Count - 1)) { $cursorIndex++ }
                    }
                    $pendingActionConfirmId = ""
                }
                "Spacebar" {
                    if ($CurrentTab -eq 1 -or $CurrentTab -eq 2) {
                        if ($CurrentTab -eq 1) {
                            $active = Get-ActiveStateArray -CurrentTab $CurrentTab -WorkloadStates $script:WorkloadStates -ModeStates $script:ModeStates -SettingsStates $script:SettingsStates -ActionStates $script:ActionStates
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
                        if (@($activeStates).Count -gt 0) {
                            $selected = $activeStates[$cursorIndex]
                            if (Test-DashboardTab4RowIsSetting -Row $selected) {
                                [void](Update-DashboardSettingsValueOnSpace -Row $selected)
                            }
                            $pendingActionConfirmId = ""
                        }
                    }
                }
                "LeftArrow" {
                    if ($CurrentTab -eq 4 -and @($activeStates).Count -gt 0) {
                        $selected = $activeStates[$cursorIndex]
                        if (Test-DashboardTab4RowIsSetting -Row $selected) {
                            [void](Update-DashboardSettingsNumericValue -Row $selected -Delta -1)
                        }
                        $pendingActionConfirmId = ""
                    }
                }
                "RightArrow" {
                    if ($CurrentTab -eq 4 -and @($activeStates).Count -gt 0) {
                        $selected = $activeStates[$cursorIndex]
                        if ((Test-DashboardTab4RowIsSetting -Row $selected) -and ($selected.Type -eq "string" -or $selected.Type -eq "int")) {
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
                        $pendingActionConfirmId = ""
                    }
                }
                "Add" {
                    if ($CurrentTab -eq 4 -and @($activeStates).Count -gt 0) {
                        $selected = $activeStates[$cursorIndex]
                        if (Test-DashboardTab4RowIsSetting -Row $selected) {
                            [void](Update-DashboardSettingsNumericValue -Row $selected -Delta 1)
                        }
                        $pendingActionConfirmId = ""
                    }
                }
                "Subtract" {
                    if ($CurrentTab -eq 4 -and @($activeStates).Count -gt 0) {
                        $selected = $activeStates[$cursorIndex]
                        if (Test-DashboardTab4RowIsSetting -Row $selected) {
                            [void](Update-DashboardSettingsNumericValue -Row $selected -Delta -1)
                        }
                        $pendingActionConfirmId = ""
                    }
                }
                "Oem3" {
                    $detailUpdate = Update-WorkloadDetailModeForKey -CurrentTab $CurrentTab -CurrentMode $workloadDetailMode -Key "Oem3"
                    $workloadDetailMode = [string]$detailUpdate.Mode
                }
                "Oem2" {
                    if ($CurrentTab -eq 1) {
                        try {
                            Invoke-SafeClearHost
                            Write-Host "=== WORKSPACEMANAGER WORKLOAD SEARCH ==="
                            Write-Host ""
                            Write-Host "Filter by workload name, domain, alias, or tag." -ForegroundColor DarkGray
                            Write-Host "Enter = apply, Esc = cancel." -ForegroundColor DarkGray
                            $searchInput = Read-DashboardLineWithEscCancel -PromptText "Search"
                            if (-not [bool]$searchInput.Cancelled) {
                                $script:WorkloadFilterState.Query = [string]$searchInput.Text
                                $cursorIndex = 0
                            }
                        } catch {
                            # host may not support raw input in some contexts
                        }
                    }
                }
                "G" {
                    if ($CurrentTab -eq 1) {
                        Update-WorkloadDomainFilter -WorkloadStates $script:WorkloadStates -FilterState $script:WorkloadFilterState
                        $cursorIndex = 0
                    }
                }
                "F" {
                    if ($CurrentTab -eq 1) {
                        $script:WorkloadFilterState.FavoritesOnly = -not [bool]$script:WorkloadFilterState.FavoritesOnly
                        $cursorIndex = 0
                    }
                }
                "M" {
                    if ($CurrentTab -eq 1) {
                        $script:WorkloadFilterState.MixedOnly = -not [bool]$script:WorkloadFilterState.MixedOnly
                        $cursorIndex = 0
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
                "R" {
                    $commitMode = Toggle-DashboardCommitMode -CurrentMode $commitMode
                }
                "Escape" {
                    Invoke-SafeClearHost
                    Write-Host "Cancelled."
                    exit
                }
                "Enter" {
                    if ($CurrentTab -eq 4 -and @($activeStates).Count -gt 0) {
                        $selected = $activeStates[$cursorIndex]
                        if (Test-DashboardTab4RowIsAction -Row $selected) {
                            $decision = Resolve-DashboardActionEnterDecision -Row $selected -PendingActionConfirmId $pendingActionConfirmId -SettingsRows $script:SettingsStates
                            if ($decision.Decision -eq "ArmAction") {
                                $pendingActionConfirmId = [string]$decision.NextPendingActionId
                                $needsRedraw = $true
                                continue
                            }
                            if ($decision.Decision -eq "BlockedByPendingSettings") {
                                Invoke-SafeClearHost
                                Write-Host "=== WORKSPACEMANAGER ACTION BLOCKED ==="
                                Write-Host ""
                                Write-Host $decision.Message -ForegroundColor Yellow
                                Write-Host ""
                                Write-Host "Press any key to continue..." -ForegroundColor DarkGray
                                [Console]::ReadKey($true) | Out-Null
                                $pendingActionConfirmId = ""
                                $needsRedraw = $true
                                continue
                            }
                            if ($decision.Decision -eq "ExecuteAction") {
                                $orchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"
                                Invoke-SafeClearHost
                                Write-Host "=== WORKSPACEMANAGER ACTION ==="
                                Write-Host ""
                                Write-Host ("Running action: {0}" -f [string]$selected.Key) -ForegroundColor Cyan
                                try {
                                    $actionResult = Invoke-DashboardActionById `
                                        -ActionId ([string]$selected.ActionId) `
                                        -SettingsRows $script:SettingsStates `
                                        -JsonPath $jsonPath `
                                        -Workspaces $workspaces `
                                        -PendingHardwareChanges $script:PendingHardwareChanges `
                                        -OrchestratorPath $orchestratorPath
                                    Write-Host ("[ SUCCESS ] {0}" -f [string]$actionResult.Message) -ForegroundColor Green
                                } catch {
                                    Write-Host ("[ ERROR ] {0}" -f $_.Exception.Message) -ForegroundColor Red
                                }
                                Write-Host ""
                                Write-Host "Reloading dashboard state..." -ForegroundColor DarkGray
                                $pendingActionConfirmId = ""
                                $workspaces = Get-Content -Path $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
                                Update-DashboardRuntimeState -Workspaces $workspaces -PnpCache $globalPnpCache
                                $cursorIndex = 0
                                $needsRedraw = $true
                                continue
                            }
                        }
                    }
                    $commitRequested = $true
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

        if (-not $commitRequested) {
            continue
        }

        $OrchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"
        $postCommitAction = Invoke-DashboardCommitFlow `
            -WorkloadStates $script:WorkloadStates `
            -ModeStates $script:ModeStates `
            -PendingHardwareChanges $script:PendingHardwareChanges `
            -OrchestratorPath $OrchestratorPath `
            -StateFilePath $stateFilePath `
            -JsonPath $jsonPath `
            -Workspaces $workspaces `
            -SettingsRows $script:SettingsStates `
            -CommitMode $commitMode

        if ($postCommitAction -eq "Exit") {
            exit
        }

        $workspaces = Get-Content -Path $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        Update-DashboardRuntimeState -Workspaces $workspaces -PnpCache $globalPnpCache
        if ($script:WorkloadStates.Count -eq 0 -and $script:ModeStates.Count -eq 0) {
            Write-Host "No profiles found in workspaces.json."
            exit
        }
        if (-not $script:HasMultipleModes -and $CurrentTab -eq 2) {
            $CurrentTab = 1
        }
        if ($CurrentTab -lt 1 -or $CurrentTab -gt 4) {
            $CurrentTab = Get-FirstTab -HasMultipleModes $script:HasMultipleModes
        }
        $cursorIndex = 0
    }
}

$dashboardShouldAutoStart = ($MyInvocation.InvocationName -ne ".")
if (-not $dashboardShouldAutoStart) {
    $bootstrapVar = Get-Variable -Name WorkspaceManagerDashboardEntryBootstrap -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $bootstrapVar -and [bool]$bootstrapVar.Value) {
        $dashboardShouldAutoStart = $true
    }
}

if ($dashboardShouldAutoStart) {
    Start-Dashboard -AutoCommitWorkloadName $AutoCommitWorkloadName -ObserveWorkloadName $ObserveWorkloadName -ObserveSeconds $ObserveSeconds
}
