Set-StrictMode -Version Latest

Describe "Dashboard Commit Engine" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "invokes orchestrator only for actionable state transitions" {
        $uiStates = @(
            [pscustomobject]@{
                Name = "App1"
                CurrentState = "Stopped"
                DesiredState = "Ready"
                Type = "stateful"
            },
            [pscustomobject]@{
                Name = "App2"
                CurrentState = "Ready"
                DesiredState = "Stopped"
                Type = "stateful"
            },
            [pscustomobject]@{
                Name = "App3"
                CurrentState = "Ready"
                DesiredState = "Ready"
                Type = "stateful"
            },
            [pscustomobject]@{
                Name = "Cleanup"
                CurrentState = "Idle"
                DesiredState = "Run"
                Type = "oneshot"
            }
        )

        $mockOrchestratorPath = "C:\fake\Orchestrator.ps1"

        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Invoke-OrchestratorScript -MockWith { }

        Invoke-WorkspaceCommit -UIStates $uiStates -OrchestratorPath $mockOrchestratorPath

        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 3 -Exactly
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "App1" -and $Action -eq "Start"
        }
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "App2" -and $Action -eq "Stop"
        }
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "Cleanup" -and $Action -eq "Start"
        }
    }
}

Describe "Dashboard desired-state keys (Space / Backspace)" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "when current is Mixed, Space toggles only Ready and Stopped" {
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Mixed" -DesiredState "Mixed" | Should -Be "Ready"
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Mixed" -DesiredState "Ready" | Should -Be "Stopped"
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Mixed" -DesiredState "Stopped" | Should -Be "Ready"
    }

    It "Backspace on Mixed with desired Ready resets to Mixed" {
        Clear-DashboardDesiredState -Type "stateful" -CurrentState "Mixed" | Should -Be "Mixed"
    }

    It "Backspace on Ready with desired Stopped resets to Ready" {
        Clear-DashboardDesiredState -Type "stateful" -CurrentState "Ready" | Should -Be "Ready"
    }

    It "Backspace on oneshot clears Run to Idle" {
        Clear-DashboardDesiredState -Type "oneshot" -CurrentState "Idle" | Should -Be "Idle"
    }

    It "Space on non-Mixed stateful still toggles Ready and Stopped" {
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Ready" -DesiredState "Ready" | Should -Be "Stopped"
        Update-DashboardDesiredStateOnSpace -Type "stateful" -CurrentState "Ready" -DesiredState "Stopped" | Should -Be "Ready"
    }
}

Describe "Dashboard Editor Helpers" {
    BeforeAll {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        . (Join-Path -Path $here -ChildPath "Dashboard.ps1")
    }

    It "builds editor items from actionable array properties" {
        $workspace = [pscustomobject]@{
            services            = @("Audiosrv")
            executables         = @("C:/Tools/App.exe")
            pnp_devices_disable = @("#*Camera*")
            tags                = @("Live_Stage")
        }

        $items = @(New-WorkspaceEditorItems -WorkspaceData $workspace)

        $items.Count | Should -Be 3
        @($items | Where-Object { $_.Property -eq "services" }).Count | Should -Be 1
        @($items | Where-Object { $_.Property -eq "executables" }).Count | Should -Be 1
        @($items | Where-Object { $_.Property -eq "pnp_devices_disable" }).Count | Should -Be 1
        @($items | Where-Object { $_.Property -eq "tags" }).Count | Should -Be 0
    }

    It "toggles ignored marker and mutates RAM + disk for selected item" {
        $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("dashboard-editor-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        try {
            $workspaces = [pscustomobject]@{
                Audio_Production = [pscustomobject]@{
                    pnp_devices_disable = @("*Camera*")
                }
            }
            $selection = [pscustomobject]@{
                Property = "pnp_devices_disable"
                Index    = 0
                Value    = "*Camera*"
            }

            Set-WorkspaceEditorSelectionIgnored -Workspaces $workspaces -WorkspaceName "Audio_Production" -EditorSelection $selection -WorkspacePath $tempPath
            $workspaces.Audio_Production.pnp_devices_disable[0] | Should -Be "#*Camera*"
            $selection.Value | Should -Be "#*Camera*"

            Set-WorkspaceEditorSelectionIgnored -Workspaces $workspaces -WorkspaceName "Audio_Production" -EditorSelection $selection -WorkspacePath $tempPath
            $workspaces.Audio_Production.pnp_devices_disable[0] | Should -Be "*Camera*"
            $selection.Value | Should -Be "*Camera*"

            $saved = Get-Content -Path $tempPath -Raw | ConvertFrom-Json
            @($saved.Audio_Production.pnp_devices_disable).Count | Should -Be 1
        } finally {
            if (Test-Path -Path $tempPath) {
                Remove-Item -Path $tempPath -Force
            }
        }
    }

    It "filters or shows ignored details based on showIgnored toggle" {
        $workspace = [pscustomobject]@{
            services = @("Audiosrv", "#IgnoredService")
        }

        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName powercfg -MockWith { "" }
        Mock -CommandName Get-ItemPropertyValue -MockWith { $null }

        $hidden = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$false)
        $shown = @(Get-WorkspaceDetails -WorkspaceData $workspace -PnpCache @() -ShowIgnored:$true)

        @($hidden | Where-Object { $_.Name -match "IgnoredService" }).Count | Should -Be 0
        @($shown | Where-Object { $_.Name -eq "[Ignored] IgnoredService" -and $_.IsRunning -eq $false }).Count | Should -Be 1
    }
}
