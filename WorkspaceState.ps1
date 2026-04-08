function Get-WorkspaceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspace,
        [array]$PnpCache = $null
    )

    $typeProperty = $Workspace.PSObject.Properties["type"]
    if ($null -ne $typeProperty -and [string]$typeProperty.Value -eq "oneshot") {
        return "Idle"
    }

    $totalServices = 0
    $runningServices = 0
    $totalExecutables = 0
    $runningExecutables = 0

    $servicesProperty = $Workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        foreach ($serviceItem in @($servicesProperty.Value)) {
            $serviceName = [string]$serviceItem
            if ([string]::IsNullOrWhiteSpace($serviceName)) {
                continue
            }
            if ($serviceName -match '^#') {
                continue
            }
            if ($serviceName -match '^t\s+(\d+)$') {
                continue
            }

            $isOptional = $serviceName.StartsWith("?")
            if ($isOptional) {
                $serviceName = $serviceName.Substring(1)
            }

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -eq "Running") {
                $totalServices++
                $runningServices++
            } elseif (-not $isOptional) {
                $totalServices++
            }
        }
    }

    $executablesProperty = $Workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        foreach ($executableItem in @($executablesProperty.Value)) {
            $executionToken = [string]$executableItem
            if ([string]::IsNullOrWhiteSpace($executionToken)) {
                continue
            }
            if ($executionToken -match '^#') {
                continue
            }
            if ($executionToken -match '^t\s+(\d+)$') {
                continue
            }

            $filePath = $executionToken
            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
            }

            $isOptional = $filePath.StartsWith("?")
            if ($isOptional) {
                $filePath = $filePath.Substring(1)
            }

            $leafName = Split-Path -Path $filePath -Leaf
            $cleanName = $leafName -replace "\.exe$", ""

            $process = Get-Process -Name $cleanName -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                $totalExecutables++
                $runningExecutables++
            } elseif (-not $isOptional) {
                $totalExecutables++
            }
        }
    }

    $totalItems = $totalServices + $totalExecutables
    $runningItems = $runningServices + $runningExecutables

    $pnpEnableProperty = $Workspace.PSObject.Properties["pnp_devices_enable"]
    if ($null -ne $pnpEnableProperty) {
        foreach ($friendlyName in @($pnpEnableProperty.Value)) {
            $devName = [string]$friendlyName
            if ([string]::IsNullOrWhiteSpace($devName)) { continue }
            if ($devName -match '^#') { continue }
            $totalItems++
            if ($null -ne $PnpCache) {
                $dev = $PnpCache | Where-Object { $_.Name -like $devName } | Select-Object -First 1
            } else {
                $cimName = $devName -replace '\*', '%'
                $dev = Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '$cimName'" -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($null -ne $dev -and $dev.Status -eq "OK") {
                $runningItems++
            }
        }
    }

    $pnpDisableProperty = $Workspace.PSObject.Properties["pnp_devices_disable"]
    if ($null -ne $pnpDisableProperty) {
        foreach ($friendlyName in @($pnpDisableProperty.Value)) {
            $devName = [string]$friendlyName
            if ([string]::IsNullOrWhiteSpace($devName)) { continue }
            if ($devName -match '^#') { continue }
            $totalItems++
            if ($null -ne $PnpCache) {
                $dev = $PnpCache | Where-Object { $_.Name -like $devName } | Select-Object -First 1
            } else {
                $cimName = $devName -replace '\*', '%'
                $dev = Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '$cimName'" -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($null -eq $dev -or $dev.Status -ne "OK") {
                $runningItems++
            }
        }
    }

    $powerPlanProperty = $Workspace.PSObject.Properties["power_plan"]
    if ($null -ne $powerPlanProperty -and -not [string]::IsNullOrWhiteSpace([string]$powerPlanProperty.Value)) {
        $planName = [string]$powerPlanProperty.Value
        $totalItems++
        $active = powercfg /getactivescheme
        if ($active -match [regex]::Escape($planName)) {
            $runningItems++
        }
    }

    $registryTogglesProperty = $Workspace.PSObject.Properties["registry_toggles"]
    if ($null -ne $registryTogglesProperty) {
        foreach ($item in @($registryTogglesProperty.Value)) {
            if ($null -eq $item) { continue }
            $pathProp = $item.PSObject.Properties["path"]
            $nameProp = $item.PSObject.Properties["name"]
            $valueProp = $item.PSObject.Properties["value"]
            if ($null -eq $pathProp -or $null -eq $nameProp -or $null -eq $valueProp) { continue }

            $path = [string]$pathProp.Value
            $name = [string]$nameProp.Value
            $expectedValue = $valueProp.Value
            if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($name)) { continue }

            $totalItems++
            $val = Get-ItemPropertyValue -Path $path -Name $name -ErrorAction SilentlyContinue
            if ($val -eq $expectedValue) {
                $runningItems++
            }
        }
    }

    if ($totalItems -eq 0) {
        return "Stopped"
    }

    if ($runningItems -eq 0) {
        return "Stopped"
    }

    if ($runningItems -eq $totalItems) {
        return "Ready"
    }

    return "Mixed"
}
