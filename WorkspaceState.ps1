function Get-WorkspaceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspace
    )

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

            $totalServices++
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -eq "Running") {
                $runningServices++
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

            $totalExecutables++

            $filePath = $executionToken
            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
            }

            $leafName = Split-Path -Path $filePath -Leaf
            $cleanName = $leafName -replace "\.exe$", ""

            $process = Get-Process -Name $cleanName -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                $runningExecutables++
            }
        }
    }

    $totalItems = $totalServices + $totalExecutables
    $runningItems = $runningServices + $runningExecutables

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
