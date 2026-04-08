Set-StrictMode -Version Latest

Describe "Workspace State Analyzer" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $script:here -ChildPath "WorkspaceState.ps1")
    }

    It "returns Ready when all services and executables are running" {
        $workspace = [pscustomobject]@{
            services    = @("Audiosrv")
            executables = @("'C:/Program Files/App.exe' --hidden")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "App" } }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Ready"
    }

    It "returns Stopped when no services or executables are running" {
        $workspace = [pscustomobject]@{
            services    = @("Audiosrv")
            executables = @("C:/Tools/App.exe")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Stopped"
    }

    It "returns Mixed when only one of two items is running" {
        $workspace = [pscustomobject]@{
            services    = @("Audiosrv")
            executables = @("C:/Tools/App.exe")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Mixed"
    }

    It "returns Stopped for an empty workspace" {
        $workspace = [pscustomobject]@{}

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "Anything" } }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Stopped"
    }

    It "strips path arguments and .exe before Get-Process lookup" {
        $workspace = [pscustomobject]@{
            executables = @("'C:/My Folder/My App.exe' --hidden --profile live")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "My App" } }

        $state = Get-WorkspaceState -Workspace $workspace

        $state | Should -Be "Ready"
        Assert-MockCalled -CommandName Get-Process -Times 1 -Exactly -ParameterFilter {
            $Name -eq "My App"
        }
    }

    It "ignores timer tokens in services and executables when calculating state" {
        $workspace = [pscustomobject]@{
            services    = @("warp-svc", "t 2000")
            executables = @("'C:/App.exe'", "t 3000")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "App" } }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Ready"
    }

    It "does not penalize missing optional service in state totals" {
        $workspace = [pscustomobject]@{
            services    = @("?MissingService")
            executables = @("'C:/App.exe'")
        }

        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "App" } }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Ready"
    }

    It "returns Idle for oneshot workspaces" {
        $workspace = [pscustomobject]@{
            type        = "oneshot"
            services    = @("Audiosrv")
            executables = @("C:/Tools/App.exe")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "App" } }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Idle"
    }

    It "ignores metadata keys when calculating workspace state" {
        $workspace = [pscustomobject]@{
            comment     = "Do not parse as workload"
            description = "Reserved for future UI output"
            services    = @("Audiosrv")
            executables = @("C:/Tools/App.exe")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "App" } }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Ready"
    }

    It "returns Ready when DSC targets are compliant" {
        $workspace = [pscustomobject]@{
            pnp_devices_enable  = @("USB Audio")
            pnp_devices_disable = @("Bluetooth")
            power_plan          = "High performance"
            registry_toggles    = @(
                [pscustomobject]@{
                    path  = "HKLM:\SOFTWARE\Contoso"
                    name  = "LowLatency"
                    value = 1
                    type  = "DWord"
                }
            )
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-CimInstance -MockWith {
            if ($Filter -match "USB Audio") { return [pscustomobject]@{ Status = "OK" } }
            if ($Filter -match "Bluetooth") { return [pscustomobject]@{ Status = "Error" } }
            return $null
        }
        Mock -CommandName powercfg -MockWith { "Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { 1 }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Ready"
    }

    It "treats pnp_devices_disable status OK as non-compliant" {
        $workspace = [pscustomobject]@{
            pnp_devices_disable = @("Bluetooth")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-CimInstance -MockWith { [pscustomobject]@{ Status = "OK" } }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $workspace
        $state | Should -Be "Stopped"
    }

    It "uses provided PnpCache instead of calling Get-CimInstance" {
        $workspace = [pscustomobject]@{
            pnp_devices_enable  = @("USB Audio*")
            pnp_devices_disable = @("Bluetooth*")
        }
        $pnpCache = @(
            [pscustomobject]@{ Name = "USB Audio Device"; Status = "OK" },
            [pscustomobject]@{ Name = "Bluetooth Radio"; Status = "Error" }
        )

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Stopped" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Get-CimInstance -MockWith { throw "Get-CimInstance should not be called when cache is provided" }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $workspace -PnpCache $pnpCache

        $state | Should -Be "Ready"
        Assert-MockCalled -CommandName Get-CimInstance -Times 0 -Exactly
    }

    It "ignores # entries and excludes them from state math totals" {
        $workspace = [pscustomobject]@{
            services            = @("Audiosrv", "#IgnoredService")
            executables         = @("C:/Tools/App.exe", "#C:/Tools/Ignored.exe")
            pnp_devices_enable  = @("USB Audio*", "#Ignored Device")
            pnp_devices_disable = @("Bluetooth*", "#Ignored Disable Device")
        }
        $pnpCache = @(
            [pscustomobject]@{ Name = "USB Audio Device"; Status = "OK" },
            [pscustomobject]@{ Name = "Bluetooth Radio"; Status = "Error" }
        )

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = "App" } }
        Mock -CommandName Get-CimInstance -MockWith { throw "Get-CimInstance should not be called when cache is provided" }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $state = Get-WorkspaceState -Workspace $workspace -PnpCache $pnpCache

        $state | Should -Be "Ready"
        Assert-MockCalled -CommandName Get-Service -Times 1 -Exactly -ParameterFilter { $Name -eq "Audiosrv" }
        Assert-MockCalled -CommandName Get-Process -Times 1 -Exactly -ParameterFilter { $Name -eq "App" }
        Assert-MockCalled -CommandName Get-CimInstance -Times 0 -Exactly
    }
}
