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
            },
            [pscustomobject]@{
                Name = "App2"
                CurrentState = "Ready"
                DesiredState = "Stopped"
            },
            [pscustomobject]@{
                Name = "App3"
                CurrentState = "Ready"
                DesiredState = "Ready"
            }
        )

        $mockOrchestratorPath = "C:\fake\Orchestrator.ps1"

        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Invoke-OrchestratorScript -MockWith { }

        Invoke-WorkspaceCommit -UIStates $uiStates -OrchestratorPath $mockOrchestratorPath

        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 2 -Exactly
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "App1" -and $Action -eq "Start"
        }
        Assert-MockCalled -CommandName Invoke-OrchestratorScript -Times 1 -Exactly -ParameterFilter {
            $OrchestratorPath -eq $mockOrchestratorPath -and $WorkspaceName -eq "App2" -and $Action -eq "Stop"
        }
    }
}
