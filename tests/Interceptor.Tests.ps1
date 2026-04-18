Set-StrictMode -Version Latest

Describe "Interceptor workload resolution and flow" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Interceptor.ps1")
        $env:RigShift_InProcPolling = "1"
    }

    BeforeEach {
        $env:RigShift_InterceptorBypass = $null
        $env:RigShift_InProcPolling = "1"
        function gsudo { }
        # App_Workloads must be nested Domain.WorkloadName per Get-AppWorkloadEntries / real workspaces.json.
        $script:workspaces = [pscustomobject]@{
            App_Workloads = [pscustomobject]@{
                Main = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                        executables = @("'C:/Program Files/Microsoft OneDrive/OneDrive.exe'")
                        intercepts = @(
                            [pscustomobject]@{
                                exe = @("WINWORD.EXE", "EXCEL.EXE")
                                requires = [pscustomobject]@{
                                    services = @("ClickToRunSvc")
                                }
                            }
                        )
                    }
                    StarDesk = [pscustomobject]@{
                        services = @("StarDeskService")
                        executables = @("'C:/Program Files/StarDesk/StarDesk.exe'")
                        intercepts = @("StarDesk.exe")
                    }
                }
            }
        }
    }

    AfterEach {
        if (Test-Path Function:\gsudo) {
            Remove-Item Function:\gsudo
        }
    }

    It "resolves intercepted workload by exe name case-insensitively" {
        $result = Resolve-InterceptedWorkload -Workspaces $script:workspaces -TargetExe "C:/Program Files/Microsoft Office/root/Office16/winword.exe"

        $result.Name | Should -Be "Office"
        @($result.RequiredServices).Count | Should -Be 1
        $result.RequiredServices[0] | Should -Be "ClickToRunSvc"
        @($result.RequiredExecutables).Count | Should -Be 0
    }

    It "rule active ignores non-required executables when requires.executables is empty" {
        $resolved = Resolve-InterceptedWorkload -Workspaces $script:workspaces -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE"

        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "ClickToRunSvc") { return [pscustomobject]@{ Status = "Running" } }
            return $null
        }
        Mock -CommandName Get-ExecutableIsRunning -MockWith { throw "Get-ExecutableIsRunning should not be called" }

        $resolvedOk = Test-InterceptorRuleActive -RequiredServices $resolved.RequiredServices -RequiredExecutables $resolved.RequiredExecutables

        $resolvedOk | Should -BeTrue
        Assert-MockCalled -CommandName Get-ExecutableIsRunning -Times 0 -Exactly
    }

    It "treats StartPending as active for required services" {
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "ClickToRunSvc") { return [pscustomobject]@{ Status = "StartPending" } }
            return $null
        }
        Mock -CommandName Get-ExecutableIsRunning -MockWith { throw "Get-ExecutableIsRunning should not be called" }

        $ok = Test-InterceptorRuleActive -RequiredServices @("ClickToRunSvc") -RequiredExecutables @()

        $ok | Should -BeTrue
        Assert-MockCalled -CommandName Get-ExecutableIsRunning -Times 0 -Exactly
    }

    It "Get-InterceptorPollMaxSeconds defaults to 15 when config is missing" {
        $ws = [pscustomobject]@{}
        Get-InterceptorPollMaxSeconds -Workspaces $ws | Should -Be 15
    }

    It "Get-InterceptorPollMaxSeconds reads interceptor_poll_max_seconds when present" {
        $ws = [pscustomobject]@{
            _config = [pscustomobject]@{
                interceptor_poll_max_seconds = 20
            }
        }
        Get-InterceptorPollMaxSeconds -Workspaces $ws | Should -Be 20
    }

    It "skips workloads that omit intercepts (does not throw)" {
        $ws = [pscustomobject]@{
            App_Workloads = [pscustomobject]@{
                Main = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                        executables = @("'C:/Program Files/Microsoft OneDrive/OneDrive.exe'")
                    }
                    StarDesk = [pscustomobject]@{
                        services = @("StarDeskService")
                        executables = @("'C:/Program Files/StarDesk/StarDesk.exe'")
                        intercepts = @("StarDesk.exe")
                    }
                }
            }
        }

        { Resolve-InterceptedWorkload -Workspaces $ws -TargetExe "C:/Program Files/StarDesk/STARdesk.exe" } | Should -Not -Throw

        $result = Resolve-InterceptedWorkload -Workspaces $ws -TargetExe "C:/Program Files/StarDesk/StarDesk.exe"
        $result.Name | Should -Be "StarDesk"
    }

    It "launches target immediately when workload is already active" {
        Mock -CommandName Get-InterceptorWorkspaces -MockWith { $script:workspaces }
        Mock -CommandName Test-InterceptorRuleActive -MockWith { $true }
        Mock -CommandName Show-InterceptorPrompt -MockWith { "No" }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Start-RuleActivationFlow -MockWith { }

        Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @("/q")

        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -and
            $ArgumentList.Count -eq 1 -and
            $ArgumentList[0] -eq "/q"
        }
        Assert-MockCalled -CommandName Show-InterceptorPrompt -Times 0 -Exactly
        Assert-MockCalled -CommandName Start-RuleActivationFlow -Times 0 -Exactly
    }

    It "prompts and activates REQUIRED-only before launching target when user selects No" {
        $script:ActivationWaitTimeoutSeconds = 0
        $script:ActivationPollIntervalSeconds = 0

        Mock -CommandName Get-InterceptorWorkspaces -MockWith { $script:workspaces }
        Mock -CommandName Test-InterceptorRuleActive -MockWith { $false }
        Mock -CommandName Show-InterceptorPrompt -MockWith { "No" }
        Mock -CommandName Start-RuleActivationFlow -MockWith { }
        Mock -CommandName Wait-ForInterceptorRuleActive -MockWith { $true }
        Mock -CommandName Start-Process -MockWith { }

        Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @("/safe")

        Assert-MockCalled -CommandName Show-InterceptorPrompt -Times 1 -Exactly
        Assert-MockCalled -CommandName Start-RuleActivationFlow -Times 1 -Exactly -ParameterFilter {
            $WorkloadName -eq "Office" -and
            @($RequiredServices).Count -eq 1 -and
            @($RequiredServices)[0] -eq "ClickToRunSvc" -and
            @($RequiredExecutables).Count -eq 0
        }
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE"
        }
    }

    It "exits without launching target when user selects Cancel" {
        Mock -CommandName Get-InterceptorWorkspaces -MockWith { $script:workspaces }
        Mock -CommandName Test-InterceptorRuleActive -MockWith { $false }
        Mock -CommandName Show-InterceptorPrompt -MockWith { "Cancel" }
        Mock -CommandName Start-RuleActivationFlow -MockWith { }
        Mock -CommandName Start-Process -MockWith { }

        Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @()

        Assert-MockCalled -CommandName Show-InterceptorPrompt -Times 1 -Exactly
        Assert-MockCalled -CommandName Start-RuleActivationFlow -Times 0 -Exactly
        Assert-MockCalled -CommandName Start-Process -Times 0 -Exactly
    }

    It "bypasses prompting when RigShift_InterceptorBypass=1" {
        $env:RigShift_InterceptorBypass = "1"

        Mock -CommandName Start-RuleActivationFlow -MockWith { }
        Mock -CommandName Show-InterceptorPrompt -MockWith { "Yes" }
        Mock -CommandName Get-InterceptorWorkspaces -MockWith { throw "should not resolve workspaces" }
        Mock -CommandName Resolve-InterceptedWorkload -MockWith { throw "should not resolve intercepted workload" }
        Mock -CommandName Start-Process -MockWith { }

        { Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @("/q") } | Should -Not -Throw

        Assert-MockCalled -CommandName Show-InterceptorPrompt -Times 0 -Exactly
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE"
        }

        $env:RigShift_InterceptorBypass = $null
    }

    It "waits for required-only activation before launching when user selects No" {
        $script:ActivationWaitTimeoutSeconds = 3
        $script:ActivationPollIntervalSeconds = 0

        Mock -CommandName Get-InterceptorWorkspaces -MockWith { $script:workspaces }
        Mock -CommandName Start-RuleActivationFlow -MockWith { }
        Mock -CommandName Show-InterceptorPrompt -MockWith { "No" }

        $script:activeCalls = 0
        Mock -CommandName Test-InterceptorRuleActive -MockWith {
            $script:activeCalls++
            if ($script:activeCalls -ge 3) { return $true }
            return $false
        }

        Mock -CommandName Start-Process -MockWith { }

        Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @("/safe")

        Assert-MockCalled -CommandName Show-InterceptorPrompt -Times 1 -Exactly
        $script:activeCalls | Should -BeGreaterThan 2
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly
    }

    It "launches when required-only activation never becomes active" {
        $script:ActivationWaitTimeoutSeconds = 0
        $script:ActivationPollIntervalSeconds = 0

        $env:RigShift_InterceptorBypass = $null

        Mock -CommandName Get-InterceptorWorkspaces -MockWith { $script:workspaces }
        Mock -CommandName Start-RuleActivationFlow -MockWith { }
        Mock -CommandName Show-InterceptorPrompt -MockWith { "No" }
        Mock -CommandName Test-InterceptorRuleActive -MockWith { return $false }
        Mock -CommandName Start-Process -MockWith { }

        Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @()

        Assert-MockCalled -CommandName Show-InterceptorPrompt -Times 1 -Exactly
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly
    }

    It "spawns InterceptorPoll worker in spawn mode with max seconds and poll marker" {
        $env:RigShift_InProcPolling = "0"

        $script:ActivationWaitTimeoutSeconds = 30
        $script:ActivationPollIntervalSeconds = 1
        $script:startProcessCalls = @()

        Mock -CommandName Get-InterceptorWorkspaces -MockWith { $script:workspaces }
        Mock -CommandName Resolve-InterceptedWorkload -MockWith {
            [pscustomobject]@{
                Name = "Office"
                Workload = $script:workspaces.App_Workloads.Main.Office
                RequiredServices = @("ClickToRunSvc")
                RequiredExecutables = @()
            }
        }
        Mock -CommandName Test-InterceptorRuleActive -MockWith { return $false }
        Mock -CommandName Show-InterceptorPrompt -MockWith { "No" }
        Mock -CommandName Start-RuleActivationFlow -MockWith { }
        Mock -CommandName Wait-ForInterceptorRuleActive -MockWith { throw "Wait-ForInterceptorRuleActive should not be called in spawn mode" }

        Mock -CommandName Start-Process -MockWith {
            # Worker spawn: return a process-like object that exposes ExitCode.
            $script:startProcessCalls += [pscustomobject]@{
                FilePath     = $FilePath
                ArgumentList = $ArgumentList
            }
            $argString = if ($ArgumentList -is [string]) { $ArgumentList } else { ($ArgumentList -join " ") }
            if ($FilePath -like "*pwsh.exe" -and ($argString -match "InterceptorPoll\.ps1")) {
                return [pscustomobject]@{ ExitCode = 0 }
            }
            return $null
        }

        Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @()
        $workerCalls = @($script:startProcessCalls | Where-Object {
            $s = if ($_.ArgumentList -is [string]) { $_.ArgumentList } else { ($_.ArgumentList -join " ") }
            $s -match "InterceptorPoll\.ps1"
        })
        if ($workerCalls.Count -eq 0) {
            $callsSummary = ($script:startProcessCalls | ForEach-Object {
                $a = if ($_.ArgumentList -is [string]) { $_.ArgumentList } else { ($_.ArgumentList -join " ") }
                "FilePath=$($_.FilePath) Args=$a"
            }) -join "`n"
            throw "No worker spawn detected. Start-Process calls were:`n$callsSummary"
        }

        $workerArgString = if ($workerCalls[0].ArgumentList -is [string]) { $workerCalls[0].ArgumentList } else { ($workerCalls[0].ArgumentList -join " ") }
        $workerArgString | Should -Match "InterceptorPoll\.ps1"
        $workerArgString | Should -Match '-MaxSeconds\s+15'
        $workerArgString | Should -Match '-WorkloadName\s+Office'
        $workerArgString | Should -Match '-PollMarker\s+RigShift_InterceptorPoll'

        # next BeforeEach will restore in-proc defaults
    }

    It "activates FULL workload when user selects Yes" {
        $script:ActivationWaitTimeoutSeconds = 0
        $script:ActivationPollIntervalSeconds = 0

        Mock -CommandName Get-InterceptorWorkspaces -MockWith { $script:workspaces }

        # Fail required-only readiness first, then pick FULL in prompt.
        $requiredOnlyFailed = $true
        Mock -CommandName Test-InterceptorRuleActive -MockWith {
            $requiredOnlyFailed = $requiredOnlyFailed
            return $false
        }

        Mock -CommandName Show-InterceptorPrompt -MockWith { "Yes" }
        Mock -CommandName Start-RuleActivationFlow -MockWith { }
        Mock -CommandName Wait-ForInterceptorRuleActive -MockWith { $true }
        Mock -CommandName Start-Process -MockWith { }

        Invoke-Interceptor -TargetExe "C:/Program Files/Microsoft Office/root/Office16/WINWORD.EXE" -TargetArgs @()

        Assert-MockCalled -CommandName Start-RuleActivationFlow -Times 1 -Exactly -ParameterFilter {
            $WorkloadName -eq "Office" -and
            @($RequiredServices).Count -eq 1 -and
            @($RequiredServices)[0] -eq "ClickToRunSvc" -and
            @($RequiredExecutables).Count -ge 1
        }
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly
    }

    It "lists the required service when its startup type is Disabled" {
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "ClickToRunSvc") {
                return [pscustomobject]@{
                    Name                 = "ClickToRunSvc"
                    StartType            = "Disabled"
                    Status               = "Stopped"
                    ServicesDependedOn   = @()
                }
            }
            return $null
        }

        $blockers = @(Get-InterceptorDisabledServiceBlockers -ServiceName "ClickToRunSvc")
        $blockers.Count | Should -Be 1
        $blockers[0] | Should -Be "ClickToRunSvc"
    }

    It "lists a Disabled dependency before the required service when both are Disabled" {
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "ParentSvc") {
                return [pscustomobject]@{
                    Name                 = "ParentSvc"
                    StartType            = "Disabled"
                    Status               = "Stopped"
                    ServicesDependedOn   = @([pscustomobject]@{ Name = "DepSvc" })
                }
            }
            if ($Name -eq "DepSvc") {
                return [pscustomobject]@{
                    Name                 = "DepSvc"
                    StartType            = "Disabled"
                    Status               = "Stopped"
                    ServicesDependedOn   = @()
                }
            }
            return $null
        }

        $blockers = @(Get-InterceptorDisabledServiceBlockers -ServiceName "ParentSvc")
        $blockers.Count | Should -Be 2
        $blockers[0] | Should -Be "DepSvc"
        $blockers[1] | Should -Be "ParentSvc"
    }

    It "sets Disabled service to Manual and starts it when the user confirms" {
        $script:mockCtrStartType = "Disabled"
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "ClickToRunSvc") {
                return [pscustomobject]@{
                    Name                 = "ClickToRunSvc"
                    StartType            = $script:mockCtrStartType
                    Status               = "Stopped"
                    ServicesDependedOn   = @()
                }
            }
            return $null
        }
        Mock -CommandName Show-InterceptorDisabledServicePrompt -MockWith { "Yes" }
        $script:gsudoInterceptorLog = @()
        Mock -CommandName gsudo -MockWith {
            $line = $args -join " "
            $script:gsudoInterceptorLog += ,$line
            if ($line -match "^Set-Service -Name ClickToRunSvc -StartupType Manual") {
                $script:mockCtrStartType = "Manual"
            }
        }
        Mock -CommandName Start-Process -MockWith { }

        Start-RuleActivationFlow -RequiredServices @("ClickToRunSvc") -RequiredExecutables @() -WorkloadName "Office"

        @($script:gsudoInterceptorLog | Where-Object { $_ -match "Set-Service -Name ClickToRunSvc -StartupType Manual" }).Count | Should -Be 1
        @($script:gsudoInterceptorLog | Where-Object { $_ -match "Start-Service -Name ClickToRunSvc" }).Count | Should -Be 1
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly
        Remove-Variable -Name gsudoInterceptorLog -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name mockCtrStartType -Scope Script -ErrorAction SilentlyContinue
    }

    It "aborts activation without observe window when user aborts disabled-service prompt" {
        Mock -CommandName Get-Service -MockWith {
            param([string]$Name)
            if ($Name -eq "ClickToRunSvc") {
                return [pscustomobject]@{
                    Name                 = "ClickToRunSvc"
                    StartType            = "Disabled"
                    Status               = "Stopped"
                    ServicesDependedOn   = @()
                }
            }
            return $null
        }
        Mock -CommandName Show-InterceptorDisabledServicePrompt -MockWith { "Cancel" }
        Mock -CommandName gsudo -MockWith { throw "gsudo should not run after Cancel" }
        Mock -CommandName Start-Process -MockWith { }

        Start-RuleActivationFlow -RequiredServices @("ClickToRunSvc") -RequiredExecutables @() -WorkloadName "Office"

        Assert-MockCalled -CommandName Start-Process -Times 0 -Exactly
    }
}


