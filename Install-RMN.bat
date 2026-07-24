@echo off
title RMN-Player Offline Installer
echo.
echo ========================================
echo    RMN-Player Offline Installer
echo ========================================
echo.
echo This will install/update RMN-Player.
echo No internet connection required.
echo.
pause
echo.

:: Write a temp launcher script to avoid cmd.exe parentheses issues with paths
echo Set-Location '%~dp0' > "%TEMP%\rmn_run.ps1"
echo ^& '.\rmn-installer.ps1' >> "%TEMP%\rmn_run.ps1"

:: Check for admin privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\rmn_run.ps1" -Verb RunAs
    exit /b
)

:: Run the installer
echo Running installer...
echo.
powershell -ExecutionPolicy Bypass -NoProfile -File "%TEMP%\rmn_run.ps1"
set "PS_ERROR=%ERRORLEVEL%"

echo.
if %PS_ERROR% neq 0 (
    echo ========================================
    echo    Installation encountered errors!
    echo ========================================
    echo    Error code: %PS_ERROR%
    echo.
    echo    Please check the output above.
) else (
    echo ========================================
    echo    Installation finished successfully!
    echo ========================================
)
echo.
pause
