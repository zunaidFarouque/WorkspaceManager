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

    It "returns empty messages when UIStates is empty" {
        $workspaces = [pscustomobject]@{
            System_Modes = [pscustomobject]@{}
            Hardware_Definitions = [pscustomobject]@{}
        }

        $result = @(Get-DashboardPostCommitMessages -UIStates @() -Workspaces $workspaces)

        $result.Count | Should -Be 0
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

    It "keeps Desired tied to blueprint target even when queued differs" {
        $rows = @(
            [pscustomobject]@{
                Component     = "Search_Indexer"
                PhysicalState = "ON"
                DesiredState  = "OFF"
                TargetState   = "ON"
                IsCompliant   = $true
            }
        )
        $queue = @{ "Search_Indexer" = "OFF" }

        Normalize-DashboardComplianceRows -ComplianceRows $rows -PendingHardwareChanges $queue
        $view = Get-DashboardTab3RowPresentation -Row $rows[0] -IsSelected $false -PendingHardwareChanges $queue

        $rows[0].DesiredState | Should -Be "ON"
        $view.Desired | Should -Be "ON"
        $view.Status | Should -Be "[QUEUED: OFF]"
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
        Get-DashboardFooterText -CurrentTab 1 | Should -Match '\[1\]\[2\]\[3\]\[4\] Tab \| \[Up/Down\] Nav \| \[Space\] Toggle Workload \| \[`\] Details: None \| \[Enter\] Commit'
        Get-DashboardFooterText -CurrentTab 2 | Should -Match '\[1\]\[2\]\[3\]\[4\] Tab \| \[Up/Down\] Nav \| \[Space\] Set Blueprint \| \[A\] Queue Ideal States \| \[Enter\] Commit'
        Get-DashboardFooterText -CurrentTab 3 | Should -Match '\[1\]\[2\]\[3\]\[4\] Tab \| \[Up/Down\] Nav \| \[Space\] Toggle Override \| \[Bksp\] Clear Queue \| \[Enter\] Commit'
        Get-DashboardFooterText -CurrentTab 4 | Should -Match '\[1\]\[2\]\[3\]\[4\] Tab \| \[Up/Down\] Nav \| \[Space\] Queue Toggle/Cycle \| \[Right\] Edit \| \[Left or \+/-\] Poll Seconds \| \[Enter\] Commit'
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

Describe "Dashboard Tab 4 Settings" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "returns settings as active array for tab 4" {
        $settings = @([pscustomobject]@{ Key = "notifications"; Type = "bool"; Value = $true })
        $rows = Get-ActiveStateArray -CurrentTab 4 -WorkloadStates @([pscustomobject]@{ Name = "dummy" }) -ModeStates @([pscustomobject]@{ Name = "dummy" }) -SettingsStates $settings
        @($rows).Count | Should -Be 1
        $rows[0].Key | Should -Be "notifications"
    }

    It "loads configured settings rows and provides descriptions" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{
                console_style = "Normal"
                enable_interceptors = $true
                notifications = $false
                interceptor_poll_max_seconds = 15
                shortcut_prefix_start = "!Start-"
                shortcut_prefix_stop = "!Stop-"
                untouched_key = "keep"
            }
        }

        $rows = @(Get-DashboardSettingsRows -Workspaces $workspaces)
        $rows.Count | Should -Be 6
        (@($rows | Where-Object { $_.Key -eq "enable_interceptors" }))[0].Type | Should -Be "bool"
        (@($rows | Where-Object { $_.Key -eq "interceptor_poll_max_seconds" }))[0].Type | Should -Be "int"
        (@($rows | Where-Object { $_.Key -eq "shortcut_prefix_start" }))[0].Description.Length | Should -BeGreaterThan 5
        (@($rows | Where-Object { $_.Key -eq "console_style" }))[0].Description | Should -Match 'spacing|detail'
        (@($rows | Where-Object { $_.Key -eq "enable_interceptors" }))[0].Description | Should -Match 'executable interceptors'
        (@($rows | Where-Object { $_.Key -eq "enable_interceptors" }))[0].Description | Should -Not -Match 'Office executable'
        (@($rows | Where-Object { $_.Key -eq "interceptor_poll_max_seconds" }))[0].Example | Should -Match 'Example: 15'
    }

    It "toggles bool and cycles choice on space" {
        $boolRow = [pscustomobject]@{ Key = "notifications"; Type = "bool"; Value = $false; Choices = @(); Min = $null; Description = "" }
        $choiceRow = [pscustomobject]@{ Key = "console_style"; Type = "choice"; Value = "Normal"; Choices = @("Normal", "Compact"); Min = $null; Description = "" }

        (Update-DashboardSettingsValueOnSpace -Row $boolRow) | Should -BeTrue
        $boolRow.Value | Should -BeTrue

        (Update-DashboardSettingsValueOnSpace -Row $choiceRow) | Should -BeTrue
        $choiceRow.Value | Should -Be "Compact"
    }

    It "updates numeric setting with floor validation" {
        $row = [pscustomobject]@{ Key = "interceptor_poll_max_seconds"; Type = "int"; Value = 2; Choices = @(); Min = 1; Description = "" }
        (Update-DashboardSettingsNumericValue -Row $row -Delta -1) | Should -BeTrue
        $row.Value | Should -Be 1
        (Update-DashboardSettingsNumericValue -Row $row -Delta -10) | Should -BeTrue
        $row.Value | Should -Be 1
        (Update-DashboardSettingsNumericValue -Row $row -Delta 4) | Should -BeTrue
        $row.Value | Should -Be 5
    }

    It "parses Enter-input for integer settings with clamping" {
        $row = [pscustomobject]@{ Key = "interceptor_poll_max_seconds"; Type = "int"; Value = 15; Choices = @(); Min = 1; Description = "" }
        (Update-DashboardSettingsIntegerFromInput -Row $row -InputText "20") | Should -BeTrue
        $row.Value | Should -Be 20
        (Update-DashboardSettingsIntegerFromInput -Row $row -InputText "0") | Should -BeTrue
        $row.Value | Should -Be 1
        (Update-DashboardSettingsIntegerFromInput -Row $row -InputText "abc") | Should -BeFalse
        $row.Value | Should -Be 1
    }

    It "saves selected settings rows and preserves unknown config keys" {
        $jsonPath = Join-Path -Path $TestDrive -ChildPath "workspaces.json"
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{
                console_style = "Normal"
                enable_interceptors = $true
                notifications = $true
                interceptor_poll_max_seconds = 15
                shortcut_prefix_start = "!Start-"
                shortcut_prefix_stop = "!Stop-"
                untouched_key = "keep"
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{}
        }
        $rows = @(Get-DashboardSettingsRows -Workspaces $workspaces)
        (@($rows | Where-Object { $_.Key -eq "notifications" }))[0].Value = $false
        (@($rows | Where-Object { $_.Key -eq "interceptor_poll_max_seconds" }))[0].Value = 9
        (@($rows | Where-Object { $_.Key -eq "shortcut_prefix_start" }))[0].Value = "#Go-"

        Save-DashboardConfigSettings -JsonPath $jsonPath -Workspaces $workspaces -SettingsRows $rows

        $saved = Get-Content -Path $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        $saved._config.notifications | Should -BeFalse
        $saved._config.interceptor_poll_max_seconds | Should -Be 9
        $saved._config.shortcut_prefix_start | Should -Be "#Go-"
        $saved._config.untouched_key | Should -Be "keep"
    }

    It "marks settings row as pending when desired differs from current" {
        $row = [pscustomobject]@{
            Key = "notifications"
            Type = "bool"
            CurrentValue = $true
            Value = $false
        }

        (Test-DashboardSettingsRowPending -Row $row) | Should -BeTrue
        $row.Value = $true
        (Test-DashboardSettingsRowPending -Row $row) | Should -BeFalse
    }

    It "requires non-empty value for shortcut prefix settings" {
        $required = [pscustomobject]@{ Key = "shortcut_prefix_start"; Type = "string"; Value = "!Start-" }
        $optional = [pscustomobject]@{ Key = "console_style"; Type = "choice"; Value = "Normal" }

        (Test-DashboardSettingRequiresNonEmpty -Row $required) | Should -BeTrue
        (Test-DashboardSettingRequiresNonEmpty -Row $optional) | Should -BeFalse
    }

    It "applies string edit input with non-empty validation rules" {
        $required = [pscustomobject]@{ Key = "shortcut_prefix_stop"; Type = "string"; Value = "!Stop-" }
        $optional = [pscustomobject]@{ Key = "shortcut_prefix_start_custom"; Type = "string"; Value = "#Go-" }

        $emptyRequired = Apply-DashboardSettingEditInput -Row $required -InputText ""
        $emptyRequired.Applied | Should -BeFalse
        $emptyRequired.ValidationError | Should -BeTrue
        $required.Value | Should -Be "!Stop-"

        $emptyOptional = Apply-DashboardSettingEditInput -Row $optional -InputText ""
        $emptyOptional.Applied | Should -BeFalse
        $emptyOptional.ValidationError | Should -BeFalse
        $optional.Value | Should -Be "#Go-"
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
        $pending = @(
            [pscustomobject]@{
                Name = "Windows_Update"
                CurrentState = "ON"
                DesiredState = "OFF"
                ProfileType = "Hardware_Override"
                Action = "Stop"
            }
        )
        Mock -CommandName Invoke-WorkspaceCommit -MockWith { }

        Invoke-DashboardCommit -PendingStates $pending -PendingHardwareChanges $queue -OrchestratorPath "C:\fake\Orchestrator.ps1"

        $queue.Keys.Count | Should -Be 0
    }

    It "runs sync-only orchestrator path when there are no pending states" {
        $queue = @{}
        Mock -CommandName Invoke-WorkspaceCommit -MockWith { throw "should not commit workloads" }
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            throw "Fatal: Workspace '__SYNC_ONLY__' not defined in workspaces.json."
        }

        { Invoke-DashboardCommit -PendingStates @() -PendingHardwareChanges $queue -OrchestratorPath "C:\fake\Orchestrator.ps1" } | Should -Not -Throw

        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq "C:\fake\Orchestrator.ps1" -and
            $WorkspaceName -eq "__SYNC_ONLY__" -and $Action -eq "Start"
        }
        Assert-MockCalled -CommandName Invoke-WorkspaceCommit -Times 0 -Exactly
    }

    It "persists queued settings during commit" {
        $queue = @{}
        $jsonPath = Join-Path -Path $TestDrive -ChildPath "workspaces.json"
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{
                notifications = $true
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{}
        }
        $settingsRows = @(
            [pscustomobject]@{
                Key = "notifications"
                Type = "bool"
                CurrentValue = $true
                Value = $false
                Choices = @()
                Min = $null
            }
        )
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            throw "Fatal: Workspace '__SYNC_ONLY__' not defined in workspaces.json."
        }

        Invoke-DashboardCommit -PendingStates @() -PendingHardwareChanges $queue -OrchestratorPath "C:\fake\Orchestrator.ps1" -JsonPath $jsonPath -Workspaces $workspaces -SettingsRows $settingsRows

        $saved = Get-Content -Path $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        $saved._config.notifications | Should -BeFalse
    }
}

Describe "Dashboard Workload Detail Modes" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "Dashboard.ps1")
    }

    It "cycles detail mode in the expected order" {
        Get-NextWorkloadDetailMode -CurrentMode "None" | Should -Be "MixedOnly"
        Get-NextWorkloadDetailMode -CurrentMode "MixedOnly" | Should -Be "All"
        Get-NextWorkloadDetailMode -CurrentMode "All" | Should -Be "None"
        Get-NextWorkloadDetailMode -CurrentMode "Unexpected" | Should -Be "None"
    }

    It "toggles detail mode only on workload tab when tilde is pressed" {
        $result = Update-WorkloadDetailModeForKey -CurrentTab 1 -CurrentMode "None" -Key "Oem3"
        $result.Mode | Should -Be "MixedOnly"
        $result.Changed | Should -BeTrue

        $tab2 = Update-WorkloadDetailModeForKey -CurrentTab 2 -CurrentMode "None" -Key "Oem3"
        $tab2.Mode | Should -Be "None"
        $tab2.Changed | Should -BeFalse

        $tab3 = Update-WorkloadDetailModeForKey -CurrentTab 3 -CurrentMode "None" -Key "Oem3"
        $tab3.Mode | Should -Be "None"
        $tab3.Changed | Should -BeFalse
    }

    It "renders details by mode rules" {
        Should-RenderWorkloadDetails -DetailMode "None" -State "Mixed" | Should -BeFalse
        Should-RenderWorkloadDetails -DetailMode "MixedOnly" -State "Active" | Should -BeFalse
        Should-RenderWorkloadDetails -DetailMode "MixedOnly" -State "Mixed" | Should -BeTrue
        Should-RenderWorkloadDetails -DetailMode "All" -State "Inactive" | Should -BeTrue
    }

    It "builds compact detail rows with svc/exe labels and runtime flags" {
        $row = [pscustomobject]@{
            Name = "Office"
            RuntimeDetails = [pscustomobject]@{
                Services = @(
                    [pscustomobject]@{ Name = "ClickToRunSvc"; IsRunning = $true }
                )
                Executables = @(
                    [pscustomobject]@{ Token = "'C:/Program Files/Microsoft OneDrive/OneDrive.exe'"; DisplayName = "OneDrive.exe"; IsRunning = $false }
                )
                MatchedChecks = 1
                TotalChecks = 2
            }
        }

        $rows = @(Get-WorkloadDetailLines -WorkloadRow $row)
        $rows.Count | Should -Be 2
        $rows[0].Label | Should -Be "svc ClickToRunSvc"
        $rows[0].IsRunning | Should -BeTrue
        $rows[1].Label | Should -Be "exe OneDrive.exe"
        $rows[1].IsRunning | Should -BeFalse
    }

    It "formats mixed status with check counts only for mixed rows" {
        $mixedRow = [pscustomobject]@{
            RuntimeDetails = [pscustomobject]@{
                MatchedChecks = 1
                TotalChecks = 2
            }
        }
        $inactiveRow = [pscustomobject]@{
            RuntimeDetails = [pscustomobject]@{
                MatchedChecks = 0
                TotalChecks = 2
            }
        }

        Get-WorkloadStateText -State "Mixed" -WorkloadRow $mixedRow | Should -Be "Mixed (1/2)"
        Get-WorkloadStateText -State "Inactive" -WorkloadRow $inactiveRow | Should -Be "Inactive"
    }

    It "includes detail mode hint in tab 1 footer only" {
        Get-DashboardFooterText -CurrentTab 1 -WorkloadDetailMode "All" | Should -Match '\[`\] Details: All'
        Get-DashboardFooterText -CurrentTab 2 -WorkloadDetailMode "All" | Should -Not -Match 'Details:'
        Get-DashboardFooterText -CurrentTab 3 -WorkloadDetailMode "All" | Should -Not -Match 'Details:'
    }
}
