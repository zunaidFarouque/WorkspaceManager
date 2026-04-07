@echo off
TITLE Windows Deep Purge Protocol
color 0C

where gsudo >nul 2>&1
if errorlevel 1 (
echo [ERROR] gsudo was not found in PATH. Cannot run admin commands.
pause
exit /b 1
)

echo =======================================================
echo 1. HALTING UPDATE SERVICES...
echo =======================================================
gsudo net stop wuauserv /y >nul 2>&1
gsudo net stop dosvc /y >nul 2>&1

echo.
echo =======================================================
echo 2. VAPORIZING DELIVERY OPTIMIZATION CACHE (3.3 GB)...
echo =======================================================
gsudo rd /s /q "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" 2>nul
:: Permanently disable the Delivery Optimization service
gsudo sc config dosvc start= disabled >nul
if errorlevel 1 (
echo [WARN] Could not set dosvc to disabled. Delivery Optimization may re-enable itself.
)

echo.
echo =======================================================
echo 3. PURGING STALE UPDATE DOWNLOADS (2.0 GB)...
echo =======================================================
gsudo rd /s /q "C:\Windows\SoftwareDistribution\Download" 2>nul
timeout /t 1 /nobreak >nul
gsudo mkdir "C:\Windows\SoftwareDistribution\Download" 2>nul
if errorlevel 1 (
echo [ERROR] Failed to recreate C:\Windows\SoftwareDistribution\Download.
echo Aborting to avoid leaving Windows Update cache in a bad state.
pause
exit /b 1
)

echo.
echo =======================================================
echo 4. COMPRESSING WINSXS COMPONENT STORE...
echo (This step may take 3 to 10 minutes. Do not close.)
echo =======================================================
gsudo dism.exe /Online /Cleanup-Image /StartComponentCleanup
set DISM_ERR=%errorlevel%
if %DISM_ERR% neq 0 if %DISM_ERR% neq 3010 (
echo [ERROR] DISM component cleanup failed with code %DISM_ERR%.
echo This is a major failure. Check CBS/DISM logs before retrying.
pause
exit /b 1
)

echo.
echo =======================================================
echo 5. RESTARTING ESSENTIAL UPDATE SERVICE...
echo =======================================================
gsudo net start wuauserv >nul 2>&1
if errorlevel 1 (
echo [WARN] Could not restart wuauserv. Reboot or start it manually if Windows Update is needed.
)

echo.
echo [ SUCCESS ] Purge complete. 
echo Run WizTree again to verify your reclaimed SSD space.
pause
exit
