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

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Generate-Shortcuts.ps1" %*
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" pause
exit /b %ERR%
