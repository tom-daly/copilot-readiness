@echo off
rem Copilot Readiness: double-click to start. Runs Start.ps1 in PowerShell 7.
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
    echo Copilot Readiness needs PowerShell 7.5 or later.
    echo Install it from https://aka.ms/powershell, then double-click Start.cmd again.
    echo.
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start.ps1" %*
set code=%errorlevel%
echo.
pause
exit /b %code%