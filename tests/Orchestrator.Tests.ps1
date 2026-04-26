Set-StrictMode -Version Latest

Describe "Orchestrator Dictionary/Matrix Execution" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        $script:scriptPath = Join-Path -Path $script:scriptsDir -ChildPath "Orchestrator.ps1"
        $script:dbPath = Join-Path -Path $script:scriptsDir -ChildPath "workspaces.json"
        $script:backupPath = Join-Path -Path $script:scriptsDir -ChildPath "workspaces.json.test-backup"
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
        $tmpExe = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-audio-{0}.exe" -f [Guid]::NewGuid().ToString("n"))
        try {
            New-Item -ItemType File -Path $tmpExe -Force | Out-Null
            $exeForJson = $tmpExe.Replace("\", "/")
            @"
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "Audio_Production": {
        "services": ["Audiosrv"],
        "executables": ["'$exeForJson' --hidden"]
      }
    }
  }
}
"@ | Set-Content -Path $script:dbPath -Encoding UTF8

            $global:mockAudioSvcPass = 0
            Mock -CommandName Get-Service -MockWith {
                $global:mockAudioSvcPass++
                if ($global:mockAudioSvcPass -eq 1) {
                    return [pscustomobject]@{
                        Name      = "Audiosrv"
                        Status    = [System.ServiceProcess.ServiceControllerStatus]::Stopped
                        StartType = [System.ServiceProcess.ServiceStartMode]::Manual
                    }
                }
                return [pscustomobject]@{
                    Name      = "Audiosrv"
                    Status    = [System.ServiceProcess.ServiceControllerStatus]::Running
                    StartType = [System.ServiceProcess.ServiceStartMode]::Manual
                }
            } -ParameterFilter { $Name -eq "Audiosrv" }

            Mock -CommandName gsudo -MockWith { }
            Mock -CommandName Start-Process -MockWith { }

            { & $script:scriptPath -WorkspaceName "Audio_Production" -Action "Start" | Out-Null } | Should -Not -Throw

            $expectedExe = [System.IO.Path]::GetFullPath($tmpExe)
            Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq $expectedExe -and $ArgumentList -eq "--hidden"
            }
        } finally {
            Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name mockAudioSvcPass -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "starts an App_Workload with executables only and no services property without throwing" {
        $tmpExe = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-exeonly-{0}.exe" -f [Guid]::NewGuid().ToString("n"))
        try {
            New-Item -ItemType File -Path $tmpExe -Force | Out-Null
            $exeForJson = $tmpExe.Replace("\", "/")
            @"
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Tools": {
      "ExecOnly": {
        "executables": ["'$exeForJson'"]
      }
    }
  }
}
"@ | Set-Content -Path $script:dbPath -Encoding UTF8

            Mock -CommandName gsudo -MockWith { }
            Mock -CommandName Start-Process -MockWith { }

            { & $script:scriptPath -WorkspaceName "ExecOnly" -Action "Start" -SkipInterceptorSync | Out-Null } | Should -Not -Throw

            $expectedExe = [System.IO.Path]::GetFullPath($tmpExe)
            Assert-MockCalled -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq $expectedExe
            }
        } finally {
            Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
        }
    }

    It "continues stop workflow when executable scoped manual gate timeout is reached" {
        $tmpExe = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-stop-gate-{0}.exe" -f [Guid]::NewGuid().ToString("n"))
        try {
            New-Item -ItemType File -Path $tmpExe -Force | Out-Null
            $exeForJson = $tmpExe.Replace("\", "/")
            @"
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Tools": {
      "VpnWorkload": {
        "services": ["TestSvc"],
        "executables": ["'$exeForJson'"],
        "stop_manual_gate_executables": {
          "enabled": true,
          "message": "Disconnect VPN now and press Space.",
          "timeout_seconds": 0,
          "confirm_key": "Space"
        }
      }
    }
  }
}
"@ | Set-Content -Path $script:dbPath -Encoding UTF8

            $global:mockSvcStopPass = 0
            Mock -CommandName Get-Service -MockWith {
                $global:mockSvcStopPass++
                if ($global:mockSvcStopPass -eq 1) {
                    return [pscustomobject]@{
                        Name      = "TestSvc"
                        Status    = [System.ServiceProcess.ServiceControllerStatus]::Running
                        StartType = [System.ServiceProcess.ServiceStartMode]::Manual
                    }
                }
                return [pscustomobject]@{
                    Name      = "TestSvc"
                    Status    = [System.ServiceProcess.ServiceControllerStatus]::Stopped
                    StartType = [System.ServiceProcess.ServiceStartMode]::Manual
                }
            } -ParameterFilter { $Name -eq "TestSvc" }

            $global:gsudoCalls = @()
            Mock -CommandName gsudo -MockWith {
                $global:gsudoCalls += ,($args -join " ")
                "ok"
            }
            Mock -CommandName Start-Sleep -MockWith { }
            $printed = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Write-Host -MockWith {
                param([object]$Object)
                if ($null -ne $Object) { $printed.Add([string]$Object) }
            }

            { & $script:scriptPath -WorkspaceName "VpnWorkload" -Action "Stop" -SkipInterceptorSync | Out-Null } | Should -Not -Throw

            (@($global:gsudoCalls | Where-Object { $_ -match 'taskkill /F /IM ' })).Count | Should -Be 1
            (@($global:gsudoCalls | Where-Object { $_ -match 'powershell -NoProfile -EncodedCommand' })).Count | Should -Be 1
            Assert-MockCalled -CommandName Start-Sleep -Times 0 -Exactly
            (@($printed | Where-Object { $_ -eq "Manual stop gate auto-continued after 0s." })).Count | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name mockSvcStopPass -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "uses executable-scoped gate for stop execution path" {
        $tmpExe = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-scope-gate-{0}.exe" -f [Guid]::NewGuid().ToString("n"))
        try {
            New-Item -ItemType File -Path $tmpExe -Force | Out-Null
            $exeForJson = $tmpExe.Replace("\", "/")
            @"
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Tools": {
      "ScopedGateWorkload": {
        "services": [],
        "executables": ["'$exeForJson'"],
        "stop_manual_gate": {
          "enabled": true,
          "message": "GENERIC gate message",
          "timeout_seconds": 0,
          "confirm_key": "Space"
        },
        "stop_manual_gate_executables": {
          "enabled": true,
          "message": "EXECUTABLE gate message",
          "timeout_seconds": 0,
          "confirm_key": "Space"
        }
      }
    }
  }
}
"@ | Set-Content -Path $script:dbPath -Encoding UTF8

            Mock -CommandName gsudo -MockWith { "ok" }
            $printed = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Write-Host -MockWith {
                param([object]$Object)
                if ($null -ne $Object) { $printed.Add([string]$Object) }
            }

            { & $script:scriptPath -WorkspaceName "ScopedGateWorkload" -Action "Stop" -ExecutionScope "ExecutablesOnly" -SkipInterceptorSync | Out-Null } | Should -Not -Throw

            (@($printed | Where-Object { $_ -eq "Manual stop gate auto-continued after 0s." })).Count | Should -Be 1
            (@($printed | Where-Object { $_ -eq "GENERIC gate message" })).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
        }
    }

    It "throws when elevated service start reports failure" {
        @'
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "Test_Workload": {
        "services": ["Audiosrv"],
        "executables": []
      }
    }
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName Get-Service -MockWith {
            return [pscustomobject]@{
                Name      = "Audiosrv"
                Status    = [System.ServiceProcess.ServiceControllerStatus]::Stopped
                StartType = [System.ServiceProcess.ServiceStartMode]::Manual
            }
        } -ParameterFilter { $Name -eq "Audiosrv" }

        $global:elevatedServiceMockHits = 0
        Mock -CommandName gsudo -MockWith {
            $joined = $args -join " "
            if ($joined -match "-EncodedCommand") {
                $global:elevatedServiceMockHits++
                throw "Failed to start service 'Audiosrv': simulated elevated failure"
            }
            "ok"
        }

        { & $script:scriptPath -WorkspaceName "Test_Workload" -Action "Start" -SkipInterceptorSync | Out-Null } | Should -Throw "*Failed to start service 'Audiosrv'*"
        $global:elevatedServiceMockHits | Should -BeGreaterThan 0
        Remove-Variable -Name elevatedServiceMockHits -Scope Global -ErrorAction SilentlyContinue
    }

    It "refuses to start when service startup type is disabled" {
        @'
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "Test_Workload": {
        "services": ["Audiosrv"],
        "executables": []
      }
    }
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName Get-Service -MockWith {
            return [pscustomobject]@{
                Name      = "Audiosrv"
                Status    = [System.ServiceProcess.ServiceControllerStatus]::Stopped
                StartType = [System.ServiceProcess.ServiceStartMode]::Disabled
            }
        } -ParameterFilter { $Name -eq "Audiosrv" }

        $global:gsudoElevateAttempts = 0
        Mock -CommandName gsudo -MockWith {
            $global:gsudoElevateAttempts++
            "ok"
        }

        { & $script:scriptPath -WorkspaceName "Test_Workload" -Action "Start" -SkipInterceptorSync | Out-Null } | Should -Throw "*disabled*"
        $global:gsudoElevateAttempts | Should -Be 0
        Remove-Variable -Name gsudoElevateAttempts -Scope Global -ErrorAction SilentlyContinue
    }

    It "throws when workload executable path is missing" {
        @'
{
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "X": {
        "services": [],
        "executables": ["'C:/This/Path/Should/Not/Exist/OrchMissing999.exe'"]
      }
    }
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }

        { & $script:scriptPath -WorkspaceName "X" -Action "Start" -SkipInterceptorSync | Out-Null } | Should -Throw "*does not exist*"
    }

    It "applies App_Workload hardware_targets when starting workload" {
        @'
{
  "Hardware_Definitions": {
    "Bluetooth_Radio": {
      "type": "pnp_device",
      "match": ["*Bluetooth*"]
    }
  },
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "DAW_Cubase": {
        "services": [],
        "executables": [],
        "hardware_targets": {
          "Bluetooth_Radio": "OFF"
        }
      }
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

        { & $script:scriptPath -WorkspaceName "DAW_Cubase" -Action "Start" | Out-Null } | Should -Not -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $encodedCalls.Count | Should -Be 1
        $encodedValue = ([regex]::Match($encodedCalls[0], '-EncodedCommand\s+(\S+)')).Groups[1].Value
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
        $decoded | Should -Match 'Disable-PnpDevice'
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "treats omitted App_Workload hardware target as ANY and skips hardware transition" {
        @'
{
  "Hardware_Definitions": {
    "Bluetooth_Radio": {
      "type": "pnp_device",
      "match": ["*Bluetooth*"]
    }
  },
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "DAW_Cubase": {
        "services": [],
        "executables": []
      }
    }
  }
}
'@ | Set-Content -Path $script:dbPath -Encoding UTF8

        Mock -CommandName gsudo -MockWith { }
        Mock -CommandName Start-Process -MockWith { }

        { & $script:scriptPath -WorkspaceName "DAW_Cubase" -Action "Start" | Out-Null } | Should -Not -Throw

        Assert-MockCalled -CommandName gsudo -Times 0 -Exactly
        Assert-MockCalled -CommandName Start-Process -Times 0 -Exactly
    }

    It "expands @alias hardware target key to wildcard component match" {
        @'
{
  "Hardware_Definitions": {
    "Bluetooth_Radio": {
      "type": "pnp_device",
      "match": ["*Bluetooth*"]
    }
  },
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "DAW_Cubase": {
        "services": [],
        "executables": [],
        "hardware_targets": {
          "@bluetooth": "OFF"
        }
      }
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

        { & $script:scriptPath -WorkspaceName "DAW_Cubase" -Action "Start" | Out-Null } | Should -Not -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $encodedCalls.Count | Should -Be 1
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "expands @alias wildcard to multiple hardware components deterministically" {
        @'
{
  "Hardware_Definitions": {
    "Bluetooth_Radio": {
      "type": "pnp_device",
      "match": ["*Bluetooth*"]
    },
    "Bluetooth_LE": {
      "type": "pnp_device",
      "match": ["*Bluetooth LE*"]
    }
  },
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "DAW_Cubase": {
        "services": [],
        "executables": [],
        "hardware_targets": {
          "@bluetooth": "OFF"
        }
      }
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

        { & $script:scriptPath -WorkspaceName "DAW_Cubase" -Action "Start" | Out-Null } | Should -Not -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $encodedCalls.Count | Should -Be 2
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "starts a System_Mode and formats Disable-PnpDevice EncodedCommand for OFF hardware target" {
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
      "hardware_targets": {
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

    It "uses action_override_off instead of native command when desired hardware state is OFF" {
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
      "hardware_targets": {
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
        Mock -CommandName Test-Path -MockWith { $true } -ParameterFilter {
            $LiteralPath -like "*DisableWU.ps1"
        }

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
        Mock -CommandName Test-Path -MockWith { $true } -ParameterFilter {
            $LiteralPath -like "*EnableWU.ps1"
        }

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

        $global:mockWSearchPass = 0
        Mock -CommandName Get-Service -MockWith {
            $global:mockWSearchPass++
            if ($global:mockWSearchPass -eq 1) {
                return [pscustomobject]@{
                    Name      = "WSearch"
                    Status    = [System.ServiceProcess.ServiceControllerStatus]::Running
                    StartType = [System.ServiceProcess.ServiceStartMode]::Automatic
                }
            }
            return [pscustomobject]@{
                Name      = "WSearch"
                Status    = [System.ServiceProcess.ServiceControllerStatus]::Stopped
                StartType = [System.ServiceProcess.ServiceStartMode]::Automatic
            }
        } -ParameterFilter { $Name -eq "WSearch" }

        { & $script:scriptPath -WorkspaceName "Search_Indexer" -Action "Stop" -ProfileType "Hardware_Override" | Out-Null } | Should -Not -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match 'powershell -NoProfile -EncodedCommand' })
        $encodedCalls.Count | Should -Be 1
        $encodedValue = ([regex]::Match($encodedCalls[0], '-EncodedCommand\s+(\S+)')).Groups[1].Value
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
        $decoded | Should -Match 'Stop-Service'
        $decoded | Should -Match 'WSearch'
        $decoded | Should -Not -Match 'Start-Service'
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name mockWSearchPass -Scope Global -ErrorAction SilentlyContinue
    }

    It "skips interceptor sync when SkipInterceptorSync is provided" {
        @'
{
  "_config": {
    "enable_interceptors": true
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

        { & $script:scriptPath -WorkspaceName "__MISSING__" -Action "Start" -SkipInterceptorSync | Out-Null } | Should -Throw "Fatal: Workspace '__MISSING__' not defined in workspaces.json."

        $global:gsudoCalls.Count | Should -Be 0
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "syncs managed IFEO debugger hooks when interceptors are enabled" {
        $tmpOfficeExe = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-office-{0}.exe" -f [Guid]::NewGuid().ToString("n"))
        try {
            New-Item -ItemType File -Path $tmpOfficeExe -Force | Out-Null
            $officeExeJson = $tmpOfficeExe.Replace("\", "/")
            $officeJson = @"
{
  "_config": {
    "enable_interceptors": true
  },
  "Hardware_Definitions": {},
  "System_Modes": {},
  "App_Workloads": {
    "Audio": {
      "DAW_Cubase": {
        "services": ["Audiosrv"],
        "executables": ["'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe'"]
      }
    },
    "Office": {
      "Office": {
        "services": ["ClickToRunSvc"],
        "executables": ["'$officeExeJson'"],
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
}
"@
            Set-Content -Path $script:dbPath -Value $officeJson -Encoding UTF8

            $global:mockCtrPass = 0
            Mock -CommandName Get-Service -MockWith {
                $global:mockCtrPass++
                if ($global:mockCtrPass -eq 1) {
                    return [pscustomobject]@{
                        Name      = "ClickToRunSvc"
                        Status    = [System.ServiceProcess.ServiceControllerStatus]::Stopped
                        StartType = [System.ServiceProcess.ServiceStartMode]::Manual
                    }
                }
                return [pscustomobject]@{
                    Name      = "ClickToRunSvc"
                    Status    = [System.ServiceProcess.ServiceControllerStatus]::Running
                    StartType = [System.ServiceProcess.ServiceStartMode]::Manual
                }
            } -ParameterFilter { $Name -eq "ClickToRunSvc" }

            $global:gsudoCalls = @()
            Mock -CommandName gsudo -MockWith {
                $global:gsudoCalls += ,($args -join " ")
                "ok"
            }
            Mock -CommandName Start-Process -MockWith { }
            Mock -CommandName Get-ChildItem -MockWith { @() }

            { & $script:scriptPath -WorkspaceName "Office" -Action "Start" | Out-Null } | Should -Not -Throw
        } finally {
            Remove-Item -LiteralPath $tmpOfficeExe -Force -ErrorAction SilentlyContinue
        }

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
        (@($decodedCalls | Where-Object { $_ -match 'New-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_Managed" -Value "1"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'New-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_Owner" -Value "BG-Services-Orchestrator"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'New-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_InterceptorVersion" -Value "1"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'New-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_LastSyncedUtc"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'Image File Execution Options\\EXCEL\.EXE' })).Count | Should -BeGreaterThan 0

        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name mockCtrPass -Scope Global -ErrorAction SilentlyContinue
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
            param([string]$Path, [string]$Name)
            if ($Path -match 'WINWORD\.EXE$') {
                if ($Name -eq "RigShift_Managed") {
                    return [pscustomobject]@{ RigShift_Managed = "1" }
                }
                if ($Name -eq "RigShift_Owner") {
                    return [pscustomobject]@{ RigShift_Owner = "BG-Services-Orchestrator" }
                }
                return [pscustomobject]@{}
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
        (@($decodedCalls | Where-Object { $_ -match 'Remove-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_Managed"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'Remove-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_Owner"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'Remove-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_InterceptorVersion"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'Remove-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\WINWORD\.EXE" -Name "RigShift_LastSyncedUtc"' })).Count | Should -Be 1
        (@($decodedCalls | Where-Object { $_ -match 'notepad\.exe' })).Count | Should -Be 0

        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "removes managed legacy hooks even when owner metadata is missing" {
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
            @([pscustomobject]@{ PSChildName = "EXCEL.EXE"; PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\EXCEL.EXE" })
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param([string]$Path, [string]$Name)
            if ($Name -eq "RigShift_Managed") {
                return [pscustomobject]@{ RigShift_Managed = "1" }
            }
            return $null
        }

        { & $script:scriptPath -WorkspaceName "MissingTarget" -Action "Start" } | Should -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $decodedCalls = @(
            foreach ($call in $encodedCalls) {
                $encodedValue = ([regex]::Match($call, '-EncodedCommand\s+(\S+)')).Groups[1].Value
                [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
            }
        )

        (@($decodedCalls | Where-Object { $_ -match 'Image File Execution Options\\EXCEL\.EXE' })).Count | Should -Be 1
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "does not remove managed hooks owned by a different owner tag" {
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
            @([pscustomobject]@{ PSChildName = "POWERPNT.EXE"; PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\POWERPNT.EXE" })
        }
        Mock -CommandName Get-ItemProperty -MockWith {
            param([string]$Path, [string]$Name)
            if ($Name -eq "RigShift_Managed") {
                return [pscustomobject]@{ RigShift_Managed = "1" }
            }
            if ($Name -eq "RigShift_Owner") {
                return [pscustomobject]@{ RigShift_Owner = "AnotherOwner" }
            }
            return $null
        }

        { & $script:scriptPath -WorkspaceName "MissingTarget" -Action "Start" } | Should -Throw

        $encodedCalls = @($global:gsudoCalls | Where-Object { $_ -match '^-?powershell -NoProfile -EncodedCommand ' -or $_ -match '^powershell -NoProfile -EncodedCommand ' })
        $decodedCalls = @(
            foreach ($call in $encodedCalls) {
                $encodedValue = ([regex]::Match($call, '-EncodedCommand\s+(\S+)')).Groups[1].Value
                [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedValue))
            }
        )

        (@($decodedCalls | Where-Object { $_ -match 'Image File Execution Options\\POWERPNT\.EXE' })).Count | Should -Be 0
        Remove-Variable -Name gsudoCalls -Scope Global -ErrorAction SilentlyContinue
    }
}


