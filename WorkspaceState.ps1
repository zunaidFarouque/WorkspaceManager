function Resolve-QuotedRelativeExecutionToken {
    param([Parameter(Mandatory)][string]$ExecutionToken)
    $root = $PSScriptRoot
    $wsJson = Join-Path -Path $root -ChildPath "workspaces.json"
    if (Test-Path -LiteralPath $wsJson) {
        $root = [System.IO.Path]::GetDirectoryName($wsJson)
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    [regex]::Replace($ExecutionToken, "^'\.[\/\\](.*?)'", {
        param($match)
        $relativeRemainder = $match.Groups[1].Value -replace '/', $sep
        "'" + (Join-Path $root $relativeRemainder) + "'"
    })
}

function Resolve-RepoRelativeFilePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $root = $PSScriptRoot
    $wsJson = Join-Path -Path $root -ChildPath "workspaces.json"
    if (Test-Path -LiteralPath $wsJson) {
        $root = [System.IO.Path]::GetDirectoryName($wsJson)
    }
    $t = $Path.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq [char]'.' -and ($t[1] -eq [char]'/' -or $t[1] -eq '\')) {
        $rest = $t.Substring(2).TrimStart([char[]]@('/', '\'))
        $rest = $rest -replace '/', [System.IO.Path]::DirectorySeparatorChar
        return (Join-Path $root $rest)
    }
    return $Path
}

function Get-RunningStatusFromCounts {
    param(
        [Parameter(Mandatory = $true)][int]$Matched,
        [Parameter(Mandatory = $true)][int]$Total
    )

    if ($Total -eq 0) { return "Inactive" }
    if ($Matched -eq 0) { return "Inactive" }
    if ($Matched -eq $Total) { return "Active" }
    return "Mixed"
}

function Get-ExecutableIsRunning {
    param([Parameter(Mandatory = $true)][string]$ExecutionToken)

    if ([string]::IsNullOrWhiteSpace($ExecutionToken)) {
        return $false
    }
    if ($ExecutionToken -match '^#' -or $ExecutionToken -match '^t\s+(\d+)$') {
        return $false
    }

    $resolvedToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken $ExecutionToken
    $filePath = $resolvedToken
    if ($resolvedToken -match "^'(.*?)'\s*(.*)$") {
        $filePath = $matches[1]
    }

    $filePath = Resolve-RepoRelativeFilePath -Path $filePath
    $leafName = Split-Path -Path $filePath -Leaf
    $cleanName = $leafName -replace "\.exe$", ""

    if ([string]::IsNullOrWhiteSpace($cleanName)) {
        return $false
    }

    $process = Get-Process -Name $cleanName -ErrorAction SilentlyContinue
    return ($null -ne $process)
}

function Get-ExecutionTokenDisplayName {
    param([Parameter(Mandatory = $true)][string]$ExecutionToken)

    if ([string]::IsNullOrWhiteSpace($ExecutionToken)) {
        return ""
    }
    $resolvedToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken $ExecutionToken
    $filePath = $resolvedToken
    if ($resolvedToken -match "^'(.*?)'\s*(.*)$") {
        $filePath = $matches[1]
    }
    $filePath = Resolve-RepoRelativeFilePath -Path $filePath
    $leaf = Split-Path -Path $filePath -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        return $ExecutionToken
    }
    return $leaf
}

function Get-VideoControllerRefreshRates {
    [CmdletBinding()]
    param()

    $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
    $rates = [System.Collections.Generic.List[int]]::new()
    foreach ($controller in $controllers) {
        $rawRate = $controller.CurrentRefreshRate
        if ($null -eq $rawRate) { continue }

        $rate = 0
        if (-not [int]::TryParse([string]$rawRate, [ref]$rate)) { continue }
        if ($rate -le 0) { continue }
        $rates.Add($rate)
    }

    return @($rates)
}

function Get-HardwarePhysicalState {
    param(
        [Parameter(Mandatory = $true)][string]$DefinitionKey,
        [Parameter(Mandatory = $true)][psobject]$Definition,
        [array]$PnpCache = $null
    )

    $type = [string]$Definition.type
    switch ($type) {
        "service" {
            $name = [string]$Definition.name
            if ([string]::IsNullOrWhiteSpace($name)) { return $null }
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $svc) { return $null }
            if ($svc.Status -eq "Running") { return "ON" }
            return "OFF"
        }
        "process" {
            $name = [string]$Definition.name
            if ([string]::IsNullOrWhiteSpace($name)) { return $null }
            $cleanName = $name -replace "\.exe$", ""
            if ([string]::IsNullOrWhiteSpace($cleanName)) { return $null }
            $proc = Get-Process -Name $cleanName -ErrorAction SilentlyContinue
            if ($null -ne $proc) { return "ON" }
            return "OFF"
        }
        "pnp_device" {
            $patterns = @($Definition.match)
            if ($patterns.Count -eq 0) { return $null }
            $matchedDevices = @()

            foreach ($pattern in $patterns) {
                $devName = [string]$pattern
                if ([string]::IsNullOrWhiteSpace($devName)) { continue }
                if ($null -ne $PnpCache) {
                    $matchedDevices += @($PnpCache | Where-Object { $_.Name -like $devName })
                } else {
                    $cimName = $devName -replace '\*', '%'
                    $matchedDevices += @(Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '$cimName'" -ErrorAction SilentlyContinue)
                }
            }

            if (@($matchedDevices).Count -eq 0) { return $null }
            $okMatches = @($matchedDevices | Where-Object { $_.Status -eq "OK" })
            if ($okMatches.Count -gt 0) { return "ON" }
            return "OFF"
        }
        "registry" {
            $path = [string]$Definition.path
            $name = [string]$Definition.name
            if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($name)) { return $null }
            $val = Get-ItemPropertyValue -Path $path -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $val) { return $null }
            if ($Definition.PSObject.Properties["value_on"] -and $val -eq $Definition.value_on) { return "ON" }
            if ($Definition.PSObject.Properties["value_off"] -and $val -eq $Definition.value_off) { return "OFF" }
            return $null
        }
        "stateless" {
            if ($DefinitionKey -eq "Display_High_Refresh_Rate") {
                $rates = @(Get-VideoControllerRefreshRates)
                if ($rates.Count -eq 0) { return $null }
                if (@($rates | Where-Object { $_ -gt 60 }).Count -gt 0) { return "ON" }
                return "OFF"
            }
            return $null
        }
        default {
            return $null
        }
    }
}

function Get-WorkspaceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspace,
        [array]$PnpCache = $null
    )

    $hardwareDefinitions = $Workspace.Hardware_Definitions
    $systemModes = $Workspace.System_Modes
    $appWorkloads = $Workspace.App_Workloads
    $activeSystemMode = $null
    $statePath = Join-Path -Path $PSScriptRoot -ChildPath "state.json"
    if (-not (Test-Path -Path $statePath -PathType Leaf)) {
        ([pscustomobject]@{ Active_System_Mode = $null } | ConvertTo-Json -Depth 3) | Set-Content -Path $statePath -Encoding utf8
    }
    if (Test-Path -Path $statePath -PathType Leaf) {
        try {
            $persistedState = Get-Content -Path $statePath -Raw -Encoding utf8 | ConvertFrom-Json
            if ($null -ne $persistedState -and -not [string]::IsNullOrWhiteSpace([string]$persistedState.Active_System_Mode)) {
                $activeSystemMode = [string]$persistedState.Active_System_Mode
            }
        } catch {
            $activeSystemMode = $null
        }
    }

    $appWorkloadResults = @{}
    foreach ($workloadProp in $appWorkloads.PSObject.Properties) {
        $workloadName = $workloadProp.Name
        $workload = $workloadProp.Value
        $totalChecks = 0
        $matchedChecks = 0
        $serviceDetails = @()
        $executableDetails = @()

        foreach ($serviceName in @($workload.services)) {
            $name = [string]$serviceName
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '^#' -or $name -match '^t\s+(\d+)$') { continue }
            $totalChecks++
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            $isRunning = ($null -ne $svc -and $svc.Status -eq "Running")
            if ($isRunning) {
                $matchedChecks++
            }
            $serviceDetails += [pscustomobject]@{
                Name      = $name
                IsRunning = $isRunning
            }
        }

        foreach ($executionToken in @($workload.executables)) {
            $token = [string]$executionToken
            if ([string]::IsNullOrWhiteSpace($token) -or $token -match '^#' -or $token -match '^t\s+(\d+)$') { continue }
            $totalChecks++
            $isRunning = Get-ExecutableIsRunning -ExecutionToken $token
            if ($isRunning) {
                $matchedChecks++
            }
            $executableDetails += [pscustomobject]@{
                Token       = $token
                DisplayName = Get-ExecutionTokenDisplayName -ExecutionToken $token
                IsRunning   = $isRunning
            }
        }

        $appWorkloadResults[$workloadName] = [pscustomobject]@{
            Status        = Get-RunningStatusFromCounts -Matched $matchedChecks -Total $totalChecks
            MatchedChecks = $matchedChecks
            TotalChecks   = $totalChecks
            RuntimeDetails = [pscustomobject]@{
                Services      = @($serviceDetails)
                Executables   = @($executableDetails)
                MatchedChecks = $matchedChecks
                TotalChecks   = $totalChecks
            }
        }
    }

    $activePowerPlan = [string](powercfg /getactivescheme)
    $systemModeResults = @{}
    foreach ($modeProp in $systemModes.PSObject.Properties) {
        $modeName = $modeProp.Name
        $mode = $modeProp.Value
        $isActiveMode = ($modeName -eq $activeSystemMode)

        $powerPlanTarget = [string]$mode.power_plan
        $powerPlanMatches = $false
        if (-not [string]::IsNullOrWhiteSpace($powerPlanTarget)) {
            $powerPlanMatches = $activePowerPlan -match [regex]::Escape($powerPlanTarget)
        }

        $systemModeResults[$modeName] = [pscustomobject]@{
            Status          = if ($isActiveMode) { "Active" } else { "Inactive" }
            MatchedTargets  = 0
            TrackedTargets  = 0
            PowerPlanTarget = $powerPlanTarget
            PowerPlanMatch  = $powerPlanMatches
        }
    }

    $compliance = @()
    $activeModeTargets = $null
    if (-not [string]::IsNullOrWhiteSpace($activeSystemMode) -and
        $null -ne $systemModes -and
        $null -ne $systemModes.PSObject.Properties[$activeSystemMode]) {
        $activeModeData = $systemModes.PSObject.Properties[$activeSystemMode].Value
        if ($null -ne $activeModeData.PSObject.Properties["targets"]) {
            $activeModeTargets = $activeModeData.targets
        }
    }

    foreach ($hardwareProp in $hardwareDefinitions.PSObject.Properties) {
        $componentKey = $hardwareProp.Name
        $definition = $hardwareProp.Value
        $physicalState = Get-HardwarePhysicalState -DefinitionKey $componentKey -Definition $definition -PnpCache $PnpCache
        $targetState = "ANY"
        if ($null -ne $activeModeTargets -and $null -ne $activeModeTargets.PSObject.Properties[$componentKey]) {
            $targetState = [string]$activeModeTargets.PSObject.Properties[$componentKey].Value
        }

        $isCompliant = $null
        if ($targetState -ne "ANY") {
            $isCompliant = ($physicalState -eq $targetState)
        }

        $compliance += [pscustomobject]@{
            Mode          = $activeSystemMode
            Component     = $componentKey
            PhysicalState = $physicalState
            TargetState   = $targetState
            DesiredState  = $physicalState
            IsCompliant   = $isCompliant
        }
    }

    return [pscustomobject]@{
        AppWorkloads = [pscustomobject]$appWorkloadResults
        SystemModes  = [pscustomobject]$systemModeResults
        Compliance   = @($compliance)
    }
}
