$jsonPath = Join-Path $PSScriptRoot "apps.json"
$db = Get-Content $jsonPath | ConvertFrom-Json

# Target the actual Windows Start Menu Programs folder
$shortcutDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Orchestrator"
if (-not (Test-Path $shortcutDir)) { New-Item -ItemType Directory -Path $shortcutDir | Out-Null }

$WshShell = New-Object -ComObject WScript.Shell

# Loop through every app in the JSON and spit out Start/Kill shortcuts
foreach ($app in $db.psobject.properties.name) {
    
    # 1. Generate Start Shortcut
    $startPath = Join-Path $shortcutDir "!Start-$app.lnk"
    $startLnk = $WshShell.CreateShortcut($startPath)
    $startLnk.TargetPath = "pwsh.exe"
    $startLnk.Arguments = "-WindowStyle Minimized -File `"$PSScriptRoot\Orchestrator.ps1`" -AppName `"$app`" -Action Start"
    $startLnk.Save()

    # 2. Generate Kill Shortcut
    $killPath = Join-Path $shortcutDir "!Kill-$app.lnk"
    $killLnk = $WshShell.CreateShortcut($killPath)
    $killLnk.TargetPath = "pwsh.exe"
    $killLnk.Arguments = "-WindowStyle Minimized -File `"$PSScriptRoot\Orchestrator.ps1`" -AppName `"$app`" -Action Kill"
    $killLnk.Save()
}

Write-Host "[ SUCCESS ] Shortcuts generated in Start Menu/Orchestrator." -ForegroundColor Green
Start-Sleep -Seconds 3