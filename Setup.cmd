@echo off
setlocal EnableExtensions
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh.exe^) was not found on PATH.
    echo Install from https://aka.ms/powershell
    pause
    exit /b 1
)

set "CREATE_SHORTCUT_SCRIPT=%~dp0Scripts\Create-DashboardShortcut.ps1"
set "GENERATE_SHORTCUTS_SCRIPT=%~dp0Scripts\Generate-Shortcuts.ps1"
set "ROOT_SHORTCUT=%~dp0Workspace Manager Dashboard.lnk"
set "ROOT_CONFIG_SHORTCUT=%~dp0Workspace Manager Config.lnk"
set "WORKSPACES_JSON=%~dp0Scripts\workspaces.json"

echo [SETUP] Creating project-root dashboard shortcut...
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%CREATE_SHORTCUT_SCRIPT%" -ShortcutPath "%ROOT_SHORTCUT%"
if errorlevel 1 goto :capture_fail

echo [SETUP] Creating project-root workspaces shortcut...
pwsh.exe -NoProfile -Command "$ws='%WORKSPACES_JSON%'; $lnk='%ROOT_CONFIG_SHORTCUT%'; if (-not (Test-Path -LiteralPath $ws)) { throw \"Missing workspaces.json at '$ws'.\" }; $w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($lnk); $s.TargetPath=$ws; $s.WorkingDirectory=Split-Path -Path $ws -Parent; $s.Description='WorkspaceManager configuration (workspaces.json)'; $s.Save()"
if errorlevel 1 goto :capture_fail

set "DESKTOP_ON=1"
set "STARTMENU_ON=1"

:menu
cls
echo(
echo Optional shortcuts:
if "%DESKTOP_ON%"=="1" (
    set "DESKTOP_STATE=ON"
) else (
    set "DESKTOP_STATE=OFF"
)
if "%STARTMENU_ON%"=="1" (
    set "STARTMENU_STATE=ON"
) else (
    set "STARTMENU_STATE=OFF"
)
echo   1. Desktop shortcut: %DESKTOP_STATE%
echo   2. Start Menu shortcuts: %STARTMENU_STATE%
echo(
echo Press 1/2 to toggle instantly. Press Enter to commit. Press Esc to exit.
set "KEY="
for /f %%I in ('pwsh.exe -NoProfile -Command "$k=[Console]::ReadKey($true).Key; switch ($k) { 'D1' {'1'} 'NumPad1' {'1'} 'D2' {'2'} 'NumPad2' {'2'} 'Enter' {'ENTER'} 'Escape' {'ESC'} default {'OTHER'} }"') do set "KEY=%%I"
if "%KEY%"=="ENTER" goto :commit
if "%KEY%"=="ESC" goto :cancel
if "%KEY%"=="1" (
    if "%DESKTOP_ON%"=="1" (set "DESKTOP_ON=0") else (set "DESKTOP_ON=1")
    goto :menu
)
if "%KEY%"=="2" (
    if "%STARTMENU_ON%"=="1" (set "STARTMENU_ON=0") else (set "STARTMENU_ON=1")
    goto :menu
)
echo Invalid key. Use 1, 2, or Enter.
goto :menu

:commit
if "%DESKTOP_ON%"=="1" (
    echo [SETUP] Creating Desktop shortcut...
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%CREATE_SHORTCUT_SCRIPT%"
    if errorlevel 1 goto :capture_fail
)

if "%STARTMENU_ON%"=="1" (
    echo [SETUP] Generating Start Menu shortcuts...
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%GENERATE_SHORTCUTS_SCRIPT%"
    if errorlevel 1 goto :capture_fail
)

echo [SUCCESS] Setup complete.
exit /b 0

:cancel
echo [CANCELLED] Setup cancelled by user.
exit /b 0

:capture_fail
set "ERR=%ERRORLEVEL%"
:fail
if "%ERR%"=="" set "ERR=1"
echo [ERROR] Setup failed with exit code %ERR%.
pause
exit /b %ERR%
