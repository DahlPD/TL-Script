@echo off
powershell.exe -NoLogo -NoProfile -STA -File "%~dp0Start-Transportlogg.ps1"
if errorlevel 1 pause
