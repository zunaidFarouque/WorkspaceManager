param(
    [Parameter(Mandatory=$true)]
    [string]$AppName,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("Start", "Kill")]
    [string]$Action
)

# Load the database
$jsonPath = Join-Path $PSScriptRoot "apps.json"
if (-not (Test-Path $jsonPath)) { Write-Error "apps.json not found."; exit }

$db = Get-Content $jsonPath | ConvertFrom-Json
$appData = $db.$AppName

if ($null -eq $appData) { Write-Error "App '$AppName' not defined in apps.json."; exit }

# --- START PROTOCOL ---
if ($Action -eq "Start") {
    Write-Host "Starting $AppName Container..." -ForegroundColor Cyan
    foreach ($svc in $appData.services) {
        gsudo sc config $svc start= demand | Out-Null
        gsudo net start $svc | Out-Null
    }
    if ($appData.executable -ne "") {
        Start-Process $appData.executable
    }
}

# --- KILL PROTOCOL ---
elseif ($Action -eq "Kill") {
    Write-Host "Assassinating $AppName Container..." -ForegroundColor Red
    foreach ($proc in $appData.processes) {
        gsudo taskkill /F /IM $proc /T 2>&1 | Out-Null
    }
    foreach ($svc in $appData.services) {
        gsudo net stop $svc /y 2>&1 | Out-Null
        gsudo sc config $svc start= disabled | Out-Null
    }
}
Start-Sleep -Seconds 1