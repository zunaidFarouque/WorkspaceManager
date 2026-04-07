Set-StrictMode -Version Latest

Describe "WorkspaceManager Phase 1 - Ingestion and Input Sanitization" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:scriptPath = Join-Path -Path $script:here -ChildPath "Orchestrator.ps1"
        $script:dbPath = Join-Path -Path $script:here -ChildPath "workspaces.json"
        $script:backupPath = Join-Path -Path $script:here -ChildPath "workspaces.json.test-backup"
    }

    BeforeEach {
        if (Test-Path -Path $script:backupPath) {
            Remove-Item -Path $script:backupPath -Force
        }

        if (Test-Path -Path $script:dbPath) {
            Move-Item -Path $script:dbPath -Destination $script:backupPath -Force
        }
    }

    AfterEach {
        if (Test-Path -Path $script:dbPath) {
            Remove-Item -Path $script:dbPath -Force
        }

        if (Test-Path -Path $script:backupPath) {
            Move-Item -Path $script:backupPath -Destination $script:dbPath -Force
        }
    }

    It "throws a fatal error when workspaces.json is missing" {
        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" } |
            Should -Throw "Fatal: workspaces.json not found."
    }

    It "throws a detailed parsing error when workspaces.json is malformed" {
        @'
{
  "Audio_Production": {
    "protected_processes": ["Cubase12.exe",],
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $caughtMessage = $null
        try {
            & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start"
        } catch {
            $caughtMessage = $_.Exception.Message
        }

        $caughtMessage | Should -Not -BeNullOrEmpty
        $caughtMessage | Should -Match "^Fatal: Failed to parse workspaces\.json\."
        $caughtMessage | Should -Match "(?i)(line|position|bytepositioninline|linenumber|path|trailing|invalid)"
    }

    It "throws a fatal error when requested workspace is not defined" {
        @'
{
  "Audio_Production": {
    "protected_processes": ["Cubase12.exe", "WINWORD"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        { & $script:scriptPath -WorkspaceName "MissingWorkspace" -Action "Stop" } |
            Should -Throw "Fatal: Workspace 'MissingWorkspace' not defined in workspaces.json."
    }

    It "ignores _config metadata and still acquires a real workspace" {
        @'
{
  "_config": {
    "notifications": true
  },
  "Audio_Production": {
    "protected_processes": ["Cubase12.exe"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $result = & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start"

        $result | Should -Not -BeNullOrEmpty
        $result.protected_processes | Should -Be @("Cubase12")
    }

    It "sanitizes protected_processes by stripping only .exe suffixes" {
        @'
{
  "Audio_Production": {
    "protected_processes": ["Cubase12.exe", "WINWORD", "explorer.EXE"],
    "reverse_relations": ["wuauserv"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $result = & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start"

        $result | Should -Not -BeNullOrEmpty
        $result.protected_processes | Should -Be @("Cubase12", "WINWORD", "explorer")
    }
}

Describe "Phase 2 - Pre-Flight Safety Checks" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:scriptPath = Join-Path -Path $script:here -ChildPath "Orchestrator.ps1"
        $script:dbPath = Join-Path -Path $script:here -ChildPath "workspaces.json"
        $script:backupPath = Join-Path -Path $script:here -ChildPath "workspaces.json.test-backup"
    }

    BeforeEach {
        if (Test-Path -Path $script:backupPath) {
            Remove-Item -Path $script:backupPath -Force
        }

        if (Test-Path -Path $script:dbPath) {
            Move-Item -Path $script:dbPath -Destination $script:backupPath -Force
        }
    }

    AfterEach {
        if (Test-Path -Path $script:dbPath) {
            Remove-Item -Path $script:dbPath -Force
        }

        if (Test-Path -Path $script:backupPath) {
            Move-Item -Path $script:backupPath -Destination $script:dbPath -Force
        }
    }

    It "does not call Get-Process when action is Start" {
        @'
{
  "Audio_Production": {
    "protected_processes": ["Cubase12.exe", "WINWORD"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName Get-Process -MockWith { @([pscustomobject]@{ Name = "Cubase12" }) }

        {
            & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null
        } | Should -Not -Throw

        Assert-MockCalled -CommandName Get-Process -Times 0 -Exactly
    }

    It "aborts when action is Stop, protected process is active, and user answers N" {
        @'
{
  "Audio_Production": {
    "protected_processes": ["Cubase12.exe", "WINWORD"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName Get-Process -MockWith { @([pscustomobject]@{ Name = "Cubase12" }) }
        Mock -CommandName Read-Host -MockWith { "N" }

        {
            & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Stop" | Out-Null
        } | Should -Throw "Abort: User cancelled teardown due to active protected process."
    }

    It "continues when action is Stop, protected process is active, and user answers Y" {
        @'
{
  "Audio_Production": {
    "protected_processes": ["Cubase12.exe", "WINWORD"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName Get-Process -MockWith { @([pscustomobject]@{ Name = "Cubase12" }) }
        Mock -CommandName Read-Host -MockWith { "Y" }

        $didThrow = $false
        $result = $null
        try {
            $result = & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Stop"
        } catch {
            $didThrow = $true
        }

        $didThrow | Should -BeFalse
        $result | Should -Not -BeNullOrEmpty
        $result.protected_processes | Should -Be @("Cubase12", "WINWORD")
    }
}

Describe "Phase 3 - The Start Pipeline" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:scriptPath = Join-Path -Path $script:here -ChildPath "Orchestrator.ps1"
        $script:dbPath = Join-Path -Path $script:here -ChildPath "workspaces.json"
        $script:backupPath = Join-Path -Path $script:here -ChildPath "workspaces.json.test-backup"
    }

    BeforeEach {
        if (Test-Path -Path $script:backupPath) {
            Remove-Item -Path $script:backupPath -Force
        }

        if (Test-Path -Path $script:dbPath) {
            Move-Item -Path $script:dbPath -Destination $script:backupPath -Force
        }

        function gsudo { }
    }

    AfterEach {
        if (Test-Path -Path $script:dbPath) {
            Remove-Item -Path $script:dbPath -Force
        }

        if (Test-Path -Path $script:backupPath) {
            Move-Item -Path $script:backupPath -Destination $script:dbPath -Force
        }

        if (Test-Path Function:\gsudo) {
            Remove-Item Function:\gsudo
        }
    }

    It "parses timer tokens and calls Start-Sleep -Milliseconds 3000" {
        @'
{
  "Audio_Production": {
    "services": ["t 3000"],
    "executables": ["t 3000"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName Start-Sleep -Times 2 -Exactly -ParameterFilter { $Milliseconds -eq 3000 }
    }

    It "starts services and exits polling loop when service becomes Running" {
        @'
{
  "Audio_Production": {
    "services": ["Audiosrv"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Start-Process -MockWith { }

        $global:servicePollCount = 0
        Mock -CommandName Get-Service -MockWith {
            $global:servicePollCount++
            if ($global:servicePollCount -eq 1) {
                [pscustomobject]@{ Status = "StartPending" }
            } else {
                [pscustomobject]@{ Status = "Running" }
            }
        }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName gsudo -Times 2 -Exactly
        Assert-MockCalled -CommandName Get-Service -Times 2 -Exactly -ParameterFilter { $Name -eq "Audiosrv" }
        Remove-Variable -Name servicePollCount -Scope Global -ErrorAction SilentlyContinue
    }

    It "parses quoted executable with arguments and calls Start-Process correctly" {
        @'
{
  "Audio_Production": {
    "executables": ["'C:/My App.exe' --hidden"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "C:/My App.exe" -and $ArgumentList -eq "--hidden"
        }
    }

    It "parses unquoted executable without arguments and calls Start-Process with empty args" {
        @'
{
  "Audio_Production": {
    "executables": ["C:/App.exe"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq "C:/App.exe" }
    }

    It "calls Show-Notification at the end of a successful Start when notifications are enabled" {
        @'
{
  "_config": {
    "notifications": true
  },
  "Audio_Production": {
    "executables": ["C:/App.exe"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        function Show-Notification { param([string]$Title, [string]$Message) }
        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }
        Mock -CommandName Show-Notification -MockWith { }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName Show-Notification -Times 1 -Exactly -ParameterFilter {
            $Title -eq "Workspace Ready" -and $Message -eq "Audio_Production is now active."
        }

        if (Test-Path Function:\Show-Notification) {
            Remove-Item Function:\Show-Notification
        }
    }
}

Describe "Phase 4 - The Stop Pipeline" {
    BeforeAll {
        $script:here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:scriptPath = Join-Path -Path $script:here -ChildPath "Orchestrator.ps1"
        $script:dbPath = Join-Path -Path $script:here -ChildPath "workspaces.json"
        $script:backupPath = Join-Path -Path $script:here -ChildPath "workspaces.json.test-backup"
    }

    BeforeEach {
        if (Test-Path -Path $script:backupPath) {
            Remove-Item -Path $script:backupPath -Force
        }

        if (Test-Path -Path $script:dbPath) {
            Move-Item -Path $script:dbPath -Destination $script:backupPath -Force
        }

        function gsudo { }
    }

    AfterEach {
        if (Test-Path -Path $script:dbPath) {
            Remove-Item -Path $script:dbPath -Force
        }

        if (Test-Path -Path $script:backupPath) {
            Move-Item -Path $script:backupPath -Destination $script:dbPath -Force
        }

        if (Test-Path Function:\gsudo) {
            Remove-Item Function:\gsudo
        }
    }

    It "executes executable taskkill calls in reverse order" {
        @'
{
  "Audio_Production": {
    "executables": ["C:/First.exe", "C:/Second.exe"],
    "protected_processes": []
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Stop" | Out-Null } | Should -Not -Throw

        $taskkillCalls = @($global:gsudoCalls | Where-Object { $_ -like "taskkill*" })
        $taskkillCalls.Count | Should -Be 2
        $taskkillCalls[0] | Should -Match "Second\.exe"
        $taskkillCalls[1] | Should -Match "First\.exe"
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "extracts executable leaf name from quoted path and uses it in taskkill" {
        @'
{
  "Audio_Production": {
    "executables": ["'C:/My App.exe' --hidden"],
    "protected_processes": []
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Stop" | Out-Null } | Should -Not -Throw

        $taskkillCalls = @($global:gsudoCalls | Where-Object { $_ -like "taskkill*" })
        $taskkillCalls.Count | Should -Be 1
        $taskkillCalls[0] | Should -Match "taskkill /F /IM My App\.exe /T"
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "starts reverse_relations services in forward order with demand config then net start" {
        @'
{
  "Audio_Production": {
    "protected_processes": [],
    "reverse_relations": ["SvcOne", "SvcTwo"]
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Service -MockWith { [pscustomobject]@{ Status = "Running" } }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Stop" | Out-Null } | Should -Not -Throw

        $reverseCalls = @($global:gsudoCalls | Where-Object { $_ -like "sc config Svc* start= demand" -or $_ -like "net start Svc*" })
        $reverseCalls.Count | Should -Be 4
        $reverseCalls[0] | Should -Be "sc config SvcOne start= demand"
        $reverseCalls[1] | Should -Be "net start SvcOne"
        $reverseCalls[2] | Should -Be "sc config SvcTwo start= demand"
        $reverseCalls[3] | Should -Be "net start SvcTwo"
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "calls Show-Notification at the end of a successful Stop when notifications are enabled" {
        @'
{
  "_config": {
    "notifications": true
  },
  "Audio_Production": {
    "protected_processes": [],
    "executables": [],
    "services": []
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        function Show-Notification { param([string]$Title, [string]$Message) }
        Mock -CommandName gsudo -MockWith { "ok" }
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Get-Process -MockWith { $null }
        Mock -CommandName Show-Notification -MockWith { }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Stop" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName Show-Notification -Times 1 -Exactly -ParameterFilter {
            $Title -eq "Workspace Stopped" -and $Message -eq "Audio_Production has been cleanly terminated."
        }

        if (Test-Path Function:\Show-Notification) {
            Remove-Item Function:\Show-Notification
        }
    }
}
