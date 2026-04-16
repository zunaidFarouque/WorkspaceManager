Set-StrictMode -Version Latest

Describe "Orchestrator Dictionary/Matrix Execution" {
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

    It "starts an App_Workload and executes executable strings" {
        @'
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Audio_Production": {
      "services": ["Audiosrv"],
      "executables": ["'C:/Program Files/Test App/App.exe' --hidden"]
    }
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null } | Should -Not -Throw

        $expectedExe = [System.IO.Path]::GetFullPath("C:/Program Files/Test App/App.exe")
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $expectedExe -and $ArgumentList -eq "--hidden"
        }
    }

    It "starts a System_Mode and formats Disable-PnpDevice EncodedCommand for OFF target" {
        @'
{
  "Hardware_Definitions": {
    "Wi_Fi_Adapter": {
      "type": "pnp_device",
      "match": ["*Wi-Fi*"]
    }
  },
  "System_Modes": {
    "Live_Stage_Life": {
      "targets": {
        "Wi_Fi_Adapter": "OFF"
      }
    }
  },
  "App_Workloads": {}
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "Live_Stage_Life" -Action "Start" | Out-Null } | Should -Not -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $encodedCalls.Count | Should -Be 1
        $encodedCalls[0] | Should -Match '\s-EncodedCommand\s+\S+'

        $encodedValue = ([regex]::Match($encodedCalls[0], '-EncodedCommand\s+(\S+)')).Groups[1].Value
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
        $decoded | Should -Be 'Get-PnpDevice -FriendlyName "*Wi-Fi*" -ErrorAction SilentlyContinue | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue'

        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "uses action_override_off instead of native command when desired state is OFF" {
        @'
{
  "Hardware_Definitions": {
    "Windows_Update": {
      "type": "service",
      "name": "wuauserv",
      "action_override_off": ["'C:/Scripts/DisableWU.ps1'"]
    }
  },
  "System_Modes": {
    "Live_Stage_Life": {
      "targets": {
        "Windows_Update": "OFF"
      }
    }
  },
  "App_Workloads": {}
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "Live_Stage_Life" -Action "Start" | Out-Null } | Should -Not -Throw

        $overrideFull = [System.IO.Path]::GetFullPath("C:/Scripts/DisableWU.ps1")
        $expectedPwshArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$overrideFull`""
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "pwsh.exe" -and
            $ArgumentList -eq $expectedPwshArgs -and
            $Wait -eq $true -and
            $NoNewWindow -eq $true
        }

        ($global:gsudoCalls | Where-Object { $_ -match 'Stop-Service -Name wuauserv' }).Count | Should -Be 0
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "routes Hardware_Override to a single hardware component and uses override action" {
        @'
{
  "Hardware_Definitions": {
    "Windows_Update": {
      "type": "service",
      "name": "wuauserv",
      "action_override_on": ["'C:/Scripts/EnableWU.ps1'"]
    }
  },
  "System_Modes": {},
  "App_Workloads": {}
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "Windows_Update" -Action "Start" -ProfileType "Hardware_Override" | Out-Null } | Should -Not -Throw

        $overrideFull = [System.IO.Path]::GetFullPath("C:/Scripts/EnableWU.ps1")
        $expectedPwshArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$overrideFull`""
        Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "pwsh.exe" -and
            $ArgumentList -eq $expectedPwshArgs -and
            $Wait -eq $true -and
            $NoNewWindow -eq $true
        }
        ($global:gsudoCalls | Where-Object { $_ -match 'Start-Service -Name wuauserv' }).Count | Should -Be 0
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "uses native Hardware_Override pnp command when no action override is defined" {
        @'
{
  "Hardware_Definitions": {
    "Bluetooth_Radio": {
      "type": "pnp_device",
      "match": ["*Bluetooth*"]
    }
  },
  "System_Modes": {},
  "App_Workloads": {}
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "Bluetooth_Radio" -Action "Start" -ProfileType "Hardware_Override" | Out-Null } | Should -Not -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $encodedCalls.Count | Should -Be 1
        $encodedValue = ([regex]::Match($encodedCalls[0], '-EncodedCommand\s+(\S+)')).Groups[1].Value
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
        $decoded | Should -Match 'Enable-PnpDevice'
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "skips Hardware_Override execution when target_state is ANY" {
        @'
{
  "Hardware_Definitions": {
    "Display_Refresh_Rate": {
      "type": "stateless",
      "target_state": "ANY"
    }
  },
  "System_Modes": {},
  "App_Workloads": {}
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "Display_Refresh_Rate" -Action "Start" -ProfileType "Hardware_Override" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName gsudo -Times 0 -Exactly
        Assert-MockCalled -CommandName Start-Process -Times 0 -Exactly
    }

    It "hardware override stop action maps directly to OFF for service targets" {
        @'
{
  "Hardware_Definitions": {
    "Search_Indexer": {
      "type": "service",
      "name": "WSearch"
    }
  },
  "System_Modes": {},
  "App_Workloads": {}
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "Search_Indexer" -Action "Stop" -ProfileType "Hardware_Override" | Out-Null } | Should -Not -Throw

        ($global:gsudoCalls | Where-Object { $_ -match 'Stop-Service -Name WSearch' }).Count | Should -Be 1
        ($global:gsudoCalls | Where-Object { $_ -match 'Start-Service -Name WSearch' }).Count | Should -Be 0
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "syncs managed IFEO debugger hooks when interceptors are enabled" {
@'
{
  "_config": {
    "enable_interceptors": true
  },
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "DAW_Cubase": {
      "services": ["Audiosrv"],
      "executables": ["'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe'"]
    },
    "Office": {
      "services": ["ClickToRunSvc"],
      "executables": ["'C:/Program Files/Microsoft OneDrive/OneDrive.exe'"],
      "intercepts": [
        {
          "exe": ["WINWORD.EXE", "EXCEL.EXE"],
          "requires": {
            "services": ["ClickToRunSvc"],
            "executables": []
          }
        }
      ]
    }
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-ChildItem -MockWith { @() }

        { & $script:scriptPath -WorkspaceName "Office" -Action "Start" | Out-Null } | Should -Not -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $encodedCalls.Count | Should -BeGreaterThan 0

        $decodedCalls = @(
            foreach ($call in $encodedCalls) {
                $encodedValue = ([regex]::Match($call, '-EncodedCommand\s+(\S+)')).Groups[1].Value
                [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
            }
        )

        (@($decodedCalls | Where-Object { $_ -match 'New-Item -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'New-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "Debugger"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'New-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "WorkspaceManager_Managed" -Value "1"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'Image File Execution Options\\EXCEL\.EXE' })).Count | Should -BeGreaterThan 0

        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "removes only managed IFEO debugger values when interceptors are disabled" {
@'
{
  "_config": {
    "enable_interceptors": false
  },
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {}
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        $global:gsudoCalls = @()
        Mock -CommandName gsudo -MockWith {
            $global:gsudoCalls += ,($args -join " ")
            "ok"
        }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-ChildItem -MockWith {
            @(
                [pscustomobject]@{ PSChildName = "WINWORD.EXE"; PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\WINWORD.EXE" },
                [pscustomobject]@{ PSChildName = "notepad.exe"; PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" }
            )
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param([string]$Path)
            if ($Path -match 'WINWORD\.EXE$') {
                return [pscustomobject]@{ WorkspaceManager_Managed = "1" }
            }
            return [pscustomobject]@{}
        }

        { & $script:scriptPath -WorkspaceName "MissingTarget" -Action "Start" } | Should -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $decodedCalls = @(
            foreach ($call in $encodedCalls) {
                $encodedValue = ([regex]::Match($call, '-EncodedCommand\s+(\S+)')).Groups[1].Value
                [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
            }
        )

        (@($decodedCalls | Where-Object { $_ -match 'Remove-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "Debugger"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'Remove-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "WorkspaceManager_Managed"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'notepad\.exe' })).Count | Should -Be 0

        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }
}
