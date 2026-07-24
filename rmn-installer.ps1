<#
.SYNOPSIS
    RMN-Player Offline Copy Installer
.DESCRIPTION
    Simple offline installer that copies bundled player files.
    No internet, no 7-Zip, no icon patching required.
.NOTES
    Just copies files - no admin required for basic use
#>

param(
    [switch]$Update,
    [switch]$Force,
    [switch]$ConfigOnly
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# === CONFIGURATION ===
$AppName = "RMN-Player"
$InstallDir = "$env:LOCALAPPDATA\$AppName"
$ConfigDir = "$env:APPDATA\$AppName"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageConfigDir = Join-Path $ScriptDir "config"
$BundledPlayerDir = Join-Path $ScriptDir "player"

# === HELPER FUNCTIONS ===
function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    switch ($Type) {
        "Success" { Write-Host "[OK] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        "Config"  { Write-Host "[CONFIG] $Message" -ForegroundColor Magenta }
        default   { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    }
}

function Test-AdminPrivileges {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-MpvInstalled {
    return (Test-Path "$InstallDir\mpv.exe")
}

function Get-MpvVersion {
    if (Test-Path "$InstallDir\mpv.exe") {
        try {
            $output = & "$InstallDir\mpv.exe" --version 2>&1 | Select-Object -First 1
            return $output
        } catch { return "Unknown" }
    }
    return $null
}

# === CORE FUNCTIONS ===
function Copy-PlayerFiles {
    Write-Status "Copying bundled player files..." "Info"
    
    # Verify bundled player exists
    if (!(Test-Path $BundledPlayerDir)) {
        Write-Status "Bundled player folder not found at: $BundledPlayerDir" "Error"
        return $false
    }
    
    # Check for mpv.exe in bundled folder
    $bundledMpv = Join-Path $BundledPlayerDir "mpv.exe"
    if (!(Test-Path $bundledMpv)) {
        Write-Status "mpv.exe not found in bundled player folder" "Error"
        return $false
    }
    
    # Create install directory
    if (!(Test-Path $InstallDir)) { 
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null 
    }
    
    # Copy all files from bundled player folder
    Copy-Item -Path "$BundledPlayerDir\*" -Destination $InstallDir -Recurse -Force
    
    # Verify mpv.exe was copied
    if (Test-Path "$InstallDir\mpv.exe") {
        $size = (Get-Item "$InstallDir\mpv.exe").Length
        Write-Status "Player files copied to: $InstallDir ($([math]::Round($size/1MB,1)) MB)" "Success"
        return $true
    } else {
        Write-Status "Failed to copy mpv.exe" "Error"
        return $false
    }
}

function Install-ConfigFiles {
    Write-Status "Installing configuration files..." "Config"
    
    # Create config directories
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts\uosc" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts\uosc\elements" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts\uosc\lib" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\script-opts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\fonts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\watch_later" -Force | Out-Null

    # Copy config files from package
    if (Test-Path $PackageConfigDir) {
        # Main config files
        $configFiles = @("mpv.conf", "input.conf", "episode-tracker.json")
        foreach ($file in $configFiles) {
            $src = Join-Path $PackageConfigDir $file
            if (Test-Path $src) {
                try {
                    Copy-Item -Path $src -Destination $ConfigDir -Force
                    Write-Status "Copied $file" "Info"
                } catch {
                    Write-Status "Failed to copy $file : $($_.Exception.Message)" "Warning"
                }
            }
        }
        
        # Script options
        if (Test-Path "$PackageConfigDir\script-opts") {
            Copy-Item -Path "$PackageConfigDir\script-opts\*" -Destination "$ConfigDir\script-opts" -Force -Recurse
            Write-Status "Copied script-opts" "Info"
        }
        
        # Fonts
        if (Test-Path "$PackageConfigDir\fonts") {
            Copy-Item -Path "$PackageConfigDir\fonts\*" -Destination "$ConfigDir\fonts" -Force -Recurse
            Write-Status "Copied fonts" "Info"
        }
        
        # Scripts
        if (Test-Path "$PackageConfigDir\scripts") {
            Copy-Item -Path "$PackageConfigDir\scripts\*.lua" -Destination "$ConfigDir\scripts" -Force -ErrorAction SilentlyContinue
            if (Test-Path "$PackageConfigDir\scripts\uosc") {
                Copy-Item -Path "$PackageConfigDir\scripts\uosc\*" -Destination "$ConfigDir\scripts\uosc" -Force -Recurse
            }
            Write-Status "Copied scripts" "Info"
        }
        
        Write-Status "Configuration files installed" "Success"
    } else {
        Write-Status "Config folder not found at: $PackageConfigDir" "Warning"
    }
    
    # Update thumbfast config with correct mpv path
    Fix-ThumbfastConfig
}

function Fix-ThumbfastConfig {
    Write-Status "Configuring thumbfast thumbnail preview..." "Config"
    
    $mpvExe = "$InstallDir\mpv.exe"
    if (!(Test-Path $mpvExe)) {
        $mpvExe = "mpv"
    }

    $thumbfastConf = @"
# thumbfast.conf - Thumbnail preview configuration

# Spawn thumbnailer on file load for faster initial thumbnails
spawn_first=yes

# Use native Windows API for pipe communication (more reliable than file I/O)
direct_io=yes

# Thumbnail size
max_height=200
max_width=200

# Disable hardware decoding in thumbnail subprocess (avoids conflicts with main mpv)
hwdec=no

# Enable on network playback
network=yes

# Enable on audio playback
audio=yes

# Never quit thumbnailer - keeps it ready for instant previews
quit_after_inactivity=0

# Tone mapping for HDR content
tone_mapping=auto

# Custom path to mpv executable
mpv_path=$mpvExe
"@
    $thumbfastConf | Set-Content -Path "$ConfigDir\script-opts\thumbfast.conf" -Encoding UTF8
    Write-Status "thumbfast configured" "Success"
}

function Set-MpvHome {
    Write-Status "Setting MPV_HOME environment variable..." "Info"
    $mpvHome = $ConfigDir
    $currentHome = [Environment]::GetEnvironmentVariable("MPV_HOME", "User")
    if ($currentHome -ne $mpvHome) {
        [Environment]::SetEnvironmentVariable("MPV_HOME", $mpvHome, "User")
        $env:MPV_HOME = $mpvHome
        Write-Status "MPV_HOME set to: $mpvHome" "Success"
    } else {
        Write-Status "MPV_HOME already configured" "Info"
    }
}

function Add-ToPath {
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$InstallDir*") {
        Write-Status "Adding RMN-Player to PATH..." "Info"
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$InstallDir", "User")
        $env:Path = "$env:Path;$InstallDir"
        Write-Status "RMN-Player added to PATH" "Success"
    }
}

function Create-Shortcuts {
    Write-Status "Creating shortcuts..." "Info"

    $mpvPath = "$InstallDir\mpv.exe"
    $iconPath = "$InstallDir\rmn-icon.ico"
    
    # Use default mpv icon if custom icon doesn't exist
    if (!(Test-Path $iconPath)) {
        $iconPath = "$mpvPath,0"
    } else {
        $iconPath = "$iconPath,0"
    }

    # Desktop shortcut
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $shell = New-Object -COM WScript.Shell
    $shortcut = $shell.CreateShortcut("$desktopPath\RMN-Player.lnk")
    $shortcut.TargetPath = $mpvPath
    $shortcut.IconLocation = $iconPath
    $shortcut.Description = "RMN-Player Media Player"
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Save()
    Write-Status "Desktop shortcut created" "Success"

    # Start Menu folder and shortcuts
    $startMenuPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\RMN-Player"
    if (!(Test-Path $startMenuPath)) { 
        New-Item -ItemType Directory -Path $startMenuPath -Force | Out-Null 
    }

    # App shortcut
    $shortcut = $shell.CreateShortcut("$startMenuPath\RMN-Player.lnk")
    $shortcut.TargetPath = $mpvPath
    $shortcut.IconLocation = $iconPath
    $shortcut.Description = "RMN-Player Media Player"
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Save()
    Write-Status "Start Menu shortcut created" "Success"

    # Uninstall shortcut
    $uninstallScriptPath = Join-Path $ScriptDir "uninstall.ps1"
    if (Test-Path $uninstallScriptPath) {
        $shortcut = $shell.CreateShortcut("$startMenuPath\Uninstall RMN-Player.lnk")
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$uninstallScriptPath`""
        $shortcut.Description = "Uninstall RMN-Player"
        $shortcut.Save()
        Write-Status "Uninstall shortcut created" "Success"
    }
}

function Set-FileAssociations {
    Write-Status "Setting up file associations..." "Info"

    $mpvPath = "$InstallDir\mpv.exe"
    
    if (!(Test-Path $mpvPath)) {
        Write-Status "mpv.exe not found, skipping file associations" "Warning"
        return
    }

    $extensions = @(
        ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v",
        ".mpg", ".mpeg", ".ts", ".m2ts", ".vob", ".ogv", ".3gp", ".3g2",
        ".divx", ".f4v", ".rm", ".rmvb", ".mp3", ".flac", ".wav", ".aac",
        ".ogg", ".opus", ".wma", ".m4a"
    )

    # Register RMN-Player ProgId
    $progIdRoot = "Registry::HKEY_CURRENT_USER\Software\Classes\RMN-Player"
    try {
        if (!(Test-Path $progIdRoot)) { New-Item -Path $progIdRoot -Force | Out-Null }
        Set-ItemProperty -Path $progIdRoot -Name "(Default)" -Value "RMN-Player Media File"
        Set-ItemProperty -Path $progIdRoot -Name "FriendlyAppName" -Value "RMN-Player"
        Set-ItemProperty -Path $progIdRoot -Name "DefaultIcon" -Value "`"$mpvPath`""

        $shellKey = "$progIdRoot\shell\open\command"
        if (!(Test-Path $shellKey)) { New-Item -Path $shellKey -Force | Out-Null }
        Set-ItemProperty -Path $shellKey -Name "(Default)" -Value "`"$mpvPath`" `"%1`""
    } catch {
        Write-Status "Could not register ProgId" "Warning"
    }

    # Register for each extension
    foreach ($ext in $extensions) {
        $extProgId = "RMN-Player$ext"
        try {
            $extKey = "Registry::HKEY_CURRENT_USER\Software\Classes\$extProgId"
            if (!(Test-Path $extKey)) { New-Item -Path $extKey -Force | Out-Null }
            Set-ItemProperty -Path $extKey -Name "(Default)" -Value "RMN-Player Media File"
            Set-ItemProperty -Path $extKey -Name "DefaultIcon" -Value "`"$mpvPath`""

            $extShell = "$extKey\shell\open\command"
            if (!(Test-Path $extShell)) { New-Item -Path $extShell -Force | Out-Null }
            Set-ItemProperty -Path $extShell -Name "(Default)" -Value "`"$mpvPath`" `"%1`""

            $openWith = "Registry::HKEY_CURRENT_USER\Software\Classes\$ext\OpenWithProgids"
            if (!(Test-Path $openWith)) { New-Item -Path $openWith -Force | Out-Null }
            Set-ItemProperty -Path $openWith -Name $extProgId -Value ""

            $openWithList = "Registry::HKEY_CURRENT_USER\Software\Classes\$ext\OpenWithList"
            if (!(Test-Path $openWithList)) { New-Item -Path $openWithList -Force | Out-Null }
            Set-ItemProperty -Path $openWithList -Name "RMN-Player.exe" -Value ""
            Set-ItemProperty -Path $openWithList -Name "mpv.exe" -Value ""
        } catch {}
    }
    Write-Status "File associations configured" "Success"
}

function Register-Uninstall {
    Write-Status "Creating uninstall entry..." "Info"

    $mpvPath = "$InstallDir\mpv.exe"
    $iconPath = "$InstallDir\rmn-icon.ico"
    
    $uninstallScriptPath = Join-Path $ScriptDir "uninstall.ps1"
    if (Test-Path $uninstallScriptPath) {
        $uninstallCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$uninstallScriptPath`""
    } else {
        $uninstallCmd = "powershell.exe -ExecutionPolicy Bypass -Command `"Remove-Item -Path '$InstallDir' -Recurse -Force; Remove-Item -Path '$ConfigDir' -Recurse -Force`""
    }

    $uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RMN-Player"

    try {
        New-Item -Path $uninstallKey -Force | Out-Null
        Set-ItemProperty -Path $uninstallKey -Name "DisplayName" -Value "RMN-Player"
        Set-ItemProperty -Path $uninstallKey -Name "DisplayVersion" -Value "1.0.0"
        Set-ItemProperty -Path $uninstallKey -Name "Publisher" -Value "RMN-Player"
        Set-ItemProperty -Path $uninstallKey -Name "InstallLocation" -Value $InstallDir
        Set-ItemProperty -Path $uninstallKey -Name "UninstallString" -Value "`"$uninstallCmd`""
        Set-ItemProperty -Path $uninstallKey -Name "QuietUninstallString" -Value "`"$uninstallCmd`""
        Set-ItemProperty -Path $uninstallKey -Name "NoModify" -Value 1 -Type DWord
        Set-ItemProperty -Path $uninstallKey -Name "NoRepair" -Value 1 -Type DWord
        Set-ItemProperty -Path $uninstallKey -Name "EstimatedSize" -Value 50000 -Type DWord
        if (Test-Path $iconPath) {
            Set-ItemProperty -Path $uninstallKey -Name "DisplayIcon" -Value "`"$iconPath`""
        }
        $installDate = Get-Date -Format "yyyyMMdd"
        Set-ItemProperty -Path $uninstallKey -Name "InstallDate" -Value $installDate
        Write-Status "Uninstall entry created" "Success"
    } catch {
        Write-Status "Could not create uninstall entry: $($_.Exception.Message)" "Warning"
    }
}

# === MAIN SCRIPT ===
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "    RMN-Player Offline Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Offline copy-based installer (no downloads)" -ForegroundColor Yellow
Write-Host ""

$isAdmin = Test-AdminPrivileges
if ($isAdmin) {
    Write-Status "Running as Administrator" "Success"
} else {
    Write-Status "Running as standard user" "Info"
}

# Check if bundled player exists
if (!(Test-Path $BundledPlayerDir)) {
    Write-Host ""
    Write-Host "ERROR: Bundled player folder not found!" -ForegroundColor Red
    Write-Host "Make sure the 'player' folder exists in the same directory as this script." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Check if mpv.exe exists in bundled folder
$bundledMpv = Join-Path $BundledPlayerDir "mpv.exe"
if (!(Test-Path $bundledMpv)) {
    Write-Host ""
    Write-Host "ERROR: mpv.exe not found in player folder!" -ForegroundColor Red
    Write-Host "The 'player' folder must contain mpv.exe" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

if ($ConfigOnly) {
    Install-ConfigFiles
    Write-Host ""
    Write-Status "Configuration updated!" "Success"
    exit 0
}

$installed = Test-MpvInstalled

if ($installed -and !$Update -and !$Force) {
    $version = Get-MpvVersion
    Write-Status "RMN-Player is already installed" "Success"
    Write-Status "Version: $version" "Info"
    Write-Host ""
    Write-Status "Performing update (config + shortcuts)..." "Info"
    Set-MpvHome
    Install-ConfigFiles
    Create-Shortcuts
    Set-FileAssociations
    Register-Uninstall
} else {
    # Fresh install or force reinstall
    Write-Status "Installing RMN-Player..." "Info"
    
    # Copy player files
    $copied = Copy-PlayerFiles
    if (-not $copied) {
        Write-Host ""
        Write-Host "Installation failed - could not copy player files" -ForegroundColor Red
        exit 1
    }
    
    # Setup
    Add-ToPath
    Set-MpvHome
    Install-ConfigFiles
    Create-Shortcuts
    Set-FileAssociations
    Register-Uninstall
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "    Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Status "RMN-Player installed to: $InstallDir" "Success"
Write-Status "Config files at: $ConfigDir" "Success"
Write-Host ""
Write-Host "Created:" -ForegroundColor Yellow
Write-Host "  - Desktop shortcut (RMN-Player.lnk)"
Write-Host "  - Start Menu shortcut"
Write-Host "  - File associations"
Write-Host "  - PATH entry"
Write-Host ""
Write-Host "Key bindings:" -ForegroundColor Yellow
Write-Host "  ENTER      - Toggle fullscreen"
Write-Host "  LEFT/RIGHT - Seek 3 seconds"
Write-Host "  UP/DOWN    - Adjust volume"
Write-Host "  m          - Open menu (uosc)"
Write-Host "  c          - Subtitles"
Write-Host "  a          - Audio tracks"
Write-Host ""
Write-Host "Thumbnail preview: Hover over timeline" -ForegroundColor Green
Write-Host ""
