@echo off
setlocal
title Hatch IQ OpenClaw - Check Existing Backup New-PC Prerequisites
cd /d "%~dp0"
mode con: cols=120 lines=42 >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenClaw-Backup-Migrate.ps1" -NewPC -PrerequisiteCheckOnly
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo Prerequisite check exited with code %EXITCODE%.
pause
exit /b %EXITCODE%
