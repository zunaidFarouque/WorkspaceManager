Set-StrictMode -Version Latest

Describe "Workspace State Engine (Declarative Matrix)" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        $script:statePath = Join-Path -Path $script:scriptsDir -ChildPath "state.json"
        $script:stateBackupPath = Join-Path -Path $script:scriptsDir -ChildPath "state.json.test-backup"
        if (Test-Path -Path $script:stateBackupPath) {
            Remove-Item -Path $script:stateBackupPath -Force
        }
        if (Test-Path -Path $script:statePath) {
            Move-Item -Path $script:statePath -Destination $script:stateBackupPath -Force
        }
        . (Join-Path -Path $script:scriptsDir -ChildPath "WorkspaceState.ps1")
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
                Audio = [pscustomobject]@{
                    DAW_Cubase = [pscustomobject]@{
                        services = @("Audiosrv")
                        executables = @("'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe'")
                        tags = @("audio", "daw")
                        priority = 10
                        favorite = $true
                        hidden = $false
                        aliases = @("Cubase")
                    }
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
        @($state.AppWorkloads.DAW_Cubase.RuntimeDetails.Services).Count | Should -Be 1
        @($state.AppWorkloads.DAW_Cubase.RuntimeDetails.Executables).Count | Should -Be 1
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.Services[0].Name | Should -Be "Audiosrv"
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.Services[0].IsRunning | Should -BeTrue
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.Executables[0].DisplayName | Should -Be "Cubase12.exe"
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.Executables[0].IsRunning | Should -BeTrue
        $state.AppWorkloads.DAW_Cubase.Domain | Should -Be "Audio"
        @($state.AppWorkloads.DAW_Cubase.Tags).Count | Should -Be 2
        $state.AppWorkloads.DAW_Cubase.Favorite | Should -BeTrue
        $state.AppWorkloads.DAW_Cubase.Hidden | Should -BeFalse
        @($state.AppWorkloads.DAW_Cubase.Aliases).Count | Should -Be 1
    }

    It "captures mixed runtime details for workloads with partial matches" {
        '{"Active_System_Mode":"Live_Stage_Life"}' | Set-Content -Path $script:statePath -Encoding UTF8
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "Audiosrv") { return [pscustomobject]@{ Status = "Stopped" } }
            if ($Name -eq "wuauserv") { return [pscustomobject]@{ Status = "Stopped" } }
            return $null
        }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "Cubase12" } }
        Mock -CommandName Get-ItemPropertyValue -MockWith { 1 }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 1234  (Ultimate Performance)" }
        Mock -CommandName Get-CimInstance -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $script:config

        $state.AppWorkloads.DAW_Cubase.Status | Should -Be "Mixed"
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.MatchedChecks | Should -Be 1
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.TotalChecks | Should -Be 2
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.Services[0].IsRunning | Should -BeFalse
        $state.AppWorkloads.DAW_Cubase.RuntimeDetails.Executables[0].IsRunning | Should -BeTrue
    }

    It "provides stable empty runtime details when workload has no checks" {
        $script:config.App_Workloads = [pscustomobject]@{
            General = [pscustomobject]@{
                Empty_Workload = [pscustomobject]@{
                    services = @()
                    executables = @()
                    tags = @()
                    priority = 5
                    favorite = $false
                    hidden = $false
                    aliases = @()
                }
            }
        }
        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 9999  (Power saver)" }
        Mock -CommandName Get-CimInstance -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $script:config

        $state.AppWorkloads.Empty_Workload.Status | Should -Be "Inactive"
        $state.AppWorkloads.Empty_Workload.RuntimeDetails.MatchedChecks | Should -Be 0
        $state.AppWorkloads.Empty_Workload.RuntimeDetails.TotalChecks | Should -Be 0
        @($state.AppWorkloads.Empty_Workload.RuntimeDetails.Services).Count | Should -Be 0
        @($state.AppWorkloads.Empty_Workload.RuntimeDetails.Executables).Count | Should -Be 0
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

    It "sorts grouped workloads by priority then name" {
        $script:config.App_Workloads = [pscustomobject]@{
            Dev = [pscustomobject]@{
                Zeta = [pscustomobject]@{ services = @(); executables = @(); priority = 30; tags = @(); aliases = @(); favorite = $false; hidden = $false }
                Alpha = [pscustomobject]@{ services = @(); executables = @(); priority = 10; tags = @(); aliases = @(); favorite = $false; hidden = $false }
            }
            Audio = [pscustomobject]@{
                Beta = [pscustomobject]@{ services = @(); executables = @(); priority = 10; tags = @(); aliases = @(); favorite = $false; hidden = $false }
            }
        }
        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 9999  (Power saver)" }
        Mock -CommandName Get-CimInstance -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $script:config
        @($state.AppWorkloads.PSObject.Properties.Name) | Should -Be @("Alpha", "Beta", "Zeta")
    }
}


