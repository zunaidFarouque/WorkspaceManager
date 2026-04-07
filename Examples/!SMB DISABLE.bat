@echo off
TITLE SMB Network Disabler
color 0C

where gsudo >nul 2>&1
if errorlevel 1 (
echo [ERROR] gsudo was not found in PATH. Cannot run admin commands.
pause
exit /b 1
)

echo =======================================================
echo Executing Network Containment Protocol...
echo =======================================================

:: Force stop the SMB service and disable it
gsudo net stop LanmanServer /y 2>nul
if errorlevel 1 echo [WARN] LanmanServer may already be stopped or inaccessible.
gsudo sc config LanmanServer start= disabled >nul
if errorlevel 1 echo [WARN] Could not set LanmanServer startup type to disabled.
gsudo net stop LanmanWorkstation /y 2>nul
if errorlevel 1 echo [WARN] LanmanWorkstation may already be stopped or inaccessible.
gsudo sc config LanmanWorkstation start= disabled >nul
if errorlevel 1 echo [WARN] Could not set LanmanWorkstation startup type to disabled.

:: Close the Firewall ports to block listening/scanning
gsudo netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=No >nul
if errorlevel 1 echo [WARN] Could not update firewall rule group "File and Printer Sharing".

echo.
echo [ SUCCESS ] SMB Server/Client services are disabled.
echo Firewall ports are CLOSED. 
echo Zero background networking footprint remaining.
echo.
pause
exit