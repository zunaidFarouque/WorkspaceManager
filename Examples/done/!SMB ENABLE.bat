@echo off
TITLE SMB Network Enabler
color 0B

where gsudo >nul 2>&1
if errorlevel 1 (
echo [ERROR] gsudo was not found in PATH. Cannot run admin commands.
pause
exit /b 1
)

echo =======================================================
echo Waking up Local SMB Server and Firewall...
echo =======================================================

:: Set the SMB service to manual and start it
gsudo sc config LanmanServer start= demand >nul
if errorlevel 1 echo [WARN] Could not set LanmanServer startup type to manual.
gsudo net start LanmanServer 2>nul
if errorlevel 1 echo [WARN] LanmanServer may already be running or failed to start.
gsudo sc config LanmanWorkstation start= demand >nul
if errorlevel 1 echo [WARN] Could not set LanmanWorkstation startup type to manual.
gsudo net start LanmanWorkstation 2>nul
if errorlevel 1 echo [WARN] LanmanWorkstation may already be running or failed to start.

:: Open the Firewall ports for local sharing
gsudo netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes >nul
if errorlevel 1 echo [WARN] Could not update firewall rule group "File and Printer Sharing".

echo.
echo [ SUCCESS ] SMB Sharing is now ACTIVE.
echo.
echo =======================================================
echo YOUR AVAILABLE LOCAL IP ADDRESSES:
echo =======================================================
:: Filter ipconfig to only show IPv4 addresses
ipconfig | findstr /C:"IPv4 Address"

echo.
echo Use one of the IPs above in MiXplorer (e.g., smb://192.168.x.x)
echo.
pause
exit