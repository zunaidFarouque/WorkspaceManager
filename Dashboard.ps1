Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Host.UI.RawUI.WindowTitle = "WorkspaceManager Dashboard"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path -Path $PSScriptRoot -ChildPath "WorkspaceState.ps1")

function Invoke-WorkspaceCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$UIStates,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath
    )

    foreach ($state in $UIStates) {
        if ($state.Type -eq "oneshot") {
            if ($state.DesiredState -eq "Run") {
                Write-Host "--> Orchestrating $($state.Name) to Start..."
                Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName $state.Name -Action "Start"
                Start-Sleep -Seconds 1
            }
            continue
        }

        if ($state.DesiredState -ne $state.CurrentState -and $state.DesiredState -ne "Mixed") {
            $action = $null
            if ($state.DesiredState -eq "Ready") {
                $action = "Start"
            } elseif ($state.DesiredState -eq "Stopped") {
                $action = "Stop"
            }

            if ($null -ne $action) {
                Write-Host "--> Orchestrating $($state.Name) to $action..."
                Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName $state.Name -Action $action
                Start-Sleep -Seconds 1
            }
        }
    }
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
        [string]$Action
    )

    & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action
}

function Write-ColoredStateText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    $stateKey = $State.Trim()
    $color = switch ($stateKey) {
        "Ready" { "Red" }
        "Stopped" { "Green" }
        "Mixed" { "Yellow" }
        default { "Gray" }
    }

    Write-Host -NoNewline $State -ForegroundColor $color
}

function Update-DashboardDesiredStateOnSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$CurrentState,
        [Parameter(Mandatory = $true)]
        [string]$DesiredState
    )

    if ($Type -eq "oneshot") {
        if ($DesiredState -eq "Run") { return "Idle" }
        return "Run"
    }

    if ($CurrentState -eq "Mixed") {
        if ($DesiredState -eq "Ready") { return "Stopped" }
        return "Ready"
    }

    if ($DesiredState -eq "Ready") { return "Stopped" }
    return "Ready"
}

function Clear-DashboardDesiredState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$CurrentState
    )

    if ($Type -eq "oneshot") {
        return "Idle"
    }
    return $CurrentState
}

function Get-ActionableArrayProperties {
    @(
        "services",
        "executables",
        "scripts_start",
        "scripts_stop",
        "pnp_devices_enable",
        "pnp_devices_disable",
        "reverse_relations",
        "protected_processes"
    )
}

function Toggle-IgnoredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -match '^#') {
        return $Value.Substring(1)
    }
    return "#$Value"
}

function New-WorkspaceEditorItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$WorkspaceData
    )

    $items = @()
    foreach ($propertyName in Get-ActionableArrayProperties) {
        $property = $WorkspaceData.PSObject.Properties[$propertyName]
        if ($null -eq $property) { continue }
        $values = @($property.Value)
        for ($idx = 0; $idx -lt $values.Count; $idx++) {
            $value = [string]$values[$idx]
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $items += [pscustomobject]@{
                Property = $propertyName
                Index    = $idx
                Value    = $value
            }
        }
    }
    return $items
}

function Set-WorkspaceEditorSelectionIgnored {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,
        [Parameter(Mandatory = $true)]
        [psobject]$EditorSelection,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    $workspaceNode = $Workspaces.PSObject.Properties[$WorkspaceName]
    if ($null -eq $workspaceNode) {
        throw "Workspace '$WorkspaceName' not found in loaded configuration."
    }
    $workspaceData = $workspaceNode.Value
    $propertyName = [string]$EditorSelection.Property
    $propertyNode = $workspaceData.PSObject.Properties[$propertyName]
    if ($null -eq $propertyNode) {
        throw "Property '$propertyName' not found in workspace '$WorkspaceName'."
    }

    $values = @($propertyNode.Value)
    $targetIndex = [int]$EditorSelection.Index
    if ($targetIndex -lt 0 -or $targetIndex -ge $values.Count) {
        throw "Editor index out of range for property '$propertyName'."
    }

    $newValue = Toggle-IgnoredValue -Value ([string]$values[$targetIndex])
    $values[$targetIndex] = $newValue
    $workspaceData.$propertyName = @($values)
    $EditorSelection.Value = $newValue
    $Workspaces | ConvertTo-Json -Depth 10 | Set-Content -Path $WorkspacePath
}

function Get-WorkspaceDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$WorkspaceData,
        [array]$PnpCache = @(),
        [Parameter(Mandatory = $true)]
        [bool]$ShowIgnored
    )

    $details = @()

    $servicesProperty = $WorkspaceData.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        foreach ($s in @($servicesProperty.Value)) {
            $serviceName = [string]$s
            if ([string]::IsNullOrWhiteSpace($serviceName) -or $serviceName -match '^t\s+(\d+)$') { continue }
            if ($serviceName -match '^#') {
                if ($ShowIgnored) {
                    $label = if ($serviceName.Length -gt 1) { $serviceName.Substring(1) } else { $serviceName }
                    $details += [pscustomobject]@{ Type = "[Svc]"; Name = "[Ignored] $label"; IsRunning = $false }
                }
                continue
            }
            if ($serviceName.StartsWith("?")) { $serviceName = $serviceName.Substring(1) }
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            $details += [pscustomobject]@{ Type = "[Svc]"; Name = $serviceName; IsRunning = ($null -ne $service -and $service.Status -eq "Running") }
        }
    }

    $executablesProperty = $WorkspaceData.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        foreach ($exeToken in @($executablesProperty.Value)) {
            $exeText = [string]$exeToken
            if ([string]::IsNullOrWhiteSpace($exeText) -or $exeText -match '^t\s+(\d+)$') { continue }
            if ($exeText -match '^#') {
                if ($ShowIgnored) {
                    $label = if ($exeText.Length -gt 1) { $exeText.Substring(1) } else { $exeText }
                    $details += [pscustomobject]@{ Type = "[Exe]"; Name = "[Ignored] $label"; IsRunning = $false }
                }
                continue
            }
            $filePath = $exeText
            if ($exeText -match "^'(.*?)'\s*(.*)$") { $filePath = $matches[1] }
            if ($filePath.StartsWith("?")) { $filePath = $filePath.Substring(1) }
            $leafName = Split-Path -Path $filePath -Leaf
            $cleanName = $leafName -replace "\.exe$", ""
            $proc = Get-Process -Name $cleanName -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                $details += [pscustomobject]@{ Type = "[Exe]"; Name = "$cleanName.exe"; IsRunning = $true }
            }
        }
    }

    $pnpEnableProperty = $WorkspaceData.PSObject.Properties["pnp_devices_enable"]
    if ($null -ne $pnpEnableProperty) {
        foreach ($item in @($pnpEnableProperty.Value)) {
            $devName = [string]$item
            if ([string]::IsNullOrWhiteSpace($devName) -or $devName -match '^t\s+(\d+)$') { continue }
            if ($devName -match '^#') {
                if ($ShowIgnored) {
                    $label = if ($devName.Length -gt 1) { $devName.Substring(1) } else { $devName }
                    $details += [pscustomobject]@{ Type = "[Dev]"; Name = "[Ignored] $label"; IsRunning = $false }
                }
                continue
            }
            if ($devName.StartsWith("?")) { $devName = $devName.Substring(1) }
            $dev = $PnpCache | Where-Object { $_.Name -like $devName } | Select-Object -First 1
            $details += [pscustomobject]@{ Type = "[Dev]"; Name = $devName; IsRunning = ($null -ne $dev -and $dev.Status -eq "OK") }
        }
    }

    $pnpDisableProperty = $WorkspaceData.PSObject.Properties["pnp_devices_disable"]
    if ($null -ne $pnpDisableProperty) {
        foreach ($item in @($pnpDisableProperty.Value)) {
            $devName = [string]$item
            if ([string]::IsNullOrWhiteSpace($devName) -or $devName -match '^t\s+(\d+)$') { continue }
            if ($devName -match '^#') {
                if ($ShowIgnored) {
                    $label = if ($devName.Length -gt 1) { $devName.Substring(1) } else { $devName }
                    $details += [pscustomobject]@{ Type = "[Dev]"; Name = "[Ignored] $label"; IsRunning = $false }
                }
                continue
            }
            if ($devName.StartsWith("?")) { $devName = $devName.Substring(1) }
            $dev = $PnpCache | Where-Object { $_.Name -like $devName } | Select-Object -First 1
            $details += [pscustomobject]@{ Type = "[Dev]"; Name = $devName; IsRunning = ($null -ne $dev -and $dev.Status -eq "OK") }
        }
    }

    $powerPlanProperty = $WorkspaceData.PSObject.Properties["power_plan"]
    if ($null -ne $powerPlanProperty) {
        $planName = [string]$powerPlanProperty.Value
        if (-not [string]::IsNullOrWhiteSpace($planName)) {
            if ($planName.StartsWith("?")) { $planName = $planName.Substring(1) }
            $active = powercfg /getactivescheme
            $details += [pscustomobject]@{ Type = "[Pwr]"; Name = $planName; IsRunning = ($active -match [regex]::Escape($planName)) }
        }
    }

    $registryTogglesProperty = $WorkspaceData.PSObject.Properties["registry_toggles"]
    if ($null -ne $registryTogglesProperty) {
        foreach ($item in @($registryTogglesProperty.Value)) {
            if ($null -eq $item) { continue }
            $pathProp = $item.PSObject.Properties["path"]
            $nameProp = $item.PSObject.Properties["name"]
            $valueProp = $item.PSObject.Properties["value"]
            if ($null -eq $pathProp -or $null -eq $nameProp -or $null -eq $valueProp) { continue }
            $regPath = [string]$pathProp.Value
            $regName = [string]$nameProp.Value
            if ([string]::IsNullOrWhiteSpace($regPath) -or [string]::IsNullOrWhiteSpace($regName)) { continue }
            if ($regName.StartsWith("?")) { $regName = $regName.Substring(1) }
            $expectedValue = $valueProp.Value
            $val = Get-ItemPropertyValue -Path $regPath -Name $regName -ErrorAction SilentlyContinue
            $details += [pscustomobject]@{ Type = "[Reg]"; Name = $regName; IsRunning = ($val -eq $expectedValue) }
        }
    }

    return $details
}

function Get-UIStatesFromWorkspaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [array]$PnpCache,
        [Parameter(Mandatory = $true)]
        [bool]$ShowIgnored
    )

    $metadataKeys = @("_config", "comment", "description")
    $states = @()
    foreach ($prop in $Workspaces.PSObject.Properties) {
        $name = $prop.Name
        if ($metadataKeys -contains $name) { continue }
        $workspaceData = $prop.Value
        $type = "stateful"
        $typeProperty = $workspaceData.PSObject.Properties["type"]
        if ($null -ne $typeProperty -and -not [string]::IsNullOrWhiteSpace([string]$typeProperty.Value)) {
            $type = [string]$typeProperty.Value
        }
        $tags = @()
        $tagsProperty = $workspaceData.PSObject.Properties["tags"]
        if ($null -ne $tagsProperty) {
            $tags = @($tagsProperty.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        }
        $current = if ($type -eq "oneshot") { "Idle" } else { Get-WorkspaceState -Workspace $workspaceData -PnpCache $PnpCache }
        $details = Get-WorkspaceDetails -WorkspaceData $workspaceData -PnpCache $PnpCache -ShowIgnored:$ShowIgnored
        $states += [pscustomobject]@{
            Name         = $name
            CurrentState = $current
            DesiredState = $current
            Details      = $details
            Tags         = $tags
            Type         = $type
        }
    }
    return $states
}

function Start-Dashboard {
    $jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
    if (-not (Test-Path -Path $jsonPath -PathType Leaf)) {
        throw "Fatal: workspaces.json not found."
    }

    $workspaces = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
    Write-Host "Scanning hardware devices..." -ForegroundColor DarkGray
    $globalPnpCache = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
    $showIgnored = $false
    $UIStates = Get-UIStatesFromWorkspaces -Workspaces $workspaces -PnpCache $globalPnpCache -ShowIgnored:$showIgnored

    if ($UIStates.Count -eq 0) {
        Write-Host "No workspaces found in workspaces.json."
        exit
    }

    $cursorIndex = 0
    $DetailedMode = $false
    $MenuState = "Master"
    $activeWorkspace = $null
    $editorItems = @()
    $nameColumnWidth = 42
    $isRendering = $true
    $needsRedraw = $true
    $AllTabs = @("All")
    foreach ($ui in $UIStates) {
        foreach ($tag in @($ui.Tags)) {
            if ($AllTabs -notcontains $tag) {
                $AllTabs += $tag
            }
        }
    }
    $activeTab = "All"

    while ($isRendering) {
        $visibleStates = @()
        foreach ($ui in $UIStates) {
            $uiTags = @()
            $tagsProp = $ui.PSObject.Properties["Tags"]
            if ($null -ne $tagsProp) {
                $uiTags = @($tagsProp.Value)
            }

            if ($activeTab -eq "All" -or $uiTags -contains $activeTab) {
                $visibleStates += $ui
            }
        }
        if ($MenuState -eq "Editor") {
            if ($editorItems.Count -eq 0) {
                $cursorIndex = 0
            } elseif ($cursorIndex -ge $editorItems.Count) {
                $cursorIndex = 0
            }
        } else {
            if ($visibleStates.Count -eq 0) {
                $cursorIndex = 0
            } elseif ($cursorIndex -ge $visibleStates.Count) {
                $cursorIndex = 0
            }
        }

        if ($needsRedraw) {
            if ($MenuState -eq "Master") {
                Clear-Host
                Write-Host "=== WORKSPACEMANAGER DASHBOARD ==="
                Write-Host " "
                for ($tabIdx = 0; $tabIdx -lt $AllTabs.Count; $tabIdx++) {
                    $tabText = "[$($tabIdx + 1)] $($AllTabs[$tabIdx])  "
                    if ($AllTabs[$tabIdx] -eq $activeTab) {
                        Write-Host -NoNewline $tabText -ForegroundColor Cyan
                    } else {
                        Write-Host -NoNewline $tabText
                    }
                }
                Write-Host ""
                Write-Host "   Profiles                               |  Current  ->  Desired"
                Write-Host "------------------------------------------+-------------------------"
                if ($visibleStates.Count -eq 0) {
                    Write-Host "   (No workspaces in this tab)" -ForegroundColor DarkGray
                }

                for ($i = 0; $i -lt $visibleStates.Count; $i++) {
                    $state = $visibleStates[$i]
                    $prefix = if ($i -eq $cursorIndex) { " > " } else { "   " }
                    $paddedName = $state.Name.PadRight($nameColumnWidth - 3)

                    Write-Host -NoNewline $prefix
                    Write-Host -NoNewline $paddedName -ForegroundColor Cyan
                    Write-Host -NoNewline "|  "

                    if ($state.Type -eq "oneshot") {
                        if ($state.DesiredState -eq "Run") {
                            Write-Host -NoNewline "-> Run" -ForegroundColor Magenta
                        } else {
                            Write-Host -NoNewline "One-Shot" -ForegroundColor DarkGray
                        }
                    } elseif ($state.CurrentState -eq $state.DesiredState) {
                        Write-ColoredStateText -State $state.CurrentState
                    } else {
                        $currentText = [string]$state.CurrentState
                        Write-ColoredStateText -State $currentText
                        $currentPadCount = 8 - $currentText.Length
                        if ($currentPadCount -gt 0) { Write-Host -NoNewline (" " * $currentPadCount) }
                        Write-Host -NoNewline " ->  "
                        Write-ColoredStateText -State $state.DesiredState
                    }
                    Write-Host ""

                    if ($DetailedMode -eq $true) {
                        foreach ($detail in $state.Details) {
                            $icon = if ($detail.IsRunning) { [char]0x25B6 } else { [char]0x25CB }
                            $detailPrefix = "      "
                            $detailType = if ($null -ne $detail.PSObject.Properties["Type"] -and -not [string]::IsNullOrWhiteSpace([string]$detail.Type)) { [string]$detail.Type } else { "[Obj]" }
                            $detailText = "$detailType $($detail.Name)".PadRight($nameColumnWidth - 12)
                            if ([string]$detail.Name -match '^\[Ignored\]') {
                                Write-Host "$detailPrefix$icon $detailText" -ForegroundColor DarkGray
                            } else {
                                Write-Host "$detailPrefix$icon $detailText"
                            }
                        }
                    }
                }

                Write-Host ""
                Write-Host "[Up/Down] Navigate  |  [Space] Toggle desired  |  [Backspace] Clear desired"
                Write-Host "[Right] Edit Workspace  |  [F1] Toggle Details"
                Write-Host "[F2] Toggle Ignored: $showIgnored |  [Esc] Cancel"
                Write-Host "[Enter] Commit & Exit"
            } elseif ($MenuState -eq "Editor") {
                Clear-Host
                Write-Host "=== EDITING: $($activeWorkspace.Name) ==="
                Write-Host ""
                if ($editorItems.Count -eq 0) {
                    Write-Host "   (No editable items in this workspace)" -ForegroundColor DarkGray
                } else {
                    for ($i = 0; $i -lt $editorItems.Count; $i++) {
                        $item = $editorItems[$i]
                        $prefix = if ($i -eq $cursorIndex) { " > " } else { "   " }
                        $text = "[$($item.Property)] $($item.Value)"
                        if ($item.Value -match '^#') {
                            Write-Host "$prefix$text" -ForegroundColor DarkGray
                        } else {
                            Write-Host "$prefix$text"
                        }
                    }
                }
                Write-Host ""
                Write-Host "[Up/Down] Navigate | [Space] Toggle Ignore | [Left] Back"
            }
            $needsRedraw = $false
        }

        if ([Console]::KeyAvailable) {
            try {
                $key = [Console]::ReadKey($true).Key
            } catch {
                Write-Host "Input error: $($_.Exception.Message)" -ForegroundColor Red
                break
            }

            if ($MenuState -eq "Master") {
                switch ($key) {
                "UpArrow" {
                    if ($cursorIndex -gt 0) { $cursorIndex-- }
                }
                "DownArrow" {
                    if ($cursorIndex -lt ($visibleStates.Count - 1)) { $cursorIndex++ }
                }
                "RightArrow" {
                    if ($visibleStates.Count -eq 0) { continue }
                    $activeWorkspace = $visibleStates[$cursorIndex]
                    $workspaceData = $workspaces.PSObject.Properties[$activeWorkspace.Name].Value
                    $editorItems = New-WorkspaceEditorItems -WorkspaceData $workspaceData
                    $MenuState = "Editor"
                    $cursorIndex = 0
                }
                "Spacebar" {
                    if ($visibleStates.Count -eq 0) { continue }
                    $selected = $visibleStates[$cursorIndex]
                    $selected.DesiredState = Update-DashboardDesiredStateOnSpace `
                        -Type ([string]$selected.Type) `
                        -CurrentState ([string]$selected.CurrentState) `
                        -DesiredState ([string]$selected.DesiredState)
                }
                "Backspace" {
                    if ($visibleStates.Count -eq 0) { continue }
                    $selected = $visibleStates[$cursorIndex]
                    $selected.DesiredState = Clear-DashboardDesiredState `
                        -Type ([string]$selected.Type) `
                        -CurrentState ([string]$selected.CurrentState)
                }
                "F1" {
                    $DetailedMode = -not $DetailedMode
                }
                "F2" {
                    $showIgnored = -not $showIgnored
                    $UIStates = Get-UIStatesFromWorkspaces -Workspaces $workspaces -PnpCache $globalPnpCache -ShowIgnored:$showIgnored
                }
                "Escape" {
                    Clear-Host
                    Write-Host "Cancelled."
                    exit
                }
                "Enter" {
                    $isRendering = $false
                    break
                }
                default {
                    $keyName = [string]$key
                    if ($keyName -match "^(?:D|NumPad)([1-9])$") {
                        $tabIndex = [int]$matches[1] - 1
                        if ($tabIndex -ge 0 -and $tabIndex -lt $AllTabs.Count) {
                            $activeTab = $AllTabs[$tabIndex]
                            $cursorIndex = 0
                        }
                    }
                }
                }
            } else {
                switch ($key) {
                "UpArrow" {
                    if ($cursorIndex -gt 0) { $cursorIndex-- }
                }
                "DownArrow" {
                    if ($cursorIndex -lt ($editorItems.Count - 1)) { $cursorIndex++ }
                }
                "LeftArrow" {
                    $MenuState = "Master"
                    $UIStates = Get-UIStatesFromWorkspaces -Workspaces $workspaces -PnpCache $globalPnpCache -ShowIgnored:$showIgnored
                    $cursorIndex = 0
                }
                "Spacebar" {
                    if ($editorItems.Count -eq 0) { continue }
                    $selectedEditorItem = $editorItems[$cursorIndex]
                    Set-WorkspaceEditorSelectionIgnored -Workspaces $workspaces -WorkspaceName $activeWorkspace.Name -EditorSelection $selectedEditorItem -WorkspacePath $jsonPath
                }
                "Escape" {
                    Clear-Host
                    Write-Host "Cancelled."
                    exit
                }
                }
            }
            $needsRedraw = $true
        } else {
            Start-Sleep -Milliseconds 50
        }
    }

    Clear-Host
    Write-Host "Committing state changes..."
    $OrchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"
    Invoke-WorkspaceCommit -UIStates $UIStates -OrchestratorPath $OrchestratorPath
    Write-Host "[ SUCCESS ] Workspaces updated."
    Start-Sleep -Seconds 2
    exit
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-Dashboard
}
