@echo off
setlocal
title OpenClaw Backup and Migration Toolkit
cd /d "%~dp0"

rem Keep classic console / Windows Terminal rendering compact and readable.
mode con: cols=120 lines=42 >nul 2>&1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenClaw-Backup-Migrate.ps1"
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" echo OpenClaw toolkit exited with code %EXITCODE%.
pause
exit /b %EXITCODE%
