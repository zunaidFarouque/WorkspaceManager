@echo off
TITLE Office Containment Protocol

where gsudo >nul 2>&1
if errorlevel 1 (
    echo [ERROR] gsudo was not found in PATH. Cannot run admin commands.
    timeout /t 3 >nul
    exit /b 1
)

:: Scan RAM for active Office applications
tasklist | findstr /i "WINWORD.EXE EXCEL.EXE POWERPNT.EXE ONENOTE.EXE OUTLOOK.EXE MSACCESS.EXE MSPUB.EXE" >nul
if errorlevel 1 goto :kill_sequence

:: If the script reaches here, an Office app is currently running.
color 4F
echo =======================================================
echo DANGER: ACTIVE OFFICE APPS DETECTED IN MEMORY!
echo =======================================================
echo You have Word, Excel, PowerPoint, or OneNote currently running.
echo If you proceed, ALL UNSAVED WORK WILL BE INSTANTLY DESTROYED.
echo.
set /p confirm1="1. Are you sure you want to kill Office? (Y/N): "
if /i not "%confirm1%"=="Y" goto :abort

echo.
set /p confirm2="2. Are you ABSOLUTELY sure? Unsaved data will die. (Y/N): "
if /i not "%confirm2%"=="Y" goto :abort

echo.
set /p confirm3="3. Final safety check. Type 'KILL' to execute: "
if /i not "%confirm3%"=="KILL" goto :abort

:: Revert color to normal if user passes all 3 checks
color 07
goto :kill_sequence

:abort
color 07
echo.
echo Aborting containment. Your work is safe.
timeout /t 3 >nul
exit

:kill_sequence
echo.
echo Executing Office Containment Protocol...

:: Force kill OneDrive
taskkill /f /im OneDrive.exe 2>nul

:: Force kill Core Office apps
gsudo taskkill /f /im WINWORD.EXE 2>nul
gsudo taskkill /f /im EXCEL.EXE 2>nul
gsudo taskkill /f /im POWERPNT.EXE 2>nul
gsudo taskkill /f /im ONENOTE.EXE 2>nul

:: Force kill ProPlus Bloatware
gsudo taskkill /f /im OUTLOOK.EXE 2>nul
gsudo taskkill /f /im MSACCESS.EXE 2>nul
gsudo taskkill /f /im MSPUB.EXE 2>nul
gsudo taskkill /f /im lync.exe 2>nul
gsudo taskkill /f /im msteams.exe 2>nul

:: Stop and disable the Office background service
gsudo net stop ClickToRunSvc /y 2>nul
if errorlevel 1 echo [WARN] ClickToRunSvc may already be stopped or failed to stop.
gsudo sc config ClickToRunSvc start= disabled >nul
if errorlevel 1 (
    echo [WARN] Failed to disable ClickToRunSvc. Office background service may restart later.
)
gsudo net stop osppsvc /y 2>nul
if errorlevel 1 echo [WARN] osppsvc may already be stopped or failed to stop.
gsudo sc config osppsvc start= disabled >nul
if errorlevel 1 (
    echo [WARN] Failed to disable osppsvc. Licensing checks may still run in background.
)

echo Office environment terminated. Zero background processes running.
timeout /t 3 >nul
exit
