@echo off
powershell.exe -NoLogo -NoProfile -STA -File "%~dp0Start-Transportlogg.ps1" -Demo
if errorlevel 1 pause
