Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Host.UI.RawUI.WindowTitle = "WorkspaceManager Dashboard"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path -Path $PSScriptRoot -ChildPath "WorkspaceState.ps1")

function Invoke-WorkspaceCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$UIStates,
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath
    )

    foreach ($state in $UIStates) {
        if ($state.DesiredState -ne $state.CurrentState -and $state.DesiredState -ne "Mixed") {
            $action = $null
            if ($state.DesiredState -eq "Ready") {
                $action = "Start"
            } elseif ($state.DesiredState -eq "Stopped") {
                $action = "Stop"
            }

            if ($null -ne $action) {
                Write-Host "--> Orchestrating $($state.Name) to $action..."
                Invoke-OrchestratorScript -OrchestratorPath $OrchestratorPath -WorkspaceName $state.Name -Action $action
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Invoke-OrchestratorScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrchestratorPath,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Start", "Stop")]
        [string]$Action
    )

    & $OrchestratorPath -WorkspaceName $WorkspaceName -Action $Action
}

function Write-ColoredStateText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    $stateKey = $State.Trim()
    $color = switch ($stateKey) {
        "Ready" { "Red" }
        "Stopped" { "Green" }
        "Mixed" { "Yellow" }
        default { "Gray" }
    }

    Write-Host -NoNewline $State -ForegroundColor $color
}

function Start-Dashboard {
    $jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
    if (-not (Test-Path -Path $jsonPath -PathType Leaf)) {
        throw "Fatal: workspaces.json not found."
    }

    $workspaces = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

    $UIStates = @()
    foreach ($prop in $workspaces.PSObject.Properties) {
        $Name = $prop.Name
        if ($Name -eq "_config") {
            continue
        }

        $workspaceData = $prop.Value
        $current = Get-WorkspaceState -Workspace $workspaceData
        $details = @()

        $servicesProperty = $workspaceData.PSObject.Properties["services"]
        if ($null -ne $servicesProperty) {
            foreach ($s in @($servicesProperty.Value)) {
                $service = Get-Service -Name $s -ErrorAction SilentlyContinue
                $details += [pscustomobject]@{
                    Name      = [string]$s
                    IsRunning = ($null -ne $service -and $service.Status -eq "Running")
                }
            }
        }

        $executablesProperty = $workspaceData.PSObject.Properties["executables"]
        if ($null -ne $executablesProperty) {
            foreach ($exeToken in @($executablesProperty.Value)) {
                $exeText = [string]$exeToken
                $filePath = $exeText
                if ($exeText -match "^'(.*?)'\s*(.*)$") {
                    $filePath = $matches[1]
                }

                $leafName = Split-Path -Path $filePath -Leaf
                $cleanName = $leafName -replace "\.exe$", ""
                $proc = Get-Process -Name $cleanName -ErrorAction SilentlyContinue
                if ($null -ne $proc) {
                    $details += [pscustomobject]@{
                        Name      = "$cleanName.exe"
                        IsRunning = $true
                    }
                }
            }
        }

        $UIStates += [pscustomobject]@{
            Name         = $Name
            CurrentState = $current
            DesiredState = $current
            Details      = $details
        }
    }

    if ($UIStates.Count -eq 0) {
        Write-Host "No workspaces found in workspaces.json."
        exit
    }

    $cursorIndex = 0
    $DetailedMode = $false
    $nameColumnWidth = 42
    $isRendering = $true

    while ($isRendering) {
        Clear-Host
        Write-Host "=== WORKSPACEMANAGER DASHBOARD ==="
        Write-Host " "
        Write-Host "   Profiles                               |  Current  ->  Desired"
        Write-Host "------------------------------------------+-------------------------"

        for ($i = 0; $i -lt $UIStates.Count; $i++) {
            $state = $UIStates[$i]
            $prefix = if ($i -eq $cursorIndex) { " > " } else { "   " }
            $paddedName = $state.Name.PadRight($nameColumnWidth - 3)

            Write-Host -NoNewline $prefix
            Write-Host -NoNewline $paddedName -ForegroundColor Cyan
            Write-Host -NoNewline "|  "

            if ($state.CurrentState -eq $state.DesiredState) {
                Write-ColoredStateText -State $state.CurrentState
            } else {
                $currentText = [string]$state.CurrentState
                Write-ColoredStateText -State $currentText
                $currentPadCount = 8 - $currentText.Length
                if ($currentPadCount -gt 0) {
                    Write-Host -NoNewline (" " * $currentPadCount)
                }
                Write-Host -NoNewline " ->  "
                Write-ColoredStateText -State $state.DesiredState
            }
            Write-Host ""

            if ($DetailedMode -eq $true) {
                foreach ($detail in $state.Details) {
                    $icon = if ($detail.IsRunning) { [char]0x25B6 } else { [char]0x25CB }
                    $detailPrefix = "      "
                    $detailName = $detail.Name.PadRight($nameColumnWidth - 6)
                    Write-Host "$detailPrefix$icon $detailName"
                }
            }
        }

        Write-Host ""
        Write-Host "[Up/Down] Navigate      |  [Space] Toggle Desired State "
        Write-Host "[F1] Toggle Details     |  [Esc] Cancel"
        Write-Host "[Enter] Commit & Exit"

        $key = [Console]::ReadKey($true).Key
        switch ($key) {
            "UpArrow" {
                if ($cursorIndex -gt 0) {
                    $cursorIndex--
                }
            }
            "DownArrow" {
                if ($cursorIndex -lt ($UIStates.Count - 1)) {
                    $cursorIndex++
                }
            }
            "Spacebar" {
                $selected = $UIStates[$cursorIndex]
                if ($selected.DesiredState -eq "Ready") {
                    $selected.DesiredState = "Stopped"
                } else {
                    $selected.DesiredState = "Ready"
                }
            }
            "F1" {
                $DetailedMode = -not $DetailedMode
            }
            "Escape" {
                Clear-Host
                Write-Host "Cancelled."
                exit
            }
            "Enter" {
                $isRendering = $false
                break
            }
        }
    }

    Clear-Host
    Write-Host "Committing state changes..."
    $OrchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"
    Invoke-WorkspaceCommit -UIStates $UIStates -OrchestratorPath $OrchestratorPath
    Write-Host "[ SUCCESS ] Workspaces updated."
    Start-Sleep -Seconds 2
    exit
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-Dashboard
}
