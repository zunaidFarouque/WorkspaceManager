Set-StrictMode -Version Latest

Describe "Dashboard Phase 3 Commit Engine" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "invokes orchestrator only for workload and mode entries with desired delta" {
        $uiStates = @(
            [pscustomobject]@{ Name = "DAW_Cubase"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload" },
            [pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Inactive"; ProfileType = "System_Mode" },
            [pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Mixed"; DesiredState = "Mixed"; ProfileType = "System_Mode" }
        )

        Mock -CommandName Invoke-OrchestratorScript -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }

        Invoke-WorkspaceCommit -UIStates $uiStates -OrchestratorPath "C:/fake/Orchestrator.ps1"

        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 2 -Exactly
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $WorkspaceName -eq "DAW_Cubase" -and $Action -eq "Start"
        }
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $WorkspaceName -eq "Live_Stage_Life" -and $Action -eq "Stop"
        }
    }
}

Describe "Dashboard Phase 3 Desired-State Toggle" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "toggles Active/Inactive for non-mixed current state" {
        Update-DashboardDesiredStateOnSpace -CurrentState "Inactive" -DesiredState "Inactive" | Should -Be "Active"
        Update-DashboardDesiredStateOnSpace -CurrentState "Inactive" -DesiredState "Active" | Should -Be "Inactive"
    }

    It "toggles only Active/Inactive when current state is Mixed" {
        Update-DashboardDesiredStateOnSpace -CurrentState "Mixed" -DesiredState "Mixed" | Should -Be "Active"
        Update-DashboardDesiredStateOnSpace -CurrentState "Mixed" -DesiredState "Active" | Should -Be "Inactive"
    }

    It "allows toggling when current and desired are empty" {
        Update-DashboardDesiredStateOnSpace -CurrentState "" -DesiredState "" | Should -Be "Active"
        Update-DashboardDesiredStateOnSpace -CurrentState "" -DesiredState "Active" | Should -Be "Inactive"
    }

    It "renders empty state text without throwing" {
        { Write-StateText -State "" } | Should -Not -Throw
    }

    It "hides Inactive text in Tab 2 display" {
        Get-DashboardDisplayState -CurrentTab 2 -State "Inactive" | Should -Be ""
        Get-DashboardDisplayState -CurrentTab 2 -State "Active" | Should -Be "Active"
        Get-DashboardDisplayState -CurrentTab 1 -State "Inactive" | Should -Be "Inactive"
    }
}

Describe "Dashboard Phase 3 Post-Commit Messaging" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "harvests post-change and action-specific messages from System_Modes path" {
        $uiStates = @(
            [pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Inactive"; DesiredState = "Active" }
        )
        $workspaces = [pscustomobject]@{
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    post_change_message = "Mode switched."
                    post_start_message = "Live mode engaged."
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
        }

        $result = @(Get-DashboardPostCommitMessages -UIStates $uiStates -Workspaces $workspaces)

        $result.Count | Should -Be 2
        $result[0] | Should -Be "[Live_Stage_Life] Mode switched."
        $result[1] | Should -Be "[Live_Stage_Life] Live mode engaged."
    }

    It "harvests hardware post-stop message from Hardware_Definitions path" {
        $uiStates = @(
            [pscustomobject]@{ Name = "GPU_Scheduling_HAGS"; CurrentState = "Active"; DesiredState = "Inactive" }
        )
        $workspaces = [pscustomobject]@{
            System_Modes = [pscustomobject]@{}
            Hardware_Definitions = [pscustomobject]@{
                GPU_Scheduling_HAGS = [pscustomobject]@{
                    post_change_message = "HAGS changed."
                    post_stop_message = "Restart required."
                }
            }
        }

        $result = @(Get-DashboardPostCommitMessages -UIStates $uiStates -Workspaces $workspaces)

        $result.Count | Should -Be 2
        $result[0] | Should -Be "[GPU_Scheduling_HAGS] HAGS changed."
        $result[1] | Should -Be "[GPU_Scheduling_HAGS] Restart required."
    }
}

Describe "Dashboard Tab 3 Manual Override Console" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "toggles ON and OFF desired state for manual hardware override rows" {
        Update-DashboardHardwareDesiredStateOnSpace -DesiredState "ON" | Should -Be "OFF"
        Update-DashboardHardwareDesiredStateOnSpace -DesiredState "OFF" | Should -Be "ON"
        Update-DashboardHardwareDesiredStateOnSpace -DesiredState "ANY" | Should -Be "ON"
    }

    It "marks pending manual override rows with pending color and state" {
        $pending = [pscustomobject]@{
            Component     = "Bluetooth_Radio"
            PhysicalState = "OFF"
            DesiredState  = "ON"
            TargetState   = "ANY"
            IsCompliant   = $null
        }
        $queue = @{ "Bluetooth_Radio" = "ON" }

        $presentation = Get-DashboardTab3RowPresentation -Row $pending -IsSelected $true -PendingHardwareChanges $queue
        $presentation.Status | Should -Be "[QUEUED: ON]"
        $presentation.Color | Should -Be "Yellow"
        $presentation.Prefix | Should -Be " > "
    }

    It "commits hardware override rows through Hardware_Override profile type" {
        $uiStates = @(
            [pscustomobject]@{ Name = "Bluetooth_Radio"; CurrentState = "OFF"; DesiredState = "ON"; ProfileType = "Hardware_Override" },
            [pscustomobject]@{ Name = "Windows_Update"; CurrentState = "ON"; DesiredState = "OFF"; ProfileType = "Hardware_Override" }
        )

        Mock -CommandName Invoke-OrchestratorScript -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }

        Invoke-WorkspaceCommit -UIStates $uiStates -OrchestratorPath "C:/fake/Orchestrator.ps1"

        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $WorkspaceName -eq "Bluetooth_Radio" -and $Action -eq "Start" -and $ProfileType -eq "Hardware_Override"
        }
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $WorkspaceName -eq "Windows_Update" -and $Action -eq "Stop" -and $ProfileType -eq "Hardware_Override"
        }
    }

    It "persists active system mode intent to state json" {
        $statePath = Join-Path -Path $TestDrive -ChildPath "state.json"
        $modeStates = @(
            [pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Mixed"; DesiredState = "Active"; ProfileType = "System_Mode" },
            [pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Active"; DesiredState = "Inactive"; ProfileType = "System_Mode" }
        )

        Save-DashboardStateMemory -ModeStates $modeStates -StateFilePath $statePath
        $saved = Get-Content -Path $statePath -Raw -Encoding utf8 | ConvertFrom-Json
        $saved.Active_System_Mode | Should -Be "Live_Stage_Life"
    }

    It "bootstraps state json when missing" {
        $statePath = Join-Path -Path $TestDrive -ChildPath "state.json"
        Ensure-DashboardStateMemoryFile -StateFilePath $statePath
        (Test-Path -Path $statePath) | Should -BeTrue
        $saved = Get-Content -Path $statePath -Raw -Encoding utf8 | ConvertFrom-Json
        $saved.PSObject.Properties.Name -contains "Active_System_Mode" | Should -BeTrue
    }
}

Describe "Dashboard Tab 2/3 Queue Workflow" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "queues ideal targets for compliance violations only" {
        $queue = @{}
        $complianceData = @(
            [pscustomobject]@{ Component = "Windows_Update"; IsCompliant = $false; TargetState = "OFF" },
            [pscustomobject]@{ Component = "Bluetooth_Radio"; IsCompliant = $false; TargetState = "ANY" },
            [pscustomobject]@{ Component = "GPU_Scheduling_HAGS"; IsCompliant = $true; TargetState = "OFF" }
        )

        Add-DashboardIdealHardwareToQueue -ComplianceData $complianceData -PendingHardwareChanges $queue

        $queue.Keys.Count | Should -Be 1
        $queue["Windows_Update"] | Should -Be "OFF"
    }

    It "toggles queue entry state between ON and OFF" {
        $queue = @{ "Windows_Update" = "OFF" }
        Toggle-DashboardQueueOverride -Component "Windows_Update" -PendingHardwareChanges $queue
        $queue["Windows_Update"] | Should -Be "ON"
        Toggle-DashboardQueueOverride -Component "Windows_Update" -PendingHardwareChanges $queue
        $queue["Windows_Update"] | Should -Be "OFF"
    }

    It "clears queue entry for selected component" {
        $queue = @{ "Windows_Update" = "ON" }
        Clear-DashboardQueueOverride -Component "Windows_Update" -PendingHardwareChanges $queue
        $queue.ContainsKey("Windows_Update") | Should -BeFalse
    }

    It "shows queued row with queued status and yellow color" {
        $row = [pscustomobject]@{
            Component     = "Windows_Update"
            PhysicalState = "ON"
            DesiredState  = "OFF"
            TargetState   = "OFF"
            IsCompliant   = $false
        }
        $queue = @{ "Windows_Update" = "OFF" }

        $presentation = Get-DashboardTab3RowPresentation -Row $row -IsSelected $true -PendingHardwareChanges $queue

        $presentation.Color | Should -Be "Yellow"
        $presentation.Status | Should -Be "[QUEUED: OFF]"
        $presentation.Desired | Should -Be "OFF"
        $presentation.Prefix | Should -Be " > "
    }

    It "shows blueprint target in Desired for non-queued violation rows" {
        $row = [pscustomobject]@{
            Component     = "Ethernet_Port"
            PhysicalState = "ON"
            DesiredState  = "ON"
            TargetState   = "OFF"
            IsCompliant   = $false
        }
        $queue = @{}

        $presentation = Get-DashboardTab3RowPresentation -Row $row -IsSelected $false -PendingHardwareChanges $queue

        $presentation.Desired | Should -Be "OFF"
        $presentation.Status | Should -Be "[VIOLATION]"
        $presentation.Color | Should -Be "Red"
    }

    It "normalizes ANY targets to empty Desired by default" {
        $rows = @(
            [pscustomobject]@{
                Component     = "Display_Refresh_Rate"
                PhysicalState = $null
                DesiredState  = "ON"
                TargetState   = "ANY"
                IsCompliant   = $null
            }
        )
        $queue = @{}

        Normalize-DashboardComplianceRows -ComplianceRows $rows -PendingHardwareChanges $queue

        $rows[0].DesiredState | Should -Be ""
    }

    It "uses compact symbols for compliant and ignored rows" {
        $matchRow = [pscustomobject]@{
            Component     = "Windows_Update"
            PhysicalState = "OFF"
            DesiredState  = "OFF"
            TargetState   = "OFF"
            IsCompliant   = $true
        }
        $ignoredRow = [pscustomobject]@{
            Component     = "Display_Refresh_Rate"
            PhysicalState = $null
            DesiredState  = ""
            TargetState   = "ANY"
            IsCompliant   = $null
        }
        $queue = @{}

        $matchView = Get-DashboardTab3RowPresentation -Row $matchRow -IsSelected $false -PendingHardwareChanges $queue
        $ignoredView = Get-DashboardTab3RowPresentation -Row $ignoredRow -IsSelected $false -PendingHardwareChanges $queue

        $matchView.Status | Should -Be "✓"
        $ignoredView.Status | Should -Be "-"
    }

    It "renders tab-specific footer action text" {
        Get-DashboardFooterText -CurrentTab 1 | Should -Match '\[Space\] Toggle Workload \| \[Enter\] Commit'
        Get-DashboardFooterText -CurrentTab 2 | Should -Match '\[Space\] Set Blueprint \| \[A\] Queue Ideal States \| \[Enter\] Commit'
        Get-DashboardFooterText -CurrentTab 3 | Should -Match '\[Space\] Toggle Override \| \[Bksp\] Clear Queue \| \[Enter\] Commit'
    }

    It "sets active blueprint immediately and updates mode rows" {
        $statePath = Join-Path -Path $TestDrive -ChildPath "state.json"
        $modeStates = @(
            [pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" },
            [pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Inactive"; DesiredState = "Inactive"; ProfileType = "System_Mode" }
        )

        Set-DashboardActiveBlueprint -ModeStates $modeStates -SelectedModeName "Eco_Life" -StateFilePath $statePath

        $saved = Get-Content -Path $statePath -Raw -Encoding utf8 | ConvertFrom-Json
        $saved.Active_System_Mode | Should -Be "Eco_Life"
        @($modeStates | Where-Object { $_.CurrentState -eq "Active" }).Count | Should -Be 1
        @($modeStates | Where-Object { $_.DesiredState -eq "Active" }).Count | Should -Be 1
        (@($modeStates | Where-Object { $_.Name -eq "Eco_Life" })[0].CurrentState) | Should -Be "Active"
    }
}

Describe "Dashboard Commit Scope Rules" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "builds commit states from workload deltas and queued hardware only" {
        $workloads = @(
            [pscustomobject]@{ Name = "DAW_Cubase"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload" }
        )
        $modes = @(
            [pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" }
        )
        $queue = @{ "Windows_Update" = "OFF" }

        $pending = Get-DashboardPendingCommitStates -WorkloadStates $workloads -PendingHardwareChanges $queue

        $pending.Count | Should -Be 2
        (@($pending | Where-Object { $_.ProfileType -eq "System_Mode" })).Count | Should -Be 0
        (@($pending | Where-Object { $_.Name -eq "DAW_Cubase" -and $_.Action -eq "Start" })).Count | Should -Be 1
        (@($pending | Where-Object { $_.Name -eq "Windows_Update" -and $_.DesiredState -eq "OFF" -and $_.ProfileType -eq "Hardware_Override" })).Count | Should -Be 1
    }

    It "clears pending hardware queue after commit helper runs" {
        $queue = @{ "Windows_Update" = "OFF" }
        Mock -CommandName Invoke-WorkspaceCommit -MockWith { }

        Invoke-DashboardCommit -PendingStates @() -PendingHardwareChanges $queue -OrchestratorPath "C:/fake/Orchestrator.ps1"

        $queue.Keys.Count | Should -Be 0
    }
}
