# RMN-Player Uninstaller
$ErrorActionPreference = "SilentlyContinue"

Write-Host "Uninstalling RMN-Player..."

# 1. Remove shortcuts
$startMenuPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\RMN-Player"
$desktopPath = [Environment]::GetFolderPath("Desktop")
if (Test-Path $startMenuPath) { Remove-Item -Path $startMenuPath -Recurse -Force }
if (Test-Path "$desktopPath\RMN-Player.lnk") { Remove-Item "$desktopPath\RMN-Player.lnk" -Force }

# 2. Remove environment variables
$p = [Environment]::GetEnvironmentVariable("Path", "User")
if ($p -match "RMN-Player") {
    $newPath = ($p -split ";" | Where-Object { $_ -notmatch "RMN-Player" }) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}
[Environment]::SetEnvironmentVariable("MPV_HOME", $null, "User")

# 3. Remove config directory
$ConfigDir = "$env:APPDATA\RMN-Player"
if (Test-Path $ConfigDir) { Remove-Item -Path $ConfigDir -Recurse -Force }

# 4. Remove registry entries
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$regRoot = if ($isAdmin) { "HKLM:\SOFTWARE" } else { "HKCU:\SOFTWARE" }
Remove-Item -Path "$regRoot\Microsoft\Windows\CurrentVersion\Uninstall\RMN-Player" -Recurse -Force
Remove-Item -Path "$regRoot\Clients\Media\RMN-Player" -Recurse -Force
Remove-Item -Path "$regRoot\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe" -Force
Remove-Item -Path "$regRoot\Microsoft\Windows\CurrentVersion\App Paths\RMN-Player.exe" -Force
Remove-Item -Path "$regRoot\Classes\Applications\mpv.exe" -Recurse -Force
Remove-Item -Path "Registry::HKEY_CURRENT_USER\Software\Classes\RMN-Player" -Recurse -Force
Remove-Item -Path "Registry::HKEY_CURRENT_USER\Software\Classes\mpv.exe" -Recurse -Force

# 5. Remove install directory (everything except this script)
$installDir = "$env:LOCALAPPDATA\RMN-Player"
Get-ChildItem -Path $installDir -File | Where-Object { $_.Name -ne "uninstall.ps1" } | Remove-Item -Force
Get-ChildItem -Path $installDir -Directory -Recurse | Remove-Item -Recurse -Force

Write-Host "RMN-Player has been uninstalled."
Write-Host "Note: The uninstall folder will be cleaned up on next install."
