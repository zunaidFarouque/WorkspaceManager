@echo off
cls

REM ============================================================================
REM ==                Check for Administrator Privileges                      ==
REM ============================================================================
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    echo Please accept the UAC prompt to continue.
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

REM ============================================================================
REM ==                Main Script (Running as Administrator)                  ==
REM ============================================================================
:main
cls
echo ========================================================
echo  Windows Virtualization & Emulator Configuration Utility
echo ========================================================
echo.
echo This utility configures your system for two scenarios:
echo.
echo  - Docker/WSL2 Mode: Enables Hyper-V and all related platforms.
echo  - Nox/Emulator Mode: Disables Hyper-V to allow emulators
echo    like NoxPlayer or BlueStacks to use VT-x directly.
echo.

REM --- Check current bcdedit state ---
set "hypervisorState=Unknown"
for /f "tokens=2" %%a in ('bcdedit /enum {current} ^| findstr "hypervisorlaunchtype"') do set "hypervisorState=%%a"

REM --- Check current Hyper-V feature state ---
set "hyperVState=Disabled"
dism /online /get-featureinfo /featurename:Microsoft-Hyper-V-All | find "State : Enabled" > nul && set "hyperVState=Enabled"

echo ----------------- CURRENT STATUS -----------------
echo  Hypervisor Launch Type : %hypervisorState%
echo  Hyper-V Platform Status: %hyperVState%
echo ----------------------------------------------------
echo.

if /i "%hypervisorState%"=="Auto" (
    echo   Your system appears to be configured for Docker/WSL2.
) else if /i "%hypervisorState%"=="Off" (
    echo   Your system appears to be configured for Nox/Emulators.
)

echo.
echo Please choose an option:
echo.
echo   1. Configure for Docker, WSL2, etc. (Enable Hyper-V)
echo   2. Configure for Nox, BlueStacks, etc. (Disable Hyper-V)
echo   3. Exit
echo.

set /p "choice=Enter your choice (1, 2, or 3): "

if "%choice%"=="1" goto :enableHyperV
if "%choice%"=="2" goto :disableHyperV
if "%choice%"=="3" goto :exit

echo Invalid choice.
timeout /t 3 > nul
goto :main


:enableHyperV
cls
echo ========================================================
echo      Enabling Hyper-V for Docker/WSL2...
echo ========================================================
echo.
echo [+] Setting boot loader to auto-launch hypervisor...
bcdedit /set hypervisorlaunchtype Auto
echo.

echo [+] Enabling 'Microsoft-Hyper-V-All'...
dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart
echo.

echo [+] Enabling 'VirtualMachinePlatform'...
dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
echo.

echo [!] CRITICAL: Enabling 'Windows Subsystem for Linux' feature...
dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
echo.

echo [+] Checking for and enabling 'WindowsHypervisorPlatform'...
dism /online /get-featureinfo /featurename:WindowsHypervisorPlatform >nul 2>&1
if %errorlevel% equ 0 (
    echo    - Feature found. Enabling now...
    dism /online /enable-feature /featurename:WindowsHypervisorPlatform /all /norestart
) else (
    echo    - WARNING: Feature 'WindowsHypervisorPlatform' not found on this system. Skipping.
    echo      This is normal for some Windows versions and typically not a problem.
)

echo.
echo --------------------------------------------------------------------
echo  Configuration complete!
echo.
echo  IMPORTANT: A FULL RESTART is required for all changes to take effect.
echo  Please save your work and restart your computer.
echo --------------------------------------------------------------------
echo.
goto :end


:disableHyperV
cls
echo ========================================================
echo      Disabling Hyper-V for Nox/Emulators...
echo ========================================================
echo.
echo [+] Setting boot loader to NOT launch hypervisor...
bcdedit /set hypervisorlaunchtype Off
echo.

echo [+] Disabling ALL conflicting Windows features...
echo (This may take a few moments)
echo.

dism /online /disable-feature /featurename:Microsoft-Hyper-V-All /norestart
dism /online /disable-feature /featurename:VirtualMachinePlatform /norestart
dism /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux /norestart

REM Check for optional features before trying to disable them
dism /online /get-featureinfo /featurename:WindowsHypervisorPlatform >nul 2>&1
if %errorlevel% equ 0 ( dism /online /disable-feature /featurename:WindowsHypervisorPlatform /norestart )
dism /online /get-featureinfo /featurename:Windows-Sandbox >nul 2>&1
if %errorlevel% equ 0 ( dism /online /disable-feature /featurename:Windows-Sandbox /norestart )
dism /online /get-featureinfo /featurename:Containers-DisposableClientVM >nul 2>&1
if %errorlevel% equ 0 ( dism /online /disable-feature /featurename:Containers-DisposableClientVM /norestart )

echo.
echo --------------------------------------------------------------------
echo  Configuration complete!
echo.
echo  IMPORTANT: A FULL RESTART is required for all changes to take effect.
echo  Please save your work and restart your computer.
echo --------------------------------------------------------------------
echo.
goto :end


:end
pause
exit

:exit
exit