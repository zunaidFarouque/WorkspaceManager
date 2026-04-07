@echo off
TITLE Terminate StarDesk
gsudo taskkill /F /IM StarDesk.exe /T
gsudo net stop StarDeskService /y
gsudo sc config StarDeskService start= disabled
exit