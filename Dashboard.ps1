param(
    [string]$AutoCommitWorkloadName,
    [string]$ObserveWorkloadName,
    [int]$ObserveSeconds = 10
)

$ErrorActionPreference = "Stop"
$implPath = Join-Path -Path $PSScriptRoot -ChildPath "Dashboard.Impl.ps1"

if (-not (Test-Path -LiteralPath $implPath)) {
    throw "Missing Dashboard.Impl.ps1 next to Dashboard.ps1."
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshCmd = Get-Command -Name "pwsh.exe" -ErrorAction SilentlyContinue
    if ($null -eq $pwshCmd) {
        Write-Host "WorkspaceManager Dashboard requires PowerShell 7+ (pwsh.exe)." -ForegroundColor Red
        Write-Host "Windows PowerShell cannot run this script. Install PowerShell 7 from https://aka.ms/powershell" -ForegroundColor Yellow
        if ($Host.Name -eq "ConsoleHost") {
            Write-Host ""
            Write-Host "Press Enter to close this window."
            $null = Read-Host
        }
        exit 1
    }

    # Run pwsh in THIS console (do not Start-Process then exit): a separate short-lived
    # Explorer console plus Start-Process can leave pwsh without a usable console stdin,
    # so [Console]::KeyAvailable throws and the dashboard exits immediately.
    Set-Location -LiteralPath $PSScriptRoot
    Write-Host "Starting WorkspaceManager dashboard (PowerShell 7)..." -ForegroundColor DarkGray

    $pwshArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $implPath,
        "-ObserveSeconds", $ObserveSeconds
    )
    if (-not [string]::IsNullOrWhiteSpace($AutoCommitWorkloadName)) {
        $pwshArgs += @("-AutoCommitWorkloadName", $AutoCommitWorkloadName)
    }
    if (-not [string]::IsNullOrWhiteSpace($ObserveWorkloadName)) {
        $pwshArgs += @("-ObserveWorkloadName", $ObserveWorkloadName)
    }

    & $pwshCmd.Source @pwshArgs
    exit $LASTEXITCODE
}

try {
    if ($MyInvocation.InvocationName -ne ".") {
        Set-Variable -Name WorkspaceManagerDashboardEntryBootstrap -Scope Global -Value $true
    }
    . $implPath @PSBoundParameters
} finally {
    Remove-Variable -Name WorkspaceManagerDashboardEntryBootstrap -Scope Global -ErrorAction SilentlyContinue
}
