Set-StrictMode -Version Latest

Describe "Dashboard Global Commit Sequencer" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "resolves effective hardware targets with precedence App over Mode" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    hardware_targets = [pscustomobject]@{
                        Bluetooth_Radio = "ON"
                    }
                }
            }
            App_Workloads = [pscustomobject]@{}
        }
        $modeStates = @(
            [pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" }
        )
        $workloadStates = @(
            [pscustomobject]@{
                Name = "DAW_Cubase"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Audio"
                HardwareTargets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
            }
        )

        $effective = Resolve-DashboardEffectiveHardwareTargets -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{} -IncludeSystemModeHardware
        $effective["Bluetooth_Radio"] | Should -Be "OFF"
    }

    It "resolves explicit queue over system mode hardware for the same component" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    hardware_targets = [pscustomobject]@{ Bluetooth_Radio = "ON" }
                }
            }
            App_Workloads = [pscustomobject]@{}
        }
        $modeStates = @(
            [pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" }
        )
        $workloadStates = @(
            [pscustomobject]@{ Name = "Office"; CurrentState = "Inactive"; DesiredState = "Inactive"; ProfileType = "App_Workload"; Domain = "Office" }
        )
        $pending = @{ Bluetooth_Radio = "OFF" }

        $effective = Resolve-DashboardEffectiveHardwareTargets -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges $pending -IncludeSystemModeHardware
        $effective["Bluetooth_Radio"] | Should -Be "OFF"
    }

    It "builds global operations in fixed seven-phase order" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
                Wi_Fi_Adapter = [pscustomobject]@{ type = "pnp_device"; match = @("*Wi-Fi*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    power_plan = "Max Performance"
                    hardware_targets = [pscustomobject]@{
                        Bluetooth_Radio = "OFF"
                        Wi_Fi_Adapter = "ON"
                    }
                }
            }
            App_Workloads = [pscustomobject]@{}
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "Office"; CurrentState = "Active"; DesiredState = "Inactive"; ProfileType = "App_Workload"; Domain = "Office" },
            [pscustomobject]@{ Name = "DAW_Cubase"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Audio" }
        )
        $pending = @{
            Bluetooth_Radio = "OFF"
            Wi_Fi_Adapter  = "ON"
        }

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges $pending)
        @($ops | Select-Object -ExpandProperty Phase | Get-Unique) | Should -Be @(1,2,3,4,5,6,7)
    }

    It "adds stable reason metadata to planned operations" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    power_plan = "Max Performance"
                }
            }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @([pscustomobject]@{ Name = "Office"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Office" })
        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{ Bluetooth_Radio = "OFF" })

        @($ops | Where-Object { [string]$_.Reason -eq "" }).Count | Should -Be 0
        @($ops | Where-Object { $_.WorkspaceName -eq "Office" -and $_.Reason -eq "Start Office" }).Count | Should -BeGreaterThan 0
        @($ops | Where-Object { $_.WorkspaceName -eq "Live_Stage_Life" -and $_.Reason -eq "Apply mode Live_Stage_Life" }).Count | Should -Be 1
    }

    It "workload_only_toggle_does_not_expand_mode_hardware_targets" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
                Wi_Fi_Adapter   = [pscustomobject]@{ type = "pnp_device"; match = @("*Wi-Fi*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    power_plan         = "Max Performance"
                    hardware_targets   = [pscustomobject]@{
                        Bluetooth_Radio = "OFF"
                        Wi_Fi_Adapter   = "ON"
                    }
                }
            }
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services    = @("ClickToRunSvc")
                        executables = @("ONEDRIVE")
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "Office"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Office" }
        )

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{})
        $hwOps = @($ops | Where-Object { $_.Phase -eq 3 -or $_.Phase -eq 5 })
        $hwOps.Count | Should -Be 0
        @($ops | Where-Object { $_.Phase -eq 4 }).Count | Should -Be 0
        @($ops | Where-Object { $_.WorkspaceName -eq "Office" -and $_.Phase -eq 6 }).Count | Should -Be 1
        @($ops | Where-Object { $_.WorkspaceName -eq "Office" -and $_.Phase -eq 7 }).Count | Should -Be 1
    }

    It "omits Start ServicesOnly when workload JSON has no services" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Tools = [pscustomobject]@{
                    ExecOnly = [pscustomobject]@{
                        executables = @("'C:/fake/app.exe'")
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "ExecOnly"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Tools" }
        )
        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{})
        @($ops | Where-Object { $_.WorkspaceName -eq "ExecOnly" -and $_.Phase -eq 6 }).Count | Should -Be 0
        @($ops | Where-Object { $_.WorkspaceName -eq "ExecOnly" -and $_.Phase -eq 7 }).Count | Should -Be 1
    }

    It "omits Start ExecutablesOnly when workload JSON has no executables" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Tools = [pscustomobject]@{
                    SvcOnly = [pscustomobject]@{
                        services = @("SomeSvc")
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Eco_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "SvcOnly"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Tools" }
        )
        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{})
        @($ops | Where-Object { $_.WorkspaceName -eq "SvcOnly" -and $_.Phase -eq 6 }).Count | Should -Be 1
        @($ops | Where-Object { $_.WorkspaceName -eq "SvcOnly" -and $_.Phase -eq 7 }).Count | Should -Be 0
    }

    It "mode_change_without_queue_applies_powerplan_only" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    power_plan       = "Max Performance"
                    hardware_targets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
                }
            }
            App_Workloads = [pscustomobject]@{}
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "Office"; CurrentState = "Inactive"; DesiredState = "Inactive"; ProfileType = "App_Workload"; Domain = "Office" }
        )

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{})
        @($ops | Where-Object { $_.Phase -eq 4 -and $_.ExecutionScope -eq "PowerPlanOnly" }).Count | Should -Be 1
        @($ops | Where-Object { $_.Phase -eq 3 -or $_.Phase -eq 5 }).Count | Should -Be 0
    }

    It "mode_change_with_queued_hardware_applies_phase3_phase5 (Tab 2 **A** or Tab 3 queue)" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
                Wi_Fi_Adapter   = [pscustomobject]@{ type = "pnp_device"; match = @("*Wi-Fi*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    power_plan       = "Max Performance"
                    hardware_targets = [pscustomobject]@{
                        Bluetooth_Radio = "OFF"
                        Wi_Fi_Adapter   = "ON"
                    }
                }
            }
            App_Workloads = [pscustomobject]@{}
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "Office"; CurrentState = "Inactive"; DesiredState = "Inactive"; ProfileType = "App_Workload"; Domain = "Office" }
        )
        $pending = @{ Bluetooth_Radio = "OFF"; Wi_Fi_Adapter = "ON" }

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges $pending)
        @($ops | Where-Object { $_.Phase -eq 3 -and $_.WorkspaceName -eq "Bluetooth_Radio" }).Count | Should -Be 1
        @($ops | Where-Object { $_.Phase -eq 5 -and $_.WorkspaceName -eq "Wi_Fi_Adapter" }).Count | Should -Be 1
        @($ops | Where-Object { $_.Phase -eq 4 }).Count | Should -Be 1
    }

    It "workload_explicit_hardware_targets_override_queued_mode_targets" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    hardware_targets = [pscustomobject]@{ Bluetooth_Radio = "ON" }
                }
            }
            App_Workloads = [pscustomobject]@{
                Audio = [pscustomobject]@{
                    DAW_Cubase = [pscustomobject]@{
                        hardware_targets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "DAW_Cubase"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Audio" }
        )
        $pending = @{ Bluetooth_Radio = "ON" }

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges $pending)
        @($ops | Where-Object { $_.Phase -eq 5 }).Count | Should -Be 0
        @($ops | Where-Object { $_.Phase -eq 3 -and $_.WorkspaceName -eq "Bluetooth_Radio" }).Count | Should -Be 1
    }

    It "prompts for confirmation when unresolved alias warnings exist" {
        $warnings = @("Unresolved alias '@bluetooth' in workload 'DAW_Cubase'.")
        $result = Confirm-DashboardWarningsBeforeCommit -Warnings $warnings -ReadKeyScript { [pscustomobject]@{ Key = [ConsoleKey]::Y } }
        $result | Should -BeTrue
    }

    It "derives mode post-commit messages from operation candidates when pending states are empty" {
        $operations = @(
            [pscustomobject]@{
                Phase = 4
                WorkspaceName = "Live_Stage_Life"
                ProfileType = "System_Mode"
                Action = "Start"
                ExecutionScope = "PowerPlanOnly"
            }
        )
        $workspaces = [pscustomobject]@{
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{
                    post_change_message = "Mode switched."
                    post_start_message = "Live mode engaged."
                }
            }
            Hardware_Definitions = [pscustomobject]@{}
        }

        $candidates = Convert-DashboardOperationsToMessageStates -Operations $operations
        $result = @(Get-DashboardPostCommitMessages -UIStates $candidates -Workspaces $workspaces)

        $result.Count | Should -Be 2
        $result[0] | Should -Be "[Live_Stage_Life] Mode switched."
        $result[1] | Should -Be "[Live_Stage_Life] Live mode engaged."
    }

    It "deduplicates message candidates produced from multi-phase operations" {
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "DAW_Cubase"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "DAW_Cubase"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly" }
        )
        $states = @(Convert-DashboardOperationsToMessageStates -Operations $operations)
        $states.Count | Should -Be 1
        $states[0].Name | Should -Be "DAW_Cubase"
        $states[0].DesiredState | Should -Be "Active"
    }

    It "converts workload-only scoped operations to message candidates without hardware rows" {
        $operations = @(
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly" }
        )
        $states = @(Convert-DashboardOperationsToMessageStates -Operations $operations)
        @($states | Where-Object { $_.ProfileType -eq "Hardware_Override" }).Count | Should -Be 0
        @($states | Where-Object { $_.ProfileType -eq "System_Mode" }).Count | Should -Be 0
        $states.Count | Should -Be 1
        $states[0].Name | Should -Be "Office"
    }

    It "maps operation phases to intent section labels in order" {
        @(1,2,3,4,5,6,7 | ForEach-Object { Get-DashboardCommitSectionTitle -Phase $_ }) | Should -Be @(
            "STOPPING EXECUTABLES",
            "STOPPING SERVICES",
            "STOPPING HARDWARE",
            "APPLYING POWER PLAN",
            "STARTING HARDWARE",
            "STARTING SERVICES",
            "STARTING EXECUTABLES"
        )
    }

    It "builds progress rows with ordered sections and mapped task rows" {
        $operations = @(
            [pscustomobject]@{ Phase = 3; WorkspaceName = "Bluetooth_Radio"; ProfileType = "Hardware_Override"; Action = "Stop"; ExecutionScope = "All"; Reason = "Start Office" },
            [pscustomobject]@{ Phase = 6; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ServicesOnly"; Reason = "Start Office" },
            [pscustomobject]@{ Phase = 7; WorkspaceName = "Office"; ProfileType = "App_Workload"; Action = "Start"; ExecutionScope = "ExecutablesOnly"; Reason = "Start Office" }
        )
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{}
            App_Workloads = [pscustomobject]@{
                Office = [pscustomobject]@{
                    Office = [pscustomobject]@{
                        services = @("ClickToRunSvc")
                        executables = @("ONEDRIVE")
                    }
                }
            }
        }

        $rows = @(New-DashboardCommitProgressRows -Operations $operations -Workspaces $workspaces)
        @($rows | Where-Object { $_.RowType -eq "Section" } | Select-Object -ExpandProperty Section) | Should -Be @(
            "STOPPING HARDWARE",
            "STARTING SERVICES",
            "STARTING EXECUTABLES"
        )
        @($rows | Where-Object { $_.RowType -eq "Task" -and $_.Section -eq "STARTING SERVICES" -and $_.TaskText -eq "starting service ClickToRunSvc" }).Count | Should -Be 1
        @($rows | Where-Object { $_.RowType -eq "Task" -and $_.Section -eq "STARTING EXECUTABLES" -and $_.TaskText -eq "starting executable ONEDRIVE" }).Count | Should -Be 1
    }
}

Describe "Dashboard Commit Sequencer RESTART expansion" {
    BeforeAll {
        $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:repoRoot = Split-Path -Path $basePath -Parent
        $script:scriptsDir = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        . (Join-Path -Path $script:scriptsDir -ChildPath "Dashboard.ps1")
    }

    It "expands a RESTART hardware queue value into a Phase 3 Stop and Phase 5 Start op" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{
                Live_Stage_Life = [pscustomobject]@{ hardware_targets = [pscustomobject]@{} }
            }
            App_Workloads = [pscustomobject]@{}
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "noop"; CurrentState = "Inactive"; DesiredState = "Inactive"; ProfileType = "App_Workload"; Domain = "Misc" }
        )
        $pending = @{ Bluetooth_Radio = "RESTART" }

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges $pending)

        @($ops | Where-Object { $_.Phase -eq 3 -and $_.WorkspaceName -eq "Bluetooth_Radio" -and $_.Action -eq "Stop" -and $_.ProfileType -eq "Hardware_Override" }).Count | Should -Be 1
        @($ops | Where-Object { $_.Phase -eq 5 -and $_.WorkspaceName -eq "Bluetooth_Radio" -and $_.Action -eq "Start" -and $_.ProfileType -eq "Hardware_Override" }).Count | Should -Be 1
    }

    It "labels RESTART hardware ops with a Restart reason" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{ Live_Stage_Life = [pscustomobject]@{ hardware_targets = [pscustomobject]@{} } }
            App_Workloads = [pscustomobject]@{}
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "noop"; CurrentState = "Inactive"; DesiredState = "Inactive"; ProfileType = "App_Workload"; Domain = "Misc" }
        )
        $pending = @{ Bluetooth_Radio = "RESTART" }

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges $pending)
        @($ops | Where-Object { $_.WorkspaceName -eq "Bluetooth_Radio" -and $_.Reason -eq "Restart Bluetooth_Radio" }).Count | Should -Be 2
    }

    It "expands a workload DesiredState=Restart into phase 1, 2, 6 and 7 ops" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{ Live_Stage_Life = [pscustomobject]@{ hardware_targets = [pscustomobject]@{} } }
            App_Workloads = [pscustomobject]@{
                Audio = [pscustomobject]@{
                    DAW_Cubase = [pscustomobject]@{
                        services = @("AudioSvc")
                        executables = @("'C:/Cubase/Cubase.exe'")
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "DAW_Cubase"; CurrentState = "Active"; DesiredState = "Restart"; ProfileType = "App_Workload"; Domain = "Audio" }
        )

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{})

        @($ops | Where-Object { $_.WorkspaceName -eq "DAW_Cubase" -and $_.Phase -eq 1 -and $_.Action -eq "Stop" -and $_.ExecutionScope -eq "ExecutablesOnly" }).Count | Should -Be 1
        @($ops | Where-Object { $_.WorkspaceName -eq "DAW_Cubase" -and $_.Phase -eq 2 -and $_.Action -eq "Stop" -and $_.ExecutionScope -eq "ServicesOnly" }).Count | Should -Be 1
        @($ops | Where-Object { $_.WorkspaceName -eq "DAW_Cubase" -and $_.Phase -eq 6 -and $_.Action -eq "Start" -and $_.ExecutionScope -eq "ServicesOnly" }).Count | Should -Be 1
        @($ops | Where-Object { $_.WorkspaceName -eq "DAW_Cubase" -and $_.Phase -eq 7 -and $_.Action -eq "Start" -and $_.ExecutionScope -eq "ExecutablesOnly" }).Count | Should -Be 1
    }

    It "labels Restart workload ops with a Restart reason" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{}
            System_Modes = [pscustomobject]@{ Live_Stage_Life = [pscustomobject]@{ hardware_targets = [pscustomobject]@{} } }
            App_Workloads = [pscustomobject]@{
                Audio = [pscustomobject]@{
                    DAW_Cubase = [pscustomobject]@{ services = @("AudioSvc"); executables = @("'C:/Cubase/Cubase.exe'") }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{ Name = "DAW_Cubase"; CurrentState = "Active"; DesiredState = "Restart"; ProfileType = "App_Workload"; Domain = "Audio" }
        )

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{})
        @($ops | Where-Object { $_.WorkspaceName -eq "DAW_Cubase" -and $_.Reason -eq "Restart DAW_Cubase" }).Count | Should -Be 4
    }

    It "applies a Restart workload's hardware_targets on the start side (phase 5) only" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{ Live_Stage_Life = [pscustomobject]@{ hardware_targets = [pscustomobject]@{} } }
            App_Workloads = [pscustomobject]@{
                Audio = [pscustomobject]@{
                    DAW_Cubase = [pscustomobject]@{
                        services = @("AudioSvc")
                        hardware_targets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{
                Name = "DAW_Cubase"; CurrentState = "Active"; DesiredState = "Restart"; ProfileType = "App_Workload"; Domain = "Audio"
                HardwareTargets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
            }
        )

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges @{})

        @($ops | Where-Object { $_.Phase -eq 3 -and $_.WorkspaceName -eq "Bluetooth_Radio" -and $_.Action -eq "Stop" }).Count | Should -Be 1
        @($ops | Where-Object { $_.Phase -eq 5 -and $_.WorkspaceName -eq "Bluetooth_Radio" }).Count | Should -Be 0
    }

    It "keeps workload hardware_targets precedence over a queued RESTART for the same component" {
        $workspaces = [pscustomobject]@{
            Hardware_Definitions = [pscustomobject]@{
                Bluetooth_Radio = [pscustomobject]@{ type = "pnp_device"; match = @("*Bluetooth*") }
            }
            System_Modes = [pscustomobject]@{ Live_Stage_Life = [pscustomobject]@{ hardware_targets = [pscustomobject]@{} } }
            App_Workloads = [pscustomobject]@{
                Audio = [pscustomobject]@{
                    DAW_Cubase = [pscustomobject]@{
                        services = @("AudioSvc")
                        hardware_targets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
                    }
                }
            }
        }
        $modeStates = @([pscustomobject]@{ Name = "Live_Stage_Life"; CurrentState = "Active"; DesiredState = "Active"; ProfileType = "System_Mode" })
        $workloadStates = @(
            [pscustomobject]@{
                Name = "DAW_Cubase"; CurrentState = "Inactive"; DesiredState = "Active"; ProfileType = "App_Workload"; Domain = "Audio"
                HardwareTargets = [pscustomobject]@{ Bluetooth_Radio = "OFF" }
            }
        )
        $pending = @{ Bluetooth_Radio = "RESTART" }

        $ops = @(Build-DashboardCommitOperations -Workspaces $workspaces -ModeStates $modeStates -WorkloadStates $workloadStates -PendingHardwareChanges $pending)

        @($ops | Where-Object { $_.Phase -eq 3 -and $_.WorkspaceName -eq "Bluetooth_Radio" -and $_.Action -eq "Stop" }).Count | Should -Be 1
        @($ops | Where-Object { $_.Phase -eq 5 -and $_.WorkspaceName -eq "Bluetooth_Radio" }).Count | Should -Be 0
    }
}
