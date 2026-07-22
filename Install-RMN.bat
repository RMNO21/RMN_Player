@echo off
title RMN-Player Installer
echo.
echo ========================================
echo    RMN-Player Installer
echo ========================================
echo.
echo This will install/update RMN-Player and configure it with your settings.
echo.
echo Required: 7-Zip (will be installed if missing)
echo.
pause
echo.

:: Check for admin privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell -ExecutionPolicy Bypass -File "%~dp0rmn-installer.ps1"
echo.
pause
