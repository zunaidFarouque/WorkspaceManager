Set-StrictMode -Version Latest

Describe "Workspace State Engine (Declarative Matrix)" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:statePath = Join-Path -Path $script:here -ChildPath "state.json"
        $script:stateBackupPath = Join-Path -Path $script:here -ChildPath "state.json.test-backup"
        if (Test-Path -Path $script:stateBackupPath) {
            Remove-Item -Path $script:stateBackupPath -Force
        }
        if (Test-Path -Path $script:statePath) {
            Move-Item -Path $script:statePath -Destination $script:stateBackupPath -Force
        }
        . (Join-Path -Path $script:here -ChildPath "WorkspaceState.ps1")
    }

    AfterAll {
        if (Test-Path -Path $script:statePath) {
            Remove-Item -Path $script:statePath -Force
        }
        if (Test-Path -Path $script:stateBackupPath) {
            Move-Item -Path $script:stateBackupPath -Destination $script:statePath -Force
        }
    }

    BeforeEach {
        if (Test-Path -Path $script:statePath) {
            Remove-Item -Path $script:statePath -Force
        }
        $script:config = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Windows_Update = [pscustomobject]@{
                    type = "service"
                    name = "wuauserv"
                }
                GPU_Scheduling_HAGS = [pscustomobject]@{
                    type = "registry"
                    path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
                    name = "HwSchMode"
                    value_on = 2
                    value_off = 1
                }
                Bluetooth_Radio = [pscustomobject]@{
                    type = "pnp_device"
                    match = @("*Bluetooth*")
                }
                Display_Refresh_Rate = [pscustomobject]@{
                    type = "stateless"
                }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    power_plan = "Ultimate Performance"
                    targets = [pscustomobject]@{
                        Windows_Update = "OFF"
                        GPU_Scheduling_HAGS = "OFF"
                    }
                }
                Eco_Life = [pscustomobject]@{
                    power_plan = "Power saver"
                    targets = [pscustomobject]@{
                        Display_Refresh_Rate = "ANY"
                        Bluetooth_Radio = "ANY"
                    }
                }
            }
            App_Workloads = [pscustomobject]@{
                DAW_Cubase = [pscustomobject]@{
                    services = @("Audiosrv")
                    executables = @("'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe'")
                }
            }
        }
    }

    It "marks App_Workload as Active when all declared checks are running" {
        '{"Active_System_Mode":"Live_Stage_Life"}' | Set-Content -Path $script:statePath -Encoding UTF8
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "Audiosrv") { return [pscustomobject]@{ Status = "Running" } }
            if ($Name -eq "wuauserv") { return [pscustomobject]@{ Status = "Stopped" } }
            return $null
        }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "Cubase12" } }
        Mock -CommandName Get-ItemPropertyValue -MockWith { 1 }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 1234  (Ultimate Performance)" }
        Mock -CommandName Get-CimInstance -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $script:config

        $state.AppWorkloads.DAW_Cubase.Status | Should -Be "Active"
        $state.AppWorkloads.DAW_Cubase.MatchedChecks | Should -Be 2
        $state.AppWorkloads.DAW_Cubase.TotalChecks | Should -Be 2
    }

    It "uses persisted Active_System_Mode for strict Active/Inactive status" {
        '{"Active_System_Mode":"Live_Stage_Life"}' | Set-Content -Path $script:statePath -Encoding UTF8
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "Audiosrv") { return [pscustomobject]@{ Status = "Stopped" } }
            if ($Name -eq "wuauserv") { return [pscustomobject]@{ Status = "Running" } }
            return $null
        }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-ItemPropertyValue -MockWith { 2 }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 1234  (Ultimate Performance)" }
        Mock -CommandName Get-CimInstance -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $script:config
        $wuRow = @($state.Compliance | Where-Object { $_.Component -eq "Windows_Update" })[0]

        $state.SystemModes.Live_Stage_Life.Status | Should -Be "Active"
        [string]$state.SystemModes.Eco_Life.Status | Should -Be "Inactive"
        $wuRow.TargetState | Should -Be "OFF"
        $wuRow.PhysicalState | Should -Be "ON"
        $wuRow.IsCompliant | Should -BeFalse
    }

    It "builds compliance rows once per hardware definition using active mode targets" {
        '{"Active_System_Mode":"Eco_Life"}' | Set-Content -Path $script:statePath -Encoding UTF8
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 9999  (Power saver)" }
        Mock -CommandName Get-CimInstance -MockWith { [pscustomobject]@{ Name = "Bluetooth Device"; Status = "Error" } }

        $state = Get-WorkspaceState -Workspace $script:config
        $rows = @($state.Compliance)
        $bluetoothRow = @($rows | Where-Object { $_.Component -eq "Bluetooth_Radio" })[0]
        $wuRow = @($rows | Where-Object { $_.Component -eq "Windows_Update" })[0]

        $state.SystemModes.Eco_Life.Status | Should -Be "Active"
        [string]$state.SystemModes.Live_Stage_Life.Status | Should -Be "Inactive"
        $rows.Count | Should -Be 4
        $bluetoothRow.TargetState | Should -Be "ANY"
        $bluetoothRow.IsCompliant | Should -Be $null
        $wuRow.TargetState | Should -Be "ANY"
        $wuRow.IsCompliant | Should -Be $null
    }

    It "defaults all compliance targets to ANY when no active mode is persisted" {
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 9999  (Power saver)" }
        Mock -CommandName Get-CimInstance -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $script:config

        foreach ($row in @($state.Compliance)) {
            $row.TargetState | Should -Be "ANY"
            $row.IsCompliant | Should -Be $null
        }
        [string]$state.SystemModes.Live_Stage_Life.Status | Should -Be "Inactive"
        [string]$state.SystemModes.Eco_Life.Status | Should -Be "Inactive"
    }

    It "creates a default state file when one does not exist" {
        if (Test-Path -Path $script:statePath) {
            Remove-Item -Path $script:statePath -Force
        }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 9999  (Power saver)" }
        Mock -CommandName Get-CimInstance -MockWith { $null }

        $null = Get-WorkspaceState -Workspace $script:config

        (Test-Path -Path $script:statePath) | Should -BeTrue
        $saved = Get-Content -Path $script:statePath -Raw -Encoding utf8 | ConvertFrom-Json
        $saved.PSObject.Properties.Name -contains "Active_System_Mode" | Should -BeTrue
    }
}
