@echo off
setlocal
title Hatch IQ OpenClaw - Restore Existing Backup on New PC
cd /d "%~dp0"
mode con: cols=120 lines=42 >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenClaw-Backup-Migrate.ps1" -NewPC
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo Restore exited with code %EXITCODE%.
pause
exit /b %EXITCODE%
