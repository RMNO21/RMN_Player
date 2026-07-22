<#
.SYNOPSIS
    RMN-Player Media Player Installer - MPV Player Wrapper with Custom Configuration
    
.DESCRIPTION
    Complete MPV installer with custom configuration, shortcuts, file associations, and UI customizations.
    
.LICENSE
    GNU General Public License v3.0 - see LICENSE file for details
    
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    GNU General Public License for more details.
    
    You should have received a copy of the GNU General Public License
    along with this program. If not, see <https://www.gnu.org/licenses/>.

.CREDITS
    - uosc (https://github.com/tomasklaen/uosc) - Modern UI framework
    - thumbfast (https://github.com/po5/thumbfast) - Thumbnail preview
    - mpv-player (https://github.com/mpv-player/mpv) - Media player core
    - autoload.lua - Playlist autoloading
    - Resource Hacker - PE resource editing utility
    
.NOTES
    Run as Administrator for full functionality
    
.AUTHOR
    RMNO21
    
#>

param(
    [switch]$Update,
    [switch]$Force,
    [switch]$ConfigOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Enable TLS 1.2 early - needed for all .NET web requests
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
} catch {}
# ServerCertificateCustomValidationCallback only exists in .NET Core / PowerShell 7+
try {
    [Net.ServicePointManager]::ServerCertificateCustomValidationCallback = { $true }
} catch {
    # PowerShell 5.1 on .NET Framework doesn't have this - skip it
}

# Load HttpClient assembly (not loaded by default in PS 5.1)
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {}

# === CONFIGURATION ===
$AppName = "RMN-Player"
$InstallDir = "$env:LOCALAPPDATA\$AppName"
$ConfigDir = "$env:APPDATA\$AppName"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageConfigDir = Join-Path $ScriptDir "config"

# === ICON PATCHING ===

function Get-ResourceHacker {
    # Fully offline installer - no downloads allowed
    # ResourceHacker.exe must be bundled in tools/ folder

    # Check bundled tools folder first
    $rhDir = Join-Path $ScriptDir "tools"
    $rhExe = Join-Path $rhDir "ResourceHacker.exe"
    if (Test-Path $rhExe) {
        Write-Status "Using bundled ResourceHacker" "Success"
        return $rhExe
    }

    # Check if Resource Hacker is already installed on the system
    $searchPaths = @(
        "$env:LOCALAPPDATA\ResourceHacker\ResourceHacker.exe",
        "$env:ProgramFiles\ResourceHacker\ResourceHacker.exe",
        "${env:ProgramFiles(x86)}\ResourceHacker\ResourceHacker.exe",
        "$env:USERPROFILE\Downloads\ResourceHacker\ResourceHacker.exe",
        "$env:USERPROFILE\Desktop\ResourceHacker\ResourceHacker.exe",
        "$env:USERPROFILE\Tools\ResourceHacker\ResourceHacker.exe"
    )
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            Write-Status "Found Resource Hacker: $path" "Success"
            return $path
        }
    }

    # Search all drives for ResourceHacker.exe
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Root
    foreach ($drive in $drives) {
        $found = Get-ChildItem -Path $drive -Filter "ResourceHacker.exe" -Recurse -ErrorAction SilentlyContinue -Depth 4 | Select-Object -First 1
        if ($found) {
            Write-Status "Found Resource Hacker: $($found.FullName)" "Success"
            return $found.FullName
        }
    }

    Write-Status "ResourceHacker.exe not found in tools/ folder or system" "Warning"
    Write-Status "Icon patching will use Win32 API fallback instead" "Info"
    return $null
}

function Patch-MpvIcon {
    param([string]$ExePath, [string]$IcoPath)
    if (!(Test-Path $ExePath) -or !(Test-Path $IcoPath)) { return $false }

    # Phase 1: Fix PE Resource Patching (Alt+Tab Process Icon)
    # Alt+Tab reads the icon directly from the running mpv.exe PE header (ICONGROUP / MAINICON)

    # === Method 1: Resource Hacker (proper ICO -> PE resource parsing) ===
    $rh = Get-ResourceHacker
    if ($rh) {
        try {
            # Backup original
            $bakPath = "$ExePath.bak"
            if (!(Test-Path $bakPath)) {
                Copy-Item -Path $ExePath -Destination $bakPath -Force
            }

            # ResourceHacker CLI: replace ICONGROUP,MAINICON (Ordinal 1)
            # This is the PRIMARY icon group that Windows reads for Alt+Tab
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action addoverwrite -res `"$IcoPath`" -mask ICONGROUP,1,0" -Wait -PassThru -WindowStyle Hidde[...]
            if ($proc.ExitCode -eq 0) {
                # Verify PE resource modification succeeded
                if (Test-PeIconPatched -ExePath $ExePath -IcoPath $IcoPath) {
                    Write-Status "PE resource patched successfully (ICONGROUP,1,0)" "Success"
                    Remove-Item -Path $bakPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
                Write-Status "Resource Hacker succeeded but verification failed, trying alternate mask..." "Warning"
            }

            # Try alternate mask: ICONGROUP,MAINICON,0
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action addoverwrite -res `"$IcoPath`" -mask ICONGROUP,MAINICON,0" -Wait -PassThru -WindowStyl[...]
            if ($proc.ExitCode -eq 0) {
                if (Test-PeIconPatched -ExePath $ExePath -IcoPath $IcoPath) {
                    Write-Status "PE resource patched successfully (ICONGROUP,MAINICON,0)" "Success"
                    Remove-Item -Path $bakPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
            }

            # Try deleting all existing icon groups first, then re-adding
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action delete -mask ICONGROUP,*,0" -Wait -PassThru -WindowStyle Hidden
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action addoverwrite -res `"$IcoPath`" -mask ICONGROUP,1,0" -Wait -PassThru -WindowStyle Hidde[...]
            if ($proc.ExitCode -eq 0) {
                if (Test-PeIconPatched -ExePath $ExePath -IcoPath $IcoPath) {
                    Write-Status "PE resource patched (delete+re-add)" "Success"
                    Remove-Item -Path $bakPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
            }

            # Restore backup on failure
            if (Test-Path $bakPath) {
                Write-Status "All Resource Hacker attempts failed, restoring backup" "Warning"
                Copy-Item -Path $bakPath -Destination $ExePath -Force
                Remove-Item -Path $bakPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            # Restore backup on exception
            if (Test-Path "$ExePath.bak") {
                Copy-Item -Path "$ExePath.bak" -Destination $ExePath -Force
                Remove-Item -Path "$ExePath.bak" -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # === Method 2: Fallback - Win32 API (raw ICO bytes as RT_GROUP_ICON) ===
    Write-Status "Resource Hacker unavailable or failed, using Win32 API fallback..." "Warning"

    # Delete existing icon resources first, then overwrite with new icon
    # This ensures the OLD icon group is completely removed before adding the new one
    $code = @"
using System;
using System.Runtime.InteropServices;
using System.IO;
public class IconPatcher {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern IntPtr BeginUpdateResource(string hFileName, bool bDeleteExistingResources);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cb);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);

    public static int Run(string exe, string ico) {
        byte[] data = File.ReadAllBytes(ico);

        // Step 1: Delete ALL existing icon groups (removes old Alt+Tab icons)
        IntPtr h = BeginUpdateResource(exe, false);
        if (h == IntPtr.Zero) return Marshal.GetLastWin32Error();

        // Delete ordinal 1 (MAINICON)
        UpdateResource(h, (IntPtr)14, (IntPtr)1, 0, null, 0);

        // Delete MAINICON by name
        UpdateResource(h, (IntPtr)14, (IntPtr)14, 0, null, 0);

        // Step 2: Add new icon group
        if (!UpdateResource(h, (IntPtr)14, (IntPtr)1, 0, data, (uint)data.Length)) {
            int e = Marshal.GetLastWin32Error();
            EndUpdateResource(h, true);
            return e;
        }
        if (!EndUpdateResource(h, false)) return Marshal.GetLastWin32Error();
        return 0;
    }
}
"@
    try {
        $uid = [guid]::NewGuid().ToString('N').Substring(0,8)
        $patchedCode = $code -replace 'IconPatcher', "IconPatcher_$uid"
        Add-Type -TypeDefinition $patchedCode -ErrorAction Stop
        $className = ($patchedCode | Select-String 'class (\w+)').Matches[0].Groups[1].Value
        $exeEsc = $ExePath -replace "'", "''"
        $icoEsc = $IcoPath -replace "'", "''"
        $errCode = Invoke-Expression "[$className]::Run('$exeEsc', '$icoEsc')"
        if ($errCode -eq 0) {
            # Verify the patch worked
            if (Test-PeIconPatched -ExePath $ExePath -IcoPath $IcoPath) {
                Write-Status "Win32 API patch verified successfully" "Success"
                return $true
            }
            Write-Status "Win32 API succeeded but verification failed" "Warning"
        } else {
            Write-Status "Win32 API returned error code: $errCode" "Warning"
        }
        return $false
    } catch {
        Write-Status "Win32 API fallback failed: $($_.Exception.Message)" "Warning"
        return $false
    }
}

# Phase 1 helper: Verify that the PE resource was actually patched
function Test-PeIconPatched {
    param([string]$ExePath, [string]$IcoPath)
    if (!(Test-Path $ExePath) -or !(Test-Path $IcoPath)) { return $false }

    try {
        $icoBytes = [System.IO.File]::ReadAllBytes($IcoPath)
        $exeBytes = [System.IO.File]::ReadAllBytes($ExePath)

        # Get first image data from ICO (offset at byte 18, size at byte 14)
        if ($icoBytes.Length -lt 22) { return $false }
        $firstImageOffset = [BitConverter]::ToUInt32($icoBytes, 18)
        $firstImageSize = [BitConverter]::ToUInt32($icoBytes, 14)
        if ($firstImageOffset + $firstImageSize -gt $icoBytes.Length) { return $false }

        $firstImageData = $icoBytes[$firstImageOffset..([Math]::Min($firstImageOffset + 99, $icoBytes.Length - 1))]

        # Search for this icon data in the EXE
        for ($i = 0; $i -lt $exeBytes.Length - $firstImageData.Length; $i++) {
            $match = $true
            for ($j = 0; $j -lt $firstImageData.Length; $j++) {
                if ($exeBytes[$i + $j] -ne $firstImageData[$j]) {
                    $match = $false
                    break
                }
            }
            if ($match) { return $true }
        }
    } catch {}
    return $false
}

# Phase 2 helper: Clean stale MuiCache entries that map mpv.exe to old application name/icon
function Clean-StaleMuiCache {
    $muiPaths = @(
        "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache",
        "HKLM:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
    )

    foreach ($muiPath in $muiPaths) {
        if (!(Test-Path $muiPath)) { continue }

        try {
            $props = Get-ItemProperty -Path $muiPath -ErrorAction SilentlyContinue
            if ($props) {
                $mpvProps = $props.PSObject.Properties | Where-Object {
                    $_.Name -like "*mpv*" -or $_.Name -like "*MPV*" -or $_.Name -like "*mpv-player*"
                }
                foreach ($prop in $mpvProps) {
                    try {
                        Remove-ItemProperty -Path $muiPath -Name $prop.Name -ErrorAction SilentlyContinue
                        Write-Status "Removed stale MuiCache: $($prop.Name)" "Info"
                    } catch {}
                }
            }
        } catch {}
    }

    # Also clean UserAssist entries that may cache old icons
    $userAssistPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist"
    if (Test-Path $userAssistPath) {
        Get-ChildItem -Path $userAssistPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                if ($props) {
                    $mpvProps = $props.PSObject.Properties | Where-Object {
                        $_.Name -like "*mpv*" -or $_.Name -like "*RMN*"
                    }
                    foreach ($prop in $mpvProps) {
                        Remove-ItemProperty -Path $_.PSPath -Name $prop.Name -ErrorAction SilentlyContinue
                    }
                }
            } catch {}
        }
    }

    Write-Status "MuiCache cleanup complete" "Success"
}

# Phase 3 helper: Comprehensive icon & shell cache purge
function Purge-IconCache {
    try {
        # Step 1: Stop Explorer so cache files aren't locked
        Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        # Step 2: Delete ALL Explorer icon/thumb cache databases
        $explorerCacheDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
        if (Test-Path $explorerCacheDir) {
            # Delete iconcache*.db
            Get-ChildItem -Path $explorerCacheDir -Filter "iconcache*.db" -File -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Status "Deleted: $($_.Name)" "Info"
            }
            # Delete thumbcache*.db
            Get-ChildItem -Path $explorerCacheDir -Filter "thumbcache*.db" -File -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Status "Deleted: $($_.Name)" "Info"
            }
        }

        # Step 3: Delete root IconCache.db (Windows 10/11 may store it here)
        $rootIconCache = "$env:LOCALAPPDATA\IconCache.db"
        if (Test-Path $rootIconCache) {
            Remove-Item -Path $rootIconCache -Force -ErrorAction SilentlyContinue
            Write-Status "Deleted root IconCache.db" "Info"
        }

        # Step 4: Notify Windows Shell via SHChangeNotify (SHCNE_ASSOCCHANGED)
        # This forces Windows to reload all file associations and icons
        $shellCode = @"
using System;
using System.Runtime.InteropServices;
public class Shell32Notify {
    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
}
"@
        try {
            Add-Type -TypeDefinition $shellCode -ErrorAction SilentlyContinue
            # SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0x1000
            [Shell32Notify]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
            Write-Status "SHChangeNotify(SHCNE_ASSOCCHANGED) sent" "Success"
        } catch {
            Write-Status "SHChangeNotify failed (non-critical): $($_.Exception.Message)" "Warning"
        }

        # Step 5: Flush shell icons via ie4uinit (Windows shell icon refresh utility)
        if (Get-Command "ie4uinit.exe" -ErrorAction SilentlyContinue) {
            Start-Process "ie4uinit.exe" -ArgumentList "-show" -Wait -ErrorAction SilentlyContinue
            Write-Status "ie4uinit -show executed" "Info"
        }

        # Step 6: Restart Explorer
        Start-Process "explorer.exe"
        Start-Sleep -Seconds 2
        Write-Status "Icon cache deep purge complete" "Success"
    } catch {
        # Fallback: just restart Explorer
        Start-Process "explorer.exe" -ErrorAction SilentlyContinue
        Write-Status "Icon cache purge (basic fallback)" "Info"
    }
}

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

# === MAIN INSTALLATION FLOW ===
# [Remaining code continues from original file...]
