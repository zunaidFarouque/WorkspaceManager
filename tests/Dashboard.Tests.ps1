Set-StrictMode -Version Latest

Describe "Dashboard Phase 3 Commit Engine" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
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
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
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
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
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
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
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
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
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

    It "renders unified footer layout across all tabs" {
        $tab1Footer = Get-DashboardFooterText -CurrentTab 1
        $tab1Lines = @($tab1Footer -split "`n")
        $tab1Lines.Count | Should -Be 3
        $tab1Lines[0] | Should -Be "[``]Details: None | [M]ixed=Off | [/]Filters: q='' | [G]roup='All' | [F]avourites=Off"
        $tab1Lines[1] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Toggle"
        $tab1Lines[2] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"

        $tab2Footer = Get-DashboardFooterText -CurrentTab 2
        $tab2Lines = @($tab2Footer -split "`n")
        $tab2Lines.Count | Should -Be 2
        $tab2Lines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Set Mode | [A] Queue Ideal States"
        $tab2Lines[0] | Should -Not -Match "Set Blueprint"
        $tab2Lines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"

        $tab3Footer = Get-DashboardFooterText -CurrentTab 3
        $tab3Lines = @($tab3Footer -split "`n")
        $tab3Lines.Count | Should -Be 2
        $tab3Lines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Toggle Override | [Bksp] Clear Queue"
        $tab3Lines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"

        $tab4Footer = Get-DashboardFooterText -CurrentTab 4
        $tab4Lines = @($tab4Footer -split "`n")
        $tab4Lines.Count | Should -Be 2
        $tab4Lines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Edit Setting | [Right] Edit | [Left or +/-] Poll Seconds"
        $tab4Lines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"
    }

    It "renders tab 4 footer as context-aware by selected row" {
        $boolRow = [pscustomobject]@{ Key = "notifications"; Type = "bool"; Value = $true }
        $choiceRow = [pscustomobject]@{ Key = "console_style"; Type = "choice"; Value = "Normal"; Choices = @("Normal", "Compact") }
        $stringRow = [pscustomobject]@{ Key = "shortcut_prefix_start"; Type = "string"; Value = "!Start-" }
        $intRow = [pscustomobject]@{ Key = "interceptor_poll_max_seconds"; Type = "int"; Value = 15; Min = 1 }
        $sectionRow = [pscustomobject]@{ Type = "section"; Label = "-------- Actions --------" }
        $actionRow = [pscustomobject]@{ Key = "Reset_Interceptors"; Type = "action"; ActionId = "Reset_Interceptors" }

        $boolLines = @((Get-DashboardFooterText -CurrentTab 4 -Tab4SelectedRow $boolRow -CommitMode "Exit") -split "`n")
        $boolLines.Count | Should -Be 2
        $boolLines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Edit Setting"
        $boolLines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"

        $choiceLines = @((Get-DashboardFooterText -CurrentTab 4 -Tab4SelectedRow $choiceRow -CommitMode "Return") -split "`n")
        $choiceLines.Count | Should -Be 2
        $choiceLines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Edit Setting"
        $choiceLines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Return | [Esc] Cancel"

        $stringLines = @((Get-DashboardFooterText -CurrentTab 4 -Tab4SelectedRow $stringRow -CommitMode "Exit") -split "`n")
        $stringLines.Count | Should -Be 2
        $stringLines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Edit Setting | [Right] Edit"
        $stringLines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"

        $intLines = @((Get-DashboardFooterText -CurrentTab 4 -Tab4SelectedRow $intRow -CommitMode "Exit") -split "`n")
        $intLines.Count | Should -Be 2
        $intLines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav | [Space] Edit Setting | [Left/Right or +/-] Poll Seconds"
        $intLines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"

        $sectionLines = @((Get-DashboardFooterText -CurrentTab 4 -Tab4SelectedRow $sectionRow -CommitMode "Exit") -split "`n")
        $sectionLines.Count | Should -Be 2
        $sectionLines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav"
        $sectionLines[1] | Should -Be "[R] CommitMode | [Enter] Commit & Exit | [Esc] Cancel"

        $actionLines = @((Get-DashboardFooterText -CurrentTab 4 -Tab4SelectedRow $actionRow -CommitMode "Return") -split "`n")
        $actionLines.Count | Should -Be 2
        $actionLines[0] | Should -Be "[1][2][3][4] Tab | [Up/Down] Nav"
        $actionLines[1] | Should -Be "[R] CommitMode | [Enter] Confirm/Run Action | [Esc] Cancel"
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
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "returns settings as active array for tab 4" {
        $settings = @([pscustomobject]@{ Key = "notifications"; Type = "bool"; Value = $true })
        $rows = Get-ActiveStateArray -CurrentTab 4 -WorkloadStates @([pscustomobject]@{ Name = "dummy" }) -ModeStates @([pscustomobject]@{ Name = "dummy" }) -SettingsStates $settings -ActionStates @()
        @($rows).Count | Should -Be 1
        $rows[0].Key | Should -Be "notifications"
    }

    It "builds tab 4 rows with section separator and action rows" {
        $settings = @([pscustomobject]@{ Key = "notifications"; Type = "bool"; Value = $true; CurrentValue = $true })
        $actions = @([pscustomobject]@{ Key = "Reset_Interceptors"; Type = "action"; ActionId = "Reset_Interceptors" })

        $rows = @(Get-DashboardTab4Rows -SettingsRows $settings -ActionRows $actions)

        $rows.Count | Should -Be 3
        $rows[0].Key | Should -Be "notifications"
        $rows[1].Type | Should -Be "section"
        $rows[2].ActionId | Should -Be "Reset_Interceptors"
        (Test-DashboardTab4RowIsSetting -Row $rows[0]) | Should -BeTrue
        (Test-DashboardTab4RowIsSection -Row $rows[1]) | Should -BeTrue
        (Test-DashboardTab4RowIsAction -Row $rows[2]) | Should -BeTrue
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
        $rows.Count | Should -Be 7
        (@($rows | Where-Object { $_.Key -eq "disable_startup_logo" }))[0].Value | Should -BeFalse
        (@($rows | Where-Object { $_.Key -eq "enable_interceptors" }))[0].Type | Should -Be "bool"
        (@($rows | Where-Object { $_.Key -eq "interceptor_poll_max_seconds" }))[0].Type | Should -Be "int"
        (@($rows | Where-Object { $_.Key -eq "shortcut_prefix_start" }))[0].Description.Length | Should -BeGreaterThan 5
        (@($rows | Where-Object { $_.Key -eq "console_style" }))[0].Description | Should -Match 'spacing|detail'
        (@($rows | Where-Object { $_.Key -eq "enable_interceptors" }))[0].Description | Should -Match 'executable interceptors'
        (@($rows | Where-Object { $_.Key -eq "enable_interceptors" }))[0].Description | Should -Not -Match 'Office executable'
        (@($rows | Where-Object { $_.Key -eq "interceptor_poll_max_seconds" }))[0].Example | Should -Match 'Example: 15'
    }

    It "reports startup logo disabled only when _config.disable_startup_logo is true" {
        (Test-DashboardStartupLogoDisabled -Workspaces ([pscustomobject]@{ App_Workloads = [pscustomobject]@{} })) | Should -BeFalse
        (Test-DashboardStartupLogoDisabled -Workspaces ([pscustomobject]@{ _config = [pscustomobject]@{} })) | Should -BeFalse
        (Test-DashboardStartupLogoDisabled -Workspaces ([pscustomobject]@{ _config = [pscustomobject]@{ disable_startup_logo = $false } })) | Should -BeFalse
        (Test-DashboardStartupLogoDisabled -Workspaces ([pscustomobject]@{ _config = [pscustomobject]@{ disable_startup_logo = $true } })) | Should -BeTrue
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

    It "global interceptor reset disables setting and commits sync-only cleanup" {
        $queue = @{}
        $rows = @(
            [pscustomobject]@{
                Key = "enable_interceptors"
                Type = "bool"
                CurrentValue = $true
                Value = $true
                Choices = @()
                Min = $null
            }
        )
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{
                enable_interceptors = $true
            }
        }
        Mock -CommandName Invoke-DashboardCommit -MockWith { }
        Mock -CommandName Stop-DashboardInterceptorHelperProcesses -MockWith { 2 }

        $result = Invoke-DashboardGlobalInterceptorReset -SettingsRows $rows -JsonPath "C:\fake\workspaces.json" -Workspaces $workspaces -PendingHardwareChanges $queue -OrchestratorPath "C:\fake\Orchestrator.ps1"

        $rows[0].Value | Should -BeFalse
        $rows[0].CurrentValue | Should -BeFalse
        $result.DisabledInterceptors | Should -BeTrue
        $result.KilledProcessCount | Should -Be 2
        Assert-MockCalled -CommandName Invoke-DashboardCommit -Times 1 -Exactly -ParameterFilter {
            @($PendingStates).Count -eq 0 -and
            $OrchestratorPath -eq "C:\fake\Orchestrator.ps1"
        }
    }

    It "kills only interceptor helper shell processes during emergency cleanup" {
        Mock -CommandName Get-CimInstance -MockWith {
            @(
                [pscustomobject]@{ Name = "pwsh.exe"; ProcessId = 111; CommandLine = 'pwsh.exe -File C:\repo\Interceptor.ps1 WINWORD.EXE' },
                [pscustomobject]@{ Name = "powershell.exe"; ProcessId = 222; CommandLine = 'powershell -File C:\repo\InterceptorPoll.ps1 -WorkloadName Office' },
                [pscustomobject]@{ Name = "pwsh.exe"; ProcessId = 333; CommandLine = 'pwsh.exe -File C:\repo\Dashboard.ps1' },
                [pscustomobject]@{ Name = "notepad.exe"; ProcessId = 444; CommandLine = 'notepad.exe' }
            )
        }
        Mock -CommandName Stop-Process -MockWith { }

        $killed = Stop-DashboardInterceptorHelperProcesses

        $killed | Should -Be 2
        Assert-MockCalled -CommandName Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 111 -and $Force }
        Assert-MockCalled -CommandName Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 222 -and $Force }
        Assert-MockCalled -CommandName Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 333 }
        Assert-MockCalled -CommandName Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 444 }
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

    It "does not treat action rows as pending settings rows" {
        $actionRow = [pscustomobject]@{
            Key = "Reset_Interceptors"
            Type = "action"
            ActionId = "Reset_Interceptors"
            CurrentValue = "n/a"
            Value = "n/a"
        }
        (Test-DashboardTab4RowIsAction -Row $actionRow) | Should -BeTrue
        (Test-DashboardTab4RowIsSetting -Row $actionRow) | Should -BeFalse
    }

    It "shows confirm text only when action is armed" {
        $actionRow = [pscustomobject]@{
            Key = "Reset_Interceptors"
            Type = "action"
            ActionId = "Reset_Interceptors"
        }

        (Get-DashboardTab4RowValueDisplay -Row $actionRow -PendingActionConfirmId "") | Should -Be "Run"
        (Get-DashboardTab4RowValueDisplay -Row $actionRow -PendingActionConfirmId "Reset_Interceptors") | Should -Be "Confirm: Enter"
    }

    It "requires Enter twice to execute a tab 4 action row" {
        $actionRow = [pscustomobject]@{
            Key = "Reset_Interceptors"
            Type = "action"
            ActionId = "Reset_Interceptors"
        }
        $settingsRows = @(
            [pscustomobject]@{ Key = "notifications"; Type = "bool"; CurrentValue = $true; Value = $true }
        )

        $first = Resolve-DashboardActionEnterDecision -Row $actionRow -PendingActionConfirmId "" -SettingsRows $settingsRows
        $first.Decision | Should -Be "ArmAction"
        $first.NextPendingActionId | Should -Be "Reset_Interceptors"

        $second = Resolve-DashboardActionEnterDecision -Row $actionRow -PendingActionConfirmId "Reset_Interceptors" -SettingsRows $settingsRows
        $second.Decision | Should -Be "ExecuteAction"
    }

    It "blocks action execution when there are pending setting changes" {
        $actionRow = [pscustomobject]@{
            Key = "Reset_Interceptors"
            Type = "action"
            ActionId = "Reset_Interceptors"
        }
        $settingsRows = @(
            [pscustomobject]@{ Key = "notifications"; Type = "bool"; CurrentValue = $true; Value = $false }
        )

        $decision = Resolve-DashboardActionEnterDecision -Row $actionRow -PendingActionConfirmId "Reset_Interceptors" -SettingsRows $settingsRows
        $decision.Decision | Should -Be "BlockedByPendingSettings"
        $decision.Message | Should -Match 'exclusive'
    }

    It "dispatches Reset_Interceptors action through action dispatcher" {
        $queue = @{}
        $rows = @([pscustomobject]@{ Key = "enable_interceptors"; Type = "bool"; CurrentValue = $true; Value = $true })
        $workspaces = [pscustomobject]@{ _config = [pscustomobject]@{ enable_interceptors = $true } }
        Mock -CommandName Invoke-DashboardGlobalInterceptorReset -MockWith {
            return [pscustomobject]@{ DisabledInterceptors = $true; KilledProcessCount = 4 }
        }

        $result = Invoke-DashboardActionById -ActionId "Reset_Interceptors" -SettingsRows $rows -JsonPath "C:\fake\workspaces.json" -Workspaces $workspaces -PendingHardwareChanges $queue -OrchestratorPath "C:\fake\Orchestrator.ps1"

        $result.Success | Should -BeTrue
        $result.Message | Should -Match 'Killed 4 helper process'
        Assert-MockCalled -CommandName Invoke-DashboardGlobalInterceptorReset -Times 1 -Exactly
    }

    It "registers Reset_Network_Config as a tab 4 action" {
        $actions = @(Get-DashboardActionDefinitions)
        $hit = @($actions | Where-Object { $_.ActionId -eq "Reset_Network_Config" })
        $hit.Count | Should -Be 1
        [string]$hit[0].Description | Should -Match "DNS"
    }

    It "dispatches Reset_Network_Config action through action dispatcher" {
        $queue = @{}
        $rows = @([pscustomobject]@{ Key = "enable_interceptors"; Type = "bool"; CurrentValue = $true; Value = $true })
        $workspaces = [pscustomobject]@{ _config = [pscustomobject]@{ enable_interceptors = $true } }
        Mock -CommandName Invoke-DashboardGlobalNetworkReset -MockWith {
            return [pscustomobject]@{ AdapterCount = 3 }
        }

        $result = Invoke-DashboardActionById -ActionId "Reset_Network_Config" -SettingsRows $rows -JsonPath "C:\fake\workspaces.json" -Workspaces $workspaces -PendingHardwareChanges $queue -OrchestratorPath "C:\fake\Orchestrator.ps1"

        $result.Success | Should -BeTrue
        $result.Message | Should -Match 'Updated 3 adapter'
        Assert-MockCalled -CommandName Invoke-DashboardGlobalNetworkReset -Times 1 -Exactly
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
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
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
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            if ($WorkspaceName -eq "__SYNC_ONLY__") {
                throw "Fatal: Workspace '__SYNC_ONLY__' not defined in workspaces.json."
            }
        }
        Mock -CommandName Invoke-WorkspaceCommit -MockWith { }

        Invoke-DashboardCommit -PendingStates $pending -PendingHardwareChanges $queue -OrchestratorPath "C:\fake\Orchestrator.ps1"

        $queue.Keys.Count | Should -Be 0
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $WorkspaceName -eq "__SYNC_ONLY__" -and $Action -eq "Start"
        }
        Assert-MockCalled -CommandName Invoke-WorkspaceCommit -Times 1 -Exactly -ParameterFilter {
            $SkipInterceptorSync -eq $true
        }
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

Describe "Dashboard scope-gated sequencer (integrated)" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "Office-only workload activation does not schedule mode hardware operations" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    power_plan       = "Max Performance"
                    hardware_targets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
                }
            }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{ services = @("ClickToRunSvc"); executables = @("ONEDRIVE") }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "Office"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Office" }
        )
        $warnings = [System.Collections.Generic.List[string]]::new()
        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{} -WarningsRef ([ref]$warnings))

        @($ops | Where-Object { $_.Phase -in 3, 5 }).Count | Should -Be 0
        @($ops | Where-Object { $_.Phase -eq 4 }).Count | Should -Be 0
        @($ops | Where-Object { $_.WorkspaceName -eq "Office" -and $_.Phase -in 6, 7 }).Count | Should -Be 2
    }

    It "prints intent sections and detailed tasks instead of phase-number lines" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services    = @("ClickToRunSvc")
                        executables = @("ONEDRIVE")
                    }
                }
            }
        }
        $operations = @(
            [pscustomobject]@{
                Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office"
            },
            [pscustomobject]@{
                Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office"
            }
        )

        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith {
            param([object]$Object)
            if ($null -ne $Object) {
                $printed.Add([string]$Object)
            }
        }
        Mock -CommandName Invoke-OrchestratorScript -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }

        Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces

        @($printed | Where-Object { $_ -eq "STARTING SERVICES" }).Count | Should -BeGreaterThan 0
        @($printed | Where-Object { $_ -eq "STARTING EXECUTABLES" }).Count | Should -BeGreaterThan 0
        @($printed | Where-Object { $_ -like "*> Phase *" }).Count | Should -Be 0
        @($printed | Where-Object { $_ -like "- | Start Office: starting service ClickToRunSvc" }).Count | Should -BeGreaterThan 0
        @($printed | Where-Object { $_ -like "- | Start Office: starting executable ONEDRIVE" }).Count | Should -BeGreaterThan 0
    }

    It "transitions visible task status from pending to running to done" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                    }
                }
            }
        }
        $operation = [pscustomobject]@{
            Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office"
        }
        $rows = @(New-DashboardCommitProgressRows -Operations @($operation) -Workspaces $workspaces)
        @($rows | Where-Object { $_.RowType -eq "Task" -and $_.Status -eq "Pending" }).Count | Should -Be 1

        Set-DashboardProgressRowStatusForOperation -Rows $rows -Operation $operation -Status "Running"
        @($rows | Where-Object { $_.RowType -eq "Task" -and $_.Status -eq "Running" }).Count | Should -Be 1

        Set-DashboardProgressRowStatusForOperation -Rows $rows -Operation $operation -Status "Done"
        @($rows | Where-Object { $_.RowType -eq "Task" -and $_.Status -eq "Done" }).Count | Should -Be 1
    }

    It "shows running marker during execution and done marker after execution" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                    }
                }
            }
        }
        $operations = @(
            [pscustomobject]@{
                Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office"
            }
        )

        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith {
            param([object]$Object)
            if ($null -ne $Object) { $printed.Add([string]$Object) }
        }
        Mock -CommandName Invoke-OrchestratorScript -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }

        Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces

        @($printed | Where-Object { $_ -like "-> | Start Office: starting service ClickToRunSvc" }).Count | Should -BeGreaterThan 0
        @($printed | Where-Object { $_ -like "OK | Start Office: starting service ClickToRunSvc" }).Count | Should -BeGreaterThan 0
    }

    It "falls back to append rendering when cursor redraw is unavailable" {
        $rows = @(
            [pscustomobject]@{ RowType = "Section"; Section = "STARTING SERVICES"; Status = "Pending"; Reason = ""; TaskText = ""; Phase = 6; OpIndex = -1 },
            [pscustomobject]@{ RowType = "Task"; Section = "STARTING SERVICES"; Status = "Pending"; Reason = "Start Office"; TaskText = "starting service ClickToRunSvc"; Phase = 6; OpIndex = 1; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly" }
        )
        $renderState = @{ CanRedraw = $false }
        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith {
            param([object]$Object)
            if ($null -ne $Object) { $printed.Add([string]$Object) }
        }

        Write-DashboardProgressDisplay -Rows $rows -RenderState $renderState -UseCursorRedraw
        $renderState["CanRedraw"] = $false
        $rows[1].Status = "Running"
        Write-DashboardProgressDisplay -Rows $rows -RenderState $renderState -UseCursorRedraw

        @($printed | Where-Object { $_ -eq "STARTING SERVICES" }).Count | Should -Be 2
        @($printed | Where-Object { $_ -like "-> | Start Office: starting service ClickToRunSvc" }).Count | Should -Be 1
    }

    It "shows baseline failure recovery options for operation failures" {
        $failureInfo = [pscustomobject]@{
            Category = "Unknown"
            Message = "boom"
            CanRemediateServiceDisabled = $false
            ServiceName = ""
        }
        $options = @(Resolve-DashboardOperationFailureOptions -FailureInfo $failureInfo)
        @($options | Select-Object -ExpandProperty Id) | Should -Be @("AbortCommit", "SkipStep", "RetryStep")
    }

    It "offers service-manual remediation for service-disabled failures" {
        $operation = [pscustomobject]@{
            Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office"
        }
        $workspaces = [pscustomobject]@{
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                    }
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $info = Classify-DashboardOperationFailure -Operation $operation -Exception ([System.Exception]::new("Service cannot be started because it is disabled.")) -Workspaces $workspaces
        $info.Category | Should -Be "ServiceDisabled"
        $info.CanRemediateServiceDisabled | Should -BeTrue
        $options = @(Resolve-DashboardOperationFailureOptions -FailureInfo $info)
        @($options | Select-Object -ExpandProperty Id) | Should -Contain "SetServiceManualAndRetry"
    }

    It "retries failed operation when RetryStep is selected" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                    }
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office" }
        )
        $script:count = 0
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            $script:count++
            if ($script:count -eq 1) { throw "temporary failure" }
        }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }

        $script:choiceCalls = 0
        $readKey = {
            $script:choiceCalls++
            if ($script:choiceCalls -eq 1) { [pscustomobject]@{ KeyChar = '3'; Key = [ConsoleKey]::D3 } } else { [pscustomobject]@{ KeyChar = '1'; Key = [ConsoleKey]::D1 } }
        }

        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces -ReadKeyScript $readKey)
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 2 -Exactly
        $result[0].Result | Should -Be "Done"
        $result[0].Attempts | Should -Be 2
    }

    It "skips failed step and continues with next operation" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                        executables = @("ONEDRIVE")
                    }
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office" }
        )
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            if ($ExecutionScope -eq "ServicesOnly") { throw "boom" }
        }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }

        $readKey = { [pscustomobject]@{ KeyChar = '2'; Key = [ConsoleKey]::D2 } }
        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces -ReadKeyScript $readKey)
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 2 -Exactly
        $result[0].Result | Should -Be "Skipped"
        $result[1].Result | Should -Be "Done"
    }

    It "aborts commit on AbortCommit selection and stops remaining operations" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                        executables = @("ONEDRIVE")
                    }
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office" }
        )
        Mock -CommandName Invoke-OrchestratorScript -MockWith { throw "boom" }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }

        $readKey = { [pscustomobject]@{ KeyChar = '1'; Key = [ConsoleKey]::D1 } }
        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces -ReadKeyScript $readKey)
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly
        $result.Count | Should -Be 1
        $result[0].Result | Should -Be "Aborted"
    }

    It "aborts commit when Escape is pressed on failure menu" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                        executables = @("ONEDRIVE")
                    }
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office" }
        )
        Mock -CommandName Invoke-OrchestratorScript -MockWith { throw "boom" }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }

        $readKey = { [pscustomobject]@{ KeyChar = [char]0; Key = [ConsoleKey]::Escape } }
        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces -ReadKeyScript $readKey)
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly
        $result.Count | Should -Be 1
        $result[0].Result | Should -Be "Aborted"
    }

    It "aborts commit when orchestrator throws manual stop gate abort sentinel" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            App_Workloads = [pscustomobject]@{}
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 1; WorkspaceName = "Cloudflare_Warp"; ProfileType = "App_Workload"; Action = "Stop"; ExecutionScope = "ExecutablesOnly"; Reason = "Stop Cloudflare_Warp" },
            [pscustomobject]@{ Phase = 2; WorkspaceName = "Cloudflare_Warp"; ProfileType = "App_Workload"; Action = "Stop"; ExecutionScope = "ServicesOnly"; Reason = "Stop Cloudflare_Warp" }
        )
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            throw "RigShift: Manual stop gate aborted by user."
        }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }

        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces)
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly
        $result.Count | Should -Be 1
        $result[0].Result | Should -Be "Aborted"
    }

    It "applies service-manual remediation and retries when selected" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Prompt" }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                    }
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office" }
        )
        $script:attempts = 0
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            $script:attempts++
            if ($script:attempts -eq 1) { throw "service is disabled" }
        }
        Mock -CommandName Invoke-DashboardSetServiceStartupManual -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }

        $readKey = { [pscustomobject]@{ KeyChar = '4'; Key = [ConsoleKey]::D4 } }
        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces -ReadKeyScript $readKey)
        Assert-MockCalled -CommandName Invoke-DashboardSetServiceStartupManual -Times 1 -Exactly
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 2 -Exactly
        $result[0].Result | Should -Be "Done"
    }

    It "uses deterministic Abort policy in non-interactive mode" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Abort" }
            App_Workloads = [pscustomobject]@{}
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 5; WorkspaceName = "Bluetooth_Radio"; ProfileType = "Hardware_Override"; Action = "Start"; ExecutionScope = "All"; Reason = "Queued hardware override" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office" }
        )
        Mock -CommandName Invoke-OrchestratorScript -MockWith { throw "boom" }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }
        Mock -CommandName Test-DashboardInteractiveInputAvailable -MockWith { $false }

        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces)
        $result.Count | Should -Be 1
        $result[0].Result | Should -Be "Aborted"
    }

    It "uses deterministic Skip policy in non-interactive mode" {
        $workspaces = [pscustomobject]@{
            _config = [pscustomobject]@{ commit_error_policy = "Skip" }
            App_Workloads = [pscustomobject]@{}
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
        }
        $operations = @(
            [pscustomobject]@{ Phase = 5; WorkspaceName = "Bluetooth_Radio"; ProfileType = "Hardware_Override"; Action = "Start"; ExecutionScope = "All"; Reason = "Queued hardware override" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office" }
        )
        $script:calls = 0
        Mock -CommandName Invoke-OrchestratorScript -MockWith {
            $script:calls++
            if ($script:calls -eq 1) { throw "boom" }
        }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Host -MockWith { }
        Mock -CommandName Test-DashboardInteractiveInputAvailable -MockWith { $false }

        $result = @(Invoke-DashboardCommitOperations -Operations $operations -OrchestratorPath "C:\fake\Orchestrator.ps1" -Workspaces $workspaces)
        $result.Count | Should -Be 2
        $result[0].Result | Should -Be "Skipped"
        $result[1].Result | Should -Be "Done"
    }
}

Describe "Dashboard Workload Detail Modes" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
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
        Get-DashboardFooterText -CurrentTab 1 -WorkloadDetailMode "All" | Should -Match '\[`]Details: All'
        Get-DashboardFooterText -CurrentTab 2 -WorkloadDetailMode "All" | Should -Not -Match 'Details:'
        Get-DashboardFooterText -CurrentTab 3 -WorkloadDetailMode "All" | Should -Not -Match 'Details:'
    }
}

Describe "Dashboard Workload Group Label Formatting" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "pads short domain names to 8 characters inside brackets" {
        $row = [pscustomobject]@{
            Name   = "DAW_Cubase"
            Domain = "Audio"
        }

        $label = Format-WorkloadDisplayName -WorkloadRow $row
        $label | Should -Match '^\[Audio {3}\] DAW_Cubase$'

        $inside = $label.Substring(1, 8)
        $inside.Length | Should -Be 8
    }

    It "truncates long domain names to 8 characters inside brackets" {
        $row = [pscustomobject]@{
            Name   = "Tool"
            Domain = "VeryLongDomain"
        }

        $label = Format-WorkloadDisplayName -WorkloadRow $row
        $inside = $label.Substring(1, 8)

        $inside | Should -Be "VeryLong"
        $label | Should -Match '^\[VeryLong\] Tool$'
    }

    It "falls back to plain name when domain is empty" {
        $row = [pscustomobject]@{
            Name   = "Standalone"
            Domain = ""
        }

        $label = Format-WorkloadDisplayName -WorkloadRow $row
        $label | Should -Be "Standalone"
    }
}

Describe "Dashboard Workload Filtering and Viewport" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "filters workloads by domain, favorites, mixed, and search query" {
        $rows = @(
            [pscustomobject]@{ Name = "DAW_Cubase"; Domain = "Audio"; Tags = @("audio", "daw"); Aliases = @("Cubase"); Favorite = $true; Hidden = $false; Priority = 10; CurrentState = "Mixed" },
            [pscustomobject]@{ Name = "Office"; Domain = "Office"; Tags = @("productivity"); Aliases = @("M365"); Favorite = $true; Hidden = $false; Priority = 20; CurrentState = "Active" },
            [pscustomobject]@{ Name = "InternalTool"; Domain = "Tools"; Tags = @("internal"); Aliases = @(); Favorite = $false; Hidden = $true; Priority = 5; CurrentState = "Inactive" }
        )
        $filter = [pscustomobject]@{ Query = "cuba"; Domain = "Audio"; FavoritesOnly = $true; MixedOnly = $true }

        $result = @(Get-FilteredWorkloadStates -WorkloadStates $rows -FilterState $filter)

        $result.Count | Should -Be 1
        $result[0].Name | Should -Be "DAW_Cubase"
    }

    It "hides hidden workloads unless query explicitly matches" {
        $rows = @(
            [pscustomobject]@{ Name = "InternalTool"; Domain = "Tools"; Tags = @("internal"); Aliases = @("debug"); Favorite = $false; Hidden = $true; Priority = 1; CurrentState = "Inactive" }
        )
        $noQuery = [pscustomobject]@{ Query = ""; Domain = ""; FavoritesOnly = $false; MixedOnly = $false }
        $withQuery = [pscustomobject]@{ Query = "internal"; Domain = ""; FavoritesOnly = $false; MixedOnly = $false }

        @(Get-FilteredWorkloadStates -WorkloadStates $rows -FilterState $noQuery).Count | Should -Be 0
        @(Get-FilteredWorkloadStates -WorkloadStates $rows -FilterState $withQuery).Count | Should -Be 1
    }

    It "returns viewport range centered around cursor when possible" {
        $range = Get-ViewportRange -TotalCount 100 -CursorIndex 50 -WindowSize 11
        $range.Start | Should -Be 45
        $range.End | Should -Be 55
    }

    It "cycles domain filter across all groups and back to all" {
        $rows = @(
            [pscustomobject]@{ Domain = "Office" },
            [pscustomobject]@{ Domain = "Audio" }
        )
        $filter = [pscustomobject]@{ Domain = "" }

        Update-WorkloadDomainFilter -WorkloadStates $rows -FilterState $filter
        $filter.Domain | Should -Be "Audio"
        Update-WorkloadDomainFilter -WorkloadStates $rows -FilterState $filter
        $filter.Domain | Should -Be "Office"
        Update-WorkloadDomainFilter -WorkloadStates $rows -FilterState $filter
        $filter.Domain | Should -Be ""
    }
}

Describe "Dashboard Commit Return Mode" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "uses Exit as the default commit mode" {
        Get-DashboardCommitModeDefault | Should -Be "Exit"
    }

    It "toggles commit mode between Exit and Return" {
        Toggle-DashboardCommitMode -CurrentMode "Exit" | Should -Be "Return"
        Toggle-DashboardCommitMode -CurrentMode "Return" | Should -Be "Exit"
        Toggle-DashboardCommitMode -CurrentMode "Unexpected" | Should -Be "Exit"
    }

    It "formats commit mode indicator text" {
        Get-DashboardCommitModeText -CommitMode "Exit" | Should -Be "CommitMode: Exit"
        Get-DashboardCommitModeText -CommitMode "Return" | Should -Be "CommitMode: Return"
    }

    It "includes commit mode text in tab footer output" {
        Get-DashboardFooterText -CurrentTab 1 -WorkloadDetailMode "None" -CommitMode "Return" | Should -Match 'Commit & Return'
        Get-DashboardFooterText -CurrentTab 1 -WorkloadDetailMode "None" -CommitMode "Return" | Should -Match '\[R\] CommitMode'
        Get-DashboardFooterText -CurrentTab 4 -CommitMode "Exit" | Should -Match '\[R\] CommitMode \| \[Enter\] Commit & Exit \| \[Esc\] Cancel'
    }

    It "returns Exit immediately when commit mode is Exit" {
        $result = Resolve-DashboardPostCommitAction -CommitMode "Exit" -HasPostCommitMessages $false
        $result | Should -Be "Exit"
    }

    It "returns ReturnToDashboard when commit mode is Return and non-escape key is pressed" {
        $result = Resolve-DashboardPostCommitAction -CommitMode "Return" -HasPostCommitMessages $false -ReadKeyScript {
            return [pscustomobject]@{ Key = [ConsoleKey]::A }
        }
        $result | Should -Be "ReturnToDashboard"
    }

    It "returns Exit when commit mode is Return and escape key is pressed" {
        $result = Resolve-DashboardPostCommitAction -CommitMode "Return" -HasPostCommitMessages $true -ReadKeyScript {
            return [pscustomobject]@{ Key = [ConsoleKey]::Escape }
        }
        $result | Should -Be "Exit"
    }

    It "keeps commit sequence intact in Return mode" {
        $workloads = @(
            [pscustomobject]@{ Name = "DAW_Cubase"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload" }
        )
        $modes = @(
            [pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" }
        )
        $queue = @{}
        $workspaces = [pscustomobject]@{
            System_Modes = [pscustomobject]@{}
            Hardware_Definitions = [pscustomobject]@{}
        }
        $settingsRows = @()

        Mock -CommandName Invoke-SafeClearHost -MockWith { }
        Mock -CommandName Save-DashboardStateMemory -MockWith { }
        Mock -CommandName Invoke-DashboardCommit -MockWith { }
        Mock -CommandName Get-DashboardPostCommitMessages -MockWith { @() }

        $result = Invoke-DashboardCommitFlow `
            -WorkloadStates $workloads `
            -ModeStates $modes `
            -PendingHardwareChanges $queue `
            -OrchestratorPath "C:\fake\Orchestrator.ps1" `
            -StateFilePath "C:\fake\state.json" `
            -JsonPath "C:\fake\workspaces.json" `
            -Workspaces $workspaces `
            -SettingsRows $settingsRows `
            -CommitMode "Return" `
            -ReadKeyScript { return [pscustomobject]@{ Key = [ConsoleKey]::Enter } }

        $result | Should -Be "ReturnToDashboard"
        Assert-MockCalled -CommandName Save-DashboardStateMemory -Times 1 -Exactly
        Assert-MockCalled -CommandName Invoke-DashboardCommit -Times 1 -Exactly
    }
}





