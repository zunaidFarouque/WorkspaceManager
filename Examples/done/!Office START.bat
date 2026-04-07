@echo off
TITLE Launch Office Environment
echo Waking up Microsoft Office environment...

where gsudo >nul 2>&1
if errorlevel 1 (
echo [ERROR] gsudo was not found in PATH. Cannot run admin commands.
timeout /t 3 >nul
exit /b 1
)

:: Re-enable and start the Office background service using gsudo
gsudo sc config ClickToRunSvc start= demand >nul
if errorlevel 1 echo [WARN] Could not set ClickToRunSvc startup type to demand.
gsudo net start ClickToRunSvc 2>nul
if errorlevel 1 echo [WARN] ClickToRunSvc may already be running or failed to start.
gsudo sc config osppsvc start= demand >nul
if errorlevel 1 echo [WARN] Could not set osppsvc startup type to demand.
gsudo net start osppsvc 2>nul
if errorlevel 1 echo [WARN] osppsvc may already be running or failed to start.

:: Launch OneDrive safely as standard user
set "OD_PATH_1=%localappdata%\Microsoft\OneDrive\OneDrive.exe"
set "OD_PATH_2=C:\Program Files\Microsoft OneDrive\OneDrive.exe"

if exist "%OD_PATH_1%" (
start "" "%OD_PATH_1%"
) else if exist "%OD_PATH_2%" (
start "" "%OD_PATH_2%"
) else (
echo [WARN] OneDrive executable not found in standard directories.
)

echo Office Background Services and OneDrive are active.
timeout /t 3 >nul
exit
