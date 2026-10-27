@echo off
set "TL_DEMO_ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -STA -Command "& (Join-Path $env:TL_DEMO_ROOT ('Handl' + [char]228 + 'ggare\Start-Transportlogg.ps1')) -Demo"
if errorlevel 1 pause
