@echo off
TITLE Launch StarDesk
:: gsudo intercepts these commands and natively triggers UAC
gsudo sc config StarDeskService start= demand
gsudo net start StarDeskService
start "" "C:\Program Files\StarDesk\StarDesk.exe"
exit