[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "WorkspaceState.ps1")

$script:ActivationWaitTimeoutSeconds = 30
$script:ActivationPollIntervalSeconds = 1
$script:InterceptorElevationAttributionEnabled = $true

function Set-InterceptorElevationAttributionEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enabled
    )

    $script:InterceptorElevationAttributionEnabled = [bool]$Enabled
}

function Get-InterceptorElevationAttributionEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$Workspaces
    )

    $defaultValue = $true
    if ($null -eq $Workspaces) {
        return $defaultValue
    }

    $configProp = $Workspaces.PSObject.Properties["_config"]
    if ($null -eq $configProp -or $null -eq $configProp.Value) {
        return $defaultValue
    }

    $attrProp = $configProp.Value.PSObject.Properties["elevation_attribution"]
    if ($null -eq $attrProp) {
        return $defaultValue
    }

    return [bool]$attrProp.Value
}

function Test-GsudoCacheAvailable {
    [CmdletBinding()]
    param()

    try {
        $output = gsudo status --json 2>&1
        $text = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }

        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed) { return $false }

        $cacheProp = $parsed.PSObject.Properties["CacheAvailable"]
        if ($null -eq $cacheProp) { return $false }

        return [bool]$cacheProp.Value
    } catch {
        return $false
    }
}

function Show-InterceptorElevationToast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [Parameter(Mandatory = $false)]
        [string]$WorkloadName = "",

        [Parameter(Mandatory = $false)]
        [int]$AutoCloseMilliseconds = 2500
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "RigShift Elevation"
    $form.ClientSize = New-Object System.Drawing.Size(440, 120)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.TopMost = $true
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $form.ShowInTaskbar = $false
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false

    try {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Location = New-Object System.Drawing.Point(($screen.Right - 460), ($screen.Bottom - 140))
    } catch {
        $form.Location = New-Object System.Drawing.Point(100, 100)
    }

    $label = New-Object System.Windows.Forms.Label
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $headerLine = if ([string]::IsNullOrWhiteSpace($WorkloadName)) {
        "RigShift: requesting admin elevation"
    } else {
        "RigShift: requesting admin elevation (workload: $WorkloadName)"
    }
    $label.Text = "$headerLine`r`n`r`n$Reason`r`n`r`nUAC dialog will appear..."
    $form.Controls.Add($label)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(100, [int]$AutoCloseMilliseconds)
    $timer.Add_Tick({
        try { $timer.Stop() } catch { }
        try { $form.Close() } catch { }
    })
    $timer.Start()

    try {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        # Headless or no UI session: form remains a no-op object whose Close() is still safe.
    }

    return $form
}

function Invoke-WithElevationAttribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [Parameter(Mandatory = $false)]
        [string]$WorkloadName = "",

        [Parameter(Mandatory = $true)]
        [scriptblock]$ElevatedAction
    )

    $toast = $null
    $attributionEnabled = ($script:InterceptorElevationAttributionEnabled -eq $true)
    $shouldShowToast = $false

    if ($attributionEnabled) {
        $cacheAvailable = $false
        try {
            $cacheAvailable = [bool](Test-GsudoCacheAvailable)
        } catch {
            $cacheAvailable = $false
        }
        $shouldShowToast = (-not $cacheAvailable)
    }

    if ($shouldShowToast) {
        try {
            $toast = Show-InterceptorElevationToast -Reason $Reason -WorkloadName $WorkloadName
        } catch {
            $toast = $null
        }
    }

    try {
        & $ElevatedAction
    } finally {
        if ($null -ne $toast) {
            try { $toast.Close() } catch { }
        }
    }
}

function Get-InterceptorWorkspaces {
    [CmdletBinding()]
    param()

    $jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
    if (-not (Test-Path -Path $jsonPath -PathType Leaf)) {
        throw "Fatal: workspaces.json not found."
    }

    return (Get-Content -Path $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Get-InterceptorPollMaxSeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$Workspaces
    )

    $defaultSeconds = 15
    if ($null -eq $Workspaces) {
        $Workspaces = Get-InterceptorWorkspaces
    }

    $configObj = $null
    if ($null -ne $Workspaces) {
        $configProp = $Workspaces.PSObject.Properties["_config"]
        if ($null -ne $configProp) {
            $configObj = $configProp.Value
        }
    }

    $capValue = $null
    if ($null -ne $configObj) {
        $capProp = $configObj.PSObject.Properties["interceptor_poll_max_seconds"]
        if ($null -ne $capProp) {
            $capValue = $capProp.Value
        }
    }

    if ($null -eq $capValue) { return $defaultSeconds }

    $parsed = 0
    $ok = [int]::TryParse([string]$capValue, [ref]$parsed)
    if (-not $ok -or $parsed -le 0) { return $defaultSeconds }
    return $parsed
}

function Resolve-InterceptedWorkload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspaces,
        [Parameter(Mandatory = $true)]
        [string]$TargetExe
    )

    $targetLeaf = [System.IO.Path]::GetFileName($TargetExe)
    foreach ($entry in @(Get-AppWorkloadEntries -AppWorkloads $Workspaces.App_Workloads)) {
        $workload = $entry.Workload
        $interceptsProp = $workload.PSObject.Properties["intercepts"]
        if ($null -eq $interceptsProp) { continue }

        foreach ($intercept in @($workload.intercepts)) {
            $exeRuleNames = @()
            $interceptRequires = $null

            # Legacy intercept item: string exe name => default requires = whole workload.
            if ($intercept -is [string]) {
                if ([string]::IsNullOrWhiteSpace([string]$intercept)) { continue }
                $exeRuleNames = @([string]$intercept)
            } else {
                $exeProp = $intercept.PSObject.Properties["exe"]
                if ($null -eq $exeProp) { continue }
                $exeValue = $intercept.exe
                if ($exeValue -is [System.Array]) {
                    $exeRuleNames = @($exeValue)
                } else {
                    $exeRuleNames = @([string]$exeValue)
                }

                $requiresProp = $intercept.PSObject.Properties["requires"]
                if ($null -ne $requiresProp) {
                    $interceptRequires = $intercept.requires
                }
            }

            $matched = $false
            foreach ($exeCandidate in @($exeRuleNames)) {
                $exeCandidate = [string]$exeCandidate
                if ([string]::Equals($exeCandidate, $targetLeaf, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $matched = $true
                    break
                }
            }

            if (-not $matched) { continue }

            $defaultServices = @(Get-JsonObjectOptionalStringArray -InputObject $workload -PropertyName "services")
            $defaultExecutables = @(Get-JsonObjectOptionalStringArray -InputObject $workload -PropertyName "executables")

            # Resolver semantics:
            # - legacy string intercept items: default to whole workload services/executables.
            # - rule-object intercept items with a `requires` object:
            #   missing `requires.executables` means "no executables" (avoid starting OneDrive).
            $requiredServices = $defaultServices
            $requiredExecutables = $defaultExecutables

            if ($null -ne $interceptRequires) {
                $requiredServices = @()
                $requiredExecutables = @()

                if ($interceptRequires.PSObject.Properties["services"] -ne $null) {
                    $requiredServices = @($interceptRequires.services)
                }
                if ($interceptRequires.PSObject.Properties["executables"] -ne $null) {
                    $requiredExecutables = @($interceptRequires.executables)
                }
            }

            return [pscustomobject]@{
                Name                 = [string]$entry.Name
                Workload             = $workload
                RequiredServices     = @($requiredServices)
                RequiredExecutables  = @($requiredExecutables)
            }
        }
    }

    return $null
}

function Get-AppWorkloadEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$AppWorkloads
    )

    if ($null -eq $AppWorkloads) {
        return @()
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($domainProp in @($AppWorkloads.PSObject.Properties)) {
        if ($null -eq $domainProp.Value) { continue }
        foreach ($workloadProp in @($domainProp.Value.PSObject.Properties)) {
            if ($null -eq $workloadProp.Value) { continue }
            $entries.Add([pscustomobject]@{
                Domain   = [string]$domainProp.Name
                Name     = [string]$workloadProp.Name
                Workload = $workloadProp.Value
            })
        }
    }
    return @($entries)
}

function Test-InterceptorRuleActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredServices,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredExecutables
    )

    foreach ($serviceName in @($RequiredServices)) {
        $svc = [string]$serviceName
        if ([string]::IsNullOrWhiteSpace($svc)) { continue }
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $s -or ($s.Status -ne "Running" -and $s.Status -ne "StartPending")) { return $false }
    }

    foreach ($executionToken in @($RequiredExecutables)) {
        $t = [string]$executionToken
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $isRunning = Get-ExecutableIsRunning -ExecutionToken $t
        if (-not $isRunning) { return $false }
    }

    return $true
}

function Show-InterceptorPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetExe,
        [Parameter(Mandatory = $true)]
        [string]$WorkloadName,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$FullServices,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$FullExecutables,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredServices,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredExecutables
    )

    Add-Type -AssemblyName System.Windows.Forms

    function Format-List {
        param([string[]]$Items)
        $clean = @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($clean.Count -eq 0) { return "(none)" }
        return ($clean -join ", ")
    }

    $fullExecDisplay = @()
    foreach ($t in @($FullExecutables)) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        # Convert token to a display name (leaf exe). Best-effort only.
        try { $fullExecDisplay += Get-ExecutionTokenDisplayName -ExecutionToken ([string]$t) } catch { $fullExecDisplay += [string]$t }
    }
    $reqExecDisplay = @()
    foreach ($t in @($RequiredExecutables)) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        try { $reqExecDisplay += Get-ExecutionTokenDisplayName -ExecutionToken ([string]$t) } catch { $reqExecDisplay += [string]$t }
    }

    $message = @"
The application '$TargetExe' requires the '$WorkloadName' workload.
It is currently inactive.

What do you want to enable?

REQUIRED-only (No):
  Services: $(Format-List -Items $RequiredServices)
  Executables: $(Format-List -Items $reqExecDisplay)

FULL workload (Yes):
  Services: $(Format-List -Items $FullServices)
  Executables: $(Format-List -Items $fullExecDisplay)
"@

    # Yes => FULL, No => REQUIRED-only, Cancel => decline.
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        "RigShift",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2 # Button2 == "No"
    )

    switch ([string]$result) {
        "Yes" { return "Yes" }
        "No" { return "No" }
        default { return "Cancel" }
    }
}

function Get-InterceptorDisabledServiceBlockers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    if ([string]::IsNullOrWhiteSpace($ServiceName)) {
        return @()
    }

    $s = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $s) {
        return @()
    }

    $ordered = [System.Collections.Generic.List[string]]::new()
    $seen = @{ }

    foreach ($dep in @($s.ServicesDependedOn)) {
        if ($null -eq $dep) { continue }
        $depSvc = Get-Service -Name ([string]$dep.Name) -ErrorAction SilentlyContinue
        if ($null -eq $depSvc) { continue }
        if ([string]$depSvc.StartType -ne "Disabled") { continue }
        $low = ([string]$depSvc.Name).ToLowerInvariant()
        if ($seen.ContainsKey($low)) { continue }
        $seen[$low] = $true
        [void]$ordered.Add([string]$depSvc.Name)
    }

    if ([string]$s.StartType -eq "Disabled") {
        $low = ([string]$s.Name).ToLowerInvariant()
        if (-not $seen.ContainsKey($low)) {
            $seen[$low] = $true
            [void]$ordered.Add([string]$s.Name)
        }
    }

    return @($ordered)
}

function Show-InterceptorDisabledServicePrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        [Parameter(Mandatory = $true)]
        [string]$RequiredForServiceName,
        [Parameter(Mandatory = $true)]
        [string]$WorkloadName
    )

    Add-Type -AssemblyName System.Windows.Forms

    $message = @"
The Windows service '$ServiceName' has startup type Disabled and cannot be started.

It is required for '$RequiredForServiceName' (workload '$WorkloadName').

Yes - Set startup type to Manual and continue.
No - Abort activation of workload.
"@

    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        "RigShift",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        return "Yes"
    }
    return "Cancel"
}

function Start-RuleActivationFlow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredServices,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredExecutables,
        [Parameter(Mandatory = $true)]
        [string]$WorkloadName
    )

    $script:InterceptorSkippedServiceStartDueToDeclinedDisabled = $false
    $script:InterceptorUserCancelledDisabledRemediation = $false
    $script:InterceptorDidRunGsudoStartService = $false

    foreach ($serviceName in @($RequiredServices)) {
        $svc = [string]$serviceName
        if ([string]::IsNullOrWhiteSpace($svc)) { continue }

        $blockers = @(Get-InterceptorDisabledServiceBlockers -ServiceName $svc)

        foreach ($blocker in $blockers) {
            $disabledChoice = Show-InterceptorDisabledServicePrompt -ServiceName $blocker -RequiredForServiceName $svc -WorkloadName $WorkloadName
            if ($disabledChoice -eq "Cancel") {
                $script:InterceptorUserCancelledDisabledRemediation = $true
                return
            }
            $reason = "Set-Service '$blocker' startup type to Manual (required for service '$svc')"
            Invoke-WithElevationAttribution -Reason $reason -WorkloadName $WorkloadName -ElevatedAction {
                gsudo Set-Service -Name $blocker -StartupType Manual 2>&1 | Out-Null
            }
        }

        $remainingBlockers = @(Get-InterceptorDisabledServiceBlockers -ServiceName $svc)
        if ($remainingBlockers.Count -gt 0) {
            $script:InterceptorSkippedServiceStartDueToDeclinedDisabled = $true
            continue
        }

        $global:LASTEXITCODE = 0
        $startReason = "Start-Service '$svc' for workload activation"
        Invoke-WithElevationAttribution -Reason $startReason -WorkloadName $WorkloadName -ElevatedAction {
            gsudo Start-Service -Name $svc 2>&1 | Out-Null
        }
        $script:InterceptorDidRunGsudoStartService = $true
    }

    # Open observe / workload terminal before starting executables — same window as after successful service starts.
    # Also open when a required service stayed Disabled after prompts (e.g. Set-Service failed) so workload state is visible.
    $nonEmptyExecutables = @($RequiredExecutables | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $openObserve = ($script:InterceptorDidRunGsudoStartService -eq $true) -or
        ($nonEmptyExecutables.Count -gt 0) -or
        ($script:InterceptorSkippedServiceStartDueToDeclinedDisabled -eq $true)
    if ($openObserve -eq $true) {
        $dashboardPath = Join-Path -Path $PSScriptRoot -ChildPath "Dashboard.ps1"
        $arguments = @("-ExecutionPolicy", "Bypass", "-File", $dashboardPath, "-ObserveWorkloadName", $WorkloadName, "-ObserveSeconds", "10")
        Start-Process -FilePath "pwsh.exe" -ArgumentList $arguments 2>&1 | Out-Null
    }

    foreach ($executionToken in @($RequiredExecutables)) {
        $token = [string]$executionToken
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        $runAsAdmin = $false
        if ($token -like "admin:*") {
            $runAsAdmin = $true
            $token = $token.Substring("admin:".Length)
        }

        $resolvedToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken $token
        $filePath = $resolvedToken
        $argumentList = ""
        if ($resolvedToken -match "^'(.*?)'\s*(.*)$") {
            $filePath = $matches[1]
            $argumentList = $matches[2]
        }
        $filePath = Resolve-RepoRelativeFilePath -Path $filePath
        $filePath = [System.IO.Path]::GetFullPath($filePath)

        if ($runAsAdmin) {
            # Start elevated without a visible console.
            $cmd = if ([string]::IsNullOrWhiteSpace($argumentList)) {
                "Start-Process -FilePath `"$filePath`""
            } else {
                $escaped = $argumentList.Replace('"', '`"')
                "Start-Process -FilePath `"$filePath`" -ArgumentList `"$escaped`""
            }
            $execLeaf = [System.IO.Path]::GetFileName($filePath)
            $adminReason = "Launching admin executable '$execLeaf' for workload"
            Invoke-WithElevationAttribution -Reason $adminReason -WorkloadName $WorkloadName -ElevatedAction {
                gsudo pwsh.exe -NoProfile -WindowStyle Hidden -Command $cmd 2>&1 | Out-Null
            }
        } else {
            if ([string]::IsNullOrWhiteSpace($argumentList)) {
                Start-Process -FilePath $filePath 2>&1 | Out-Null
            } else {
                Start-Process -FilePath $filePath -ArgumentList $argumentList 2>&1 | Out-Null
            }
        }
    }
}

function Wait-ForInterceptorRuleActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredServices,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredExecutables,
        [Parameter(Mandatory = $false)]
        [int]$MaxSeconds,
        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds
    )

    # With value-typed parameters, PowerShell can default unbound values (e.g. to 0).
    # Use $PSBoundParameters to decide whether to apply the script defaults.
    if ($PSBoundParameters.ContainsKey("MaxSeconds")) {
        $MaxSeconds = [int]$MaxSeconds
    } else {
        $MaxSeconds = [int]$script:ActivationWaitTimeoutSeconds
    }

    if ($PSBoundParameters.ContainsKey("PollIntervalSeconds")) {
        $PollIntervalSeconds = [int]$PollIntervalSeconds
    } else {
        $PollIntervalSeconds = [int]$script:ActivationPollIntervalSeconds
    }

    if ($PollIntervalSeconds -lt 0) { $PollIntervalSeconds = 0 }

    if ($MaxSeconds -le 0) {
        return (Test-InterceptorRuleActive -RequiredServices $RequiredServices -RequiredExecutables $RequiredExecutables)
    }

    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-InterceptorRuleActive -RequiredServices $RequiredServices -RequiredExecutables $RequiredExecutables) {
            return $true
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    return $false
}

function Invoke-InterceptorReadinessPoll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredServices,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequiredExecutables,

        [Parameter(Mandatory = $true)]
        [string]$WorkloadName
    )

    $configuredCapSeconds = [int](Get-InterceptorPollMaxSeconds)
    if ($configuredCapSeconds -le 0) { $configuredCapSeconds = 15 }

    # Hard cap readiness polling to 15s (per requirement), but still respect the
    # existing script defaults for tests and local overrides via ActivationWaitTimeoutSeconds.
    $effectiveMaxSeconds = [int]$script:ActivationWaitTimeoutSeconds
    $effectiveMaxSeconds = [Math]::Min($effectiveMaxSeconds, $configuredCapSeconds)
    $effectiveMaxSeconds = [Math]::Min($effectiveMaxSeconds, 15)

    $pollIntervalSeconds = [int]$script:ActivationPollIntervalSeconds

    if ([string]$env:RigShift_InProcPolling -eq "1") {
        return (Wait-ForInterceptorRuleActive `
            -RequiredServices $RequiredServices `
            -RequiredExecutables $RequiredExecutables `
            -MaxSeconds $effectiveMaxSeconds `
            -PollIntervalSeconds $pollIntervalSeconds)
    }

    $pollScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "InterceptorPoll.ps1"
    $requiredServicesJson = (@($RequiredServices) | ConvertTo-Json -Compress)
    $requiredExecutablesJson = (@($RequiredExecutables) | ConvertTo-Json -Compress)

    $argumentList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $pollScriptPath,
        "-WorkloadName", $WorkloadName,
        "-PollMarker", "RigShift_InterceptorPoll",
        "-MaxSeconds", $effectiveMaxSeconds.ToString(),
        "-PollIntervalSeconds", $pollIntervalSeconds.ToString(),
        "-RequiredServicesJson", $requiredServicesJson,
        "-RequiredExecutablesJson", $requiredExecutablesJson
    )

    $proc = $null
    try {
        $proc = Start-Process -FilePath "pwsh.exe" -ArgumentList $argumentList -WindowStyle Hidden -PassThru
    } catch {
        return $false
    }

    $exitCode = 1
    if ($proc -is [System.Diagnostics.Process]) {
        $proc.WaitForExit()
        $exitCode = [int]$proc.ExitCode
    } elseif ($null -ne $proc -and $proc.PSObject.Properties.Name -contains "ExitCode") {
        $exitCode = [int]$proc.ExitCode
    }

    return ($exitCode -eq 0)
}

function Invoke-WithManagedIfeoTemporarilyDisabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetExe,
        [Parameter(Mandatory = $true)]
        [scriptblock]$LaunchBlock,
        [Parameter(Mandatory = $false)]
        [string]$WorkloadName = ""
    )

    $targetLeaf = [System.IO.Path]::GetFileName($TargetExe)
    if ([string]::IsNullOrWhiteSpace($targetLeaf)) {
        & $LaunchBlock
        return
    }

    $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$targetLeaf"
    $managedHook = $false
    $debuggerValue = $null
    $managedValue = $null

    try {
        $props = Get-ItemProperty -Path $ifeoPath -ErrorAction SilentlyContinue
        if ($null -ne $props) {
            $debuggerValue = [string]$props.Debugger
            $managedValue = [string]$props.RigShift_Managed
            $managedHook = (-not [string]::IsNullOrWhiteSpace($debuggerValue) -and $managedValue -eq "1")
        }
    } catch {
        $managedHook = $false
    }

    if (-not $managedHook) {
        & $LaunchBlock
        return
    }

    $escapedPath = $ifeoPath.Replace("'", "''")
    $escapedDebugger = $debuggerValue.Replace("'", "''")
    $escapedManaged = $managedValue.Replace("'", "''")

    $disableCmd = "Remove-ItemProperty -Path '$escapedPath' -Name 'Debugger' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path '$escapedPath' -Name 'RigShift_Managed' -ErrorAction SilentlyContinue"
    $restoreCmd = "New-Item -Path '$escapedPath' -Force | Out-Null; New-ItemProperty -Path '$escapedPath' -Name 'Debugger' -Value '$escapedDebugger' -PropertyType String -Force | Out-Null; New-ItemProperty -Path '$escapedPath' -Name 'RigShift_Managed' -Value '$escapedManaged' -PropertyType String -Force | Out-Null"

    $disableReason = "Disabling IFEO hook for '$targetLeaf' to launch target without recursion"
    $restoreReason = "Restoring IFEO hook for '$targetLeaf' after launch"

    try {
        Invoke-WithElevationAttribution -Reason $disableReason -WorkloadName $WorkloadName -ElevatedAction {
            gsudo pwsh.exe -NoProfile -Command $disableCmd 2>&1 | Out-Null
        }
        & $LaunchBlock
    } finally {
        Invoke-WithElevationAttribution -Reason $restoreReason -WorkloadName $WorkloadName -ElevatedAction {
            gsudo pwsh.exe -NoProfile -Command $restoreCmd 2>&1 | Out-Null
        }
    }
}

function Start-InterceptedApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetExe,
        [string[]]$TargetArgs = @(),
        [Parameter(Mandatory = $false)]
        [string]$WorkloadName = ""
    )

    $sanitizedArgs = @()
    foreach ($arg in @($TargetArgs)) {
        if ($null -eq $arg) { continue }
        $argText = [string]$arg
        if ([string]::IsNullOrWhiteSpace($argText)) { continue }
        $sanitizedArgs += $argText
    }

    if ($sanitizedArgs.Count -eq 0) {
        Invoke-WithManagedIfeoTemporarilyDisabled -TargetExe $TargetExe -WorkloadName $WorkloadName -LaunchBlock {
            Start-Process -FilePath $TargetExe | Out-Null
        }
        return
    }

    Invoke-WithManagedIfeoTemporarilyDisabled -TargetExe $TargetExe -WorkloadName $WorkloadName -LaunchBlock {
        $quotedArgs = @()
        foreach ($arg in @($sanitizedArgs)) {
            $argText = [string]$arg
            if ($argText -match '^[/-]') {
                $quotedArgs += $argText
            } else {
                $escapedArg = $argText.Replace('"', '\"')
                $quotedArgs += ('"{0}"' -f $escapedArg)
            }
        }
        $argumentLine = ($quotedArgs -join " ")
        Start-Process -FilePath $TargetExe -ArgumentList $argumentLine | Out-Null
    }
}

function Invoke-Interceptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetExe,
        [string[]]$TargetArgs = @()
    )

    $script:InterceptorUserCancelledDisabledRemediation = $false
    $script:InterceptorSkippedServiceStartDueToDeclinedDisabled = $false

    if ([string]$env:RigShift_InterceptorBypass -eq "1") {
        Start-InterceptedApplication -TargetExe $TargetExe -TargetArgs $TargetArgs
        return
    }

    $workspaces = Get-InterceptorWorkspaces
    Set-InterceptorElevationAttributionEnabled -Enabled (Get-InterceptorElevationAttributionEnabled -Workspaces $workspaces)

    $resolved = Resolve-InterceptedWorkload -Workspaces $workspaces -TargetExe $TargetExe
    if ($null -eq $resolved) {
        Start-InterceptedApplication -TargetExe $TargetExe -TargetArgs $TargetArgs
        return
    }

    if (Test-InterceptorRuleActive -RequiredServices $resolved.RequiredServices -RequiredExecutables $resolved.RequiredExecutables) {
        Start-InterceptedApplication -TargetExe $TargetExe -TargetArgs $TargetArgs -WorkloadName $resolved.Name
        return
    }

    $fullServices = @(Get-JsonObjectOptionalStringArray -InputObject $resolved.Workload -PropertyName "services")
    $fullExecutables = @(Get-JsonObjectOptionalStringArray -InputObject $resolved.Workload -PropertyName "executables")

    $promptResult = Show-InterceptorPrompt `
        -TargetExe $TargetExe `
        -WorkloadName $resolved.Name `
        -FullServices $fullServices `
        -FullExecutables $fullExecutables `
        -RequiredServices $resolved.RequiredServices `
        -RequiredExecutables $resolved.RequiredExecutables

    # Yes => FULL workload, No => REQUIRED-only, Cancel => decline.
    $activationServices = $resolved.RequiredServices
    $activationExecutables = $resolved.RequiredExecutables

    switch ($promptResult) {
        "Yes" {
            $activationServices = $fullServices
            $activationExecutables = $fullExecutables
        }
        "No" { }
        default { return }
    }

    Start-RuleActivationFlow `
        -RequiredServices $activationServices `
        -RequiredExecutables $activationExecutables `
        -WorkloadName $resolved.Name

    if ($script:InterceptorUserCancelledDisabledRemediation -eq $true) {
        return
    }

    $nowActive = Invoke-InterceptorReadinessPoll -RequiredServices $activationServices -RequiredExecutables $activationExecutables -WorkloadName $resolved.Name
    if ($nowActive) {
        Start-InterceptedApplication -TargetExe $TargetExe -TargetArgs $TargetArgs -WorkloadName $resolved.Name
        return
    }

    if ($script:InterceptorSkippedServiceStartDueToDeclinedDisabled -eq $true) {
        return
    }

    # If activation hasn't fully materialized by timeout, still launch.
    # Launch path handles recursion safety by temporarily disabling managed IFEO.
    Start-InterceptedApplication -TargetExe $TargetExe -TargetArgs $TargetArgs -WorkloadName $resolved.Name
}

if ($MyInvocation.InvocationName -ne ".") {
    if ($RemainingArgs.Count -eq 0) {
        exit
    }

    $TargetExe = $RemainingArgs[0]
    $TargetArgs = @()
    if ($RemainingArgs.Count -gt 1) {
        $TargetArgs = @($RemainingArgs[1..($RemainingArgs.Count - 1)])
    }

    Invoke-Interceptor -TargetExe $TargetExe -TargetArgs $TargetArgs
}
