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
}
