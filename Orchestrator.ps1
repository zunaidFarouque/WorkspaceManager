[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Start", "Stop")]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command -Name Show-Notification -CommandType Function -ErrorAction SilentlyContinue)) {
    function Show-Notification {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Title,
            [Parameter(Mandatory = $true)]
            [string]$Message
        )

        try {
            $xmlPayload = @"
<toast>
  <visual>
    <binding template='ToastGeneric'>
      <text>$Title</text>
      <text>$Message</text>
    </binding>
  </visual>
</toast>
"@

            $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xmlDoc.LoadXml($xmlPayload)
            $toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("WorkspaceManager")
            $notifier.Show($toast)
        } catch {
            return
        }
    }
}

$dbPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"

if (-not (Test-Path -Path $dbPath -PathType Leaf)) {
    throw "Fatal: workspaces.json not found."
}

try {
    $workspaces = Get-Content -Path $dbPath -Raw | ConvertFrom-Json
} catch {
    $parseDetail = $_.Exception.Message
    throw "Fatal: Failed to parse workspaces.json. $parseDetail"
}

$showNotifications = $false
$configProperty = $workspaces.PSObject.Properties["_config"]
if ($null -ne $configProperty) {
    $notificationsProperty = $configProperty.Value.PSObject.Properties["notifications"]
    if ($null -ne $notificationsProperty -and $notificationsProperty.Value -eq $true) {
        $showNotifications = $true
    }
}

$workspaceProperty = $workspaces.PSObject.Properties[$WorkspaceName]
if ($null -eq $workspaceProperty) {
    throw "Fatal: Workspace '$WorkspaceName' not defined in workspaces.json."
}

$workspace = $workspaceProperty.Value

$protectedProcessesProperty = $workspace.PSObject.Properties["protected_processes"]
if ($null -ne $protectedProcessesProperty) {
    $workspace.protected_processes = @(
        foreach ($processName in $protectedProcessesProperty.Value) {
            if ($processName -is [string]) {
                $processName -replace "\.exe$", ""
            } else {
                $processName
            }
        }
    )
}

# Phase 2: Pre-Flight Safety Checks
if ($Action -eq "Stop") {
    $protectedProcesses = @()
    $protectedProcessesProperty = $workspace.PSObject.Properties["protected_processes"]
    if ($null -ne $protectedProcessesProperty) {
        $protectedProcesses = @($protectedProcessesProperty.Value)
    }

    if ($protectedProcesses.Count -gt 0) {
        foreach ($protectedProcess in $protectedProcesses) {
            $activeProcess = Get-Process -Name $protectedProcess -ErrorAction SilentlyContinue

            if ($null -ne $activeProcess) {
                $choice = Read-Host "Warning: Protected process [$protectedProcess] is active. Force kill anyway? (Y/N)"

                if ($choice -match "^[Nn]$") {
                    throw "Abort: User cancelled teardown due to active protected process."
                }

                if ($choice -match "^[Yy]$") {
                    Write-Warning "Proceeding with teardown despite active protected process [$protectedProcess]."
                }

                break
            }
        }
    }
}

# Phase 3: The Start Pipeline
if ($Action -eq "Start") {
    $servicesProperty = $workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        foreach ($serviceItem in $servicesProperty.Value) {
            if ($serviceItem -is [string] -and $serviceItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $serviceName = [string]$serviceItem
            gsudo sc.exe config $serviceName start= demand
            gsudo net.exe start $serviceName

            $pollStart = Get-Date
            while ($true) {
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($null -ne $service -and $service.Status -eq "Running") {
                    break
                }

                $elapsedMs = ((Get-Date) - $pollStart).TotalMilliseconds
                if ($elapsedMs -ge 15000) {
                    Write-Warning "Timeout waiting for service [$serviceName] to reach Running state."
                    break
                }

                Start-Sleep -Milliseconds 500
            }
        }
    }

    $executablesProperty = $workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        foreach ($executableItem in $executablesProperty.Value) {
            if ($executableItem -is [string] -and $executableItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $executionToken = [string]$executableItem
            $filePath = $executionToken
            $argumentList = ""

            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
                $argumentList = $matches[2]
            }

            if ([string]::IsNullOrWhiteSpace($argumentList)) {
                Start-Process -FilePath $filePath
            } else {
                Start-Process -FilePath $filePath -ArgumentList $argumentList
            }
        }
    }

    if ($showNotifications) {
        Show-Notification -Title "Workspace Ready" -Message "$WorkspaceName is now active."
    }
}

# Phase 4: The Stop Pipeline
if ($Action -eq "Stop") {
    $executablesProperty = $workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        $executables = @($executablesProperty.Value)
        for ($i = $executables.Count - 1; $i -ge 0; $i--) {
            $executableItem = $executables[$i]

            if ($executableItem -is [string] -and $executableItem -match "^t\s+(\d+)$") {
                continue
            }

            $executionToken = [string]$executableItem
            $filePath = $executionToken
            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
            }

            $exeName = Split-Path -Path $filePath -Leaf
            gsudo taskkill /F /IM $exeName /T 2>&1 | Out-Null
            Start-Sleep -Seconds 1
        }
    }

    $servicesProperty = $workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        $services = @($servicesProperty.Value)
        for ($i = $services.Count - 1; $i -ge 0; $i--) {
            $serviceItem = $services[$i]

            if ($serviceItem -is [string] -and $serviceItem -match "^t\s+(\d+)$") {
                continue
            }

            $serviceName = [string]$serviceItem
            gsudo net.exe stop $serviceName /y 2>&1 | Out-Null
            gsudo sc.exe config $serviceName start= disabled 2>&1 | Out-Null
        }
    }

    $reverseRelationsProperty = $workspace.PSObject.Properties["reverse_relations"]
    if ($null -ne $reverseRelationsProperty) {
        foreach ($revServiceName in @($reverseRelationsProperty.Value)) {
            gsudo sc.exe config $revServiceName start= demand 2>&1 | Out-Null
            gsudo net.exe start $revServiceName 2>&1 | Out-Null
        }
    }

    if ($showNotifications) {
        Show-Notification -Title "Workspace Stopped" -Message "$WorkspaceName has been cleanly terminated."
    }
}

$workspace
