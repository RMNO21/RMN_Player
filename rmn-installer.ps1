<#
.SYNOPSIS
    MPV Player Installer with custom configuration
.DESCRIPTION
    Complete MPV installer with shortcuts, file associations, and configs.
.NOTES
    Run as Administrator for full functionality
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
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action addoverwrite -res `"$IcoPath`" -mask ICONGROUP,1,0" -Wait -PassThru -WindowStyle Hidden
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
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action addoverwrite -res `"$IcoPath`" -mask ICONGROUP,MAINICON,0" -Wait -PassThru -WindowStyle Hidden
            if ($proc.ExitCode -eq 0) {
                if (Test-PeIconPatched -ExePath $ExePath -IcoPath $IcoPath) {
                    Write-Status "PE resource patched successfully (ICONGROUP,MAINICON,0)" "Success"
                    Remove-Item -Path $bakPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
            }

            # Try deleting all existing icon groups first, then re-adding
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action delete -mask ICONGROUP,*,0" -Wait -PassThru -WindowStyle Hidden
            $proc = Start-Process -FilePath $rh -ArgumentList "-open `"$ExePath`" -save `"$ExePath`" -action addoverwrite -res `"$IcoPath`" -mask ICONGROUP,1,0" -Wait -PassThru -WindowStyle Hidden
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

function Find-MpvOnSystem {
    # Phase 4: System Search Neutralization
    # Ensure the installer strictly prioritizes and executes $InstallDir\mpv.exe

    # PRIORITY 1: Always use the patched mpv.exe from InstallDir first
    if (Test-Path "$InstallDir\mpv.exe") {
        Write-Status "Using patched mpv.exe from InstallDir (priority)" "Success"
        return "$InstallDir\mpv.exe"
    }

    # PRIORITY 2: Bundled mpv in installer folder (works on fresh Windows with no internet)
    $bundledMpv = Join-Path $ScriptDir "mpv\mpv.exe"
    if (Test-Path $bundledMpv) {
        Write-Status "Using bundled mpv.exe (will be patched during install)" "Info"
        return $bundledMpv
    }

    # PRIORITY 3: Search other locations (these will be COPIED and PATCHED)
    # Log any secondary mpv.exe files found - they should NOT be used directly
    $searchPaths = @(
        "$env:USERPROFILE\mpv-player-fresh\mpv.exe",
        "$env:LOCALAPPDATA\Programs\mpv\mpv.exe",
        "C:\mpv\mpv.exe",
        "C:\Program Files\mpv\mpv.exe",
        "$env:USERPROFILE\mpv-player-new\mpv.exe",
        "$env:USERPROFILE\Desktop\safe backup\Local-mpv-player\mpv.exe",
        "$env:USERPROFILE\Documents\Cinex-Player\bin\mpv.exe"
    )

    $foundPaths = @()
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            $foundPaths += $path
            Write-Status "Found secondary mpv.exe: $path (will be copied & patched)" "Info"
        }
    }

    # Search winget packages folder
    $wingetPackages = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*mpv*" }
    foreach ($pkg in $wingetPackages) {
        $mpvExe = Join-Path $pkg.FullName "mpv.exe"
        if (Test-Path $mpvExe) {
            $foundPaths += $mpvExe
            Write-Status "Found secondary mpv.exe: $mpvExe (will be copied & patched)" "Info"
        }
    }

    # Search all drives for additional copies
    $drives = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Root
    foreach ($drive in $drives) {
        foreach ($folder in @("mpv", "mpv-player", "mpv-player-fresh", "mpv-player-windows")) {
            $path = Join-Path $drive $folder
            if (Test-Path "$path\mpv.exe") {
                $foundPaths += "$path\mpv.exe"
                Write-Status "Found secondary mpv.exe: $path\mpv.exe (will be copied & patched)" "Info"
            }
        }
    }

    # Return the first found path (will be copied to InstallDir and patched)
    if ($foundPaths.Count -gt 0) {
        if ($foundPaths.Count -gt 1) {
            Write-Status "WARNING: Found $($foundPaths.Count) mpv.exe copies on system" "Warning"
            Write-Status "Only the patched copy in $InstallDir will be used for file associations" "Warning"
        }
        return $foundPaths[0]
    }

    return $null
}

function Install-MpvViaWinget {
    Write-Status "Trying winget to install mpv..." "Info"
    try {
        # Ensure winget sources are up to date first (suppress all output)
        $null = winget source update 2>$null
        $null = winget install --id mpv.mpv -e --accept-source-agreements --accept-package-agreements 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Status "winget install failed (exit code: $LASTEXITCODE)" "Warning"
            return $null
        }
        # Check if winget installed it
        $wingetPath = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\mpv.mpv*\mpv.exe"
        $found = Get-Item -Path $wingetPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
        # Also check common winget locations
        $altPaths = @(
            "$env:LOCALAPPDATA\Programs\mpv\mpv.exe",
            "C:\Users\Public\mpv\mpv.exe"
        )
        foreach ($p in $altPaths) {
            if (Test-Path $p) { return $p }
        }
    } catch {
        Write-Status "winget install failed: $($_.Exception.Message)" "Warning"
    }
    return $null
}

function Download-Mpv-WithCurl {
    param([string]$Url, [string]$OutFile)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        Write-Status "curl.exe not found" "Warning"
        return $false
    }
    try {
        # -L follow redirects, -k ignore cert errors, --ssl-no-revoke skip revocation
        # --retry 3 for transient failures, -w show HTTP status code
        $curlOutput = & curl.exe -L --retry 3 --retry-delay 2 -o $OutFile $Url --connect-timeout 30 --max-time 600 --ssl-no-revoke -k -w "`nHTTP_CODE:%{http_code}" 2>&1
        $exitCode = $LASTEXITCODE
        # Extract HTTP status code from curl output
        $httpCode = ($curlOutput | Where-Object { $_ -match "^HTTP_CODE:" }) -replace "^HTTP_CODE:", ""
        if ($exitCode -eq 0 -and (Test-Path $OutFile)) {
            $size = (Get-Item $OutFile).Length
            if ($size -gt 10MB) { return $true }
            Write-Status "curl downloaded file too small ($size bytes, HTTP $httpCode)" "Warning"
            Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
        } else {
            Write-Status "curl failed (exit: $exitCode, HTTP: $httpCode)" "Warning"
        }
    } catch {
        Write-Status "curl exception: $($_.Exception.Message)" "Warning"
    }
    return $false
}

function Get-MpvDownloadUrl {
    # Try curl for API calls first (bypasses Windows Schannel revocation issues)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue

    # Helper: parse GitHub release JSON and extract mpv-x86_64 .7z URL
    function Parse-GitHubRelease {
        param([string]$JsonFile, [string]$Source)
        try {
            if (!(Test-Path $JsonFile)) { return $null }
            $raw = Get-Content $JsonFile -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            $release = $raw | ConvertFrom-Json -ErrorAction Stop
            $asset = $release.assets | Where-Object { $_.name -match "mpv-x86_64-.*\.7z$" -and $_.name -notmatch "v3" } | Select-Object -First 1
            if ($asset) {
                Write-Status "Found latest build: $($asset.name)" "Info"
                return $asset.browser_download_url
            }
        } catch {
            Write-Status "Parse error for $Source release: $($_.Exception.Message)" "Warning"
        }
        return $null
    }

    # Try shinchiro builds
    $shinchiroApi = "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest"
    $jsonFile = "$env:TEMP\mpv-download\release-shinchiro.json"
    New-Item -ItemType Directory -Path (Split-Path $jsonFile) -Force | Out-Null

    if ($curl) {
        try {
            & curl.exe -s -k --ssl-no-revoke --connect-timeout 15 --max-time 30 $shinchiroApi -o $jsonFile 2>$null
            $result = Parse-GitHubRelease -JsonFile $jsonFile -Source "shinchiro"
            if ($result) { return $result }
        } catch {}
    }
    # Fallback: use Invoke-WebRequest for API call
    try {
        Invoke-WebRequest -Uri $shinchiroApi -OutFile $jsonFile -UseBasicParsing -TimeoutSec 30
        $result = Parse-GitHubRelease -JsonFile $jsonFile -Source "shinchiro"
        if ($result) { return $result }
    } catch {
        Write-Status "Could not query shinchiro API via web request" "Warning"
    }

    # Try zhongfly builds
    $zhongflyApi = "https://api.github.com/repos/zhongfly/mpv-winbuild/releases/latest"
    $jsonFile = "$env:TEMP\mpv-download\release-zhongfly.json"

    if ($curl) {
        try {
            & curl.exe -s -k --ssl-no-revoke --connect-timeout 15 --max-time 30 $zhongflyApi -o $jsonFile 2>$null
            $result = Parse-GitHubRelease -JsonFile $jsonFile -Source "zhongfly"
            if ($result) { return $result }
        } catch {}
    }
    try {
        Invoke-WebRequest -Uri $zhongflyApi -OutFile $jsonFile -UseBasicParsing -TimeoutSec 30
        $result = Parse-GitHubRelease -JsonFile $jsonFile -Source "zhongfly"
        if ($result) { return $result }
    } catch {
        Write-Status "Could not query zhongfly API via web request" "Warning"
    }

    return $null
}

function Download-Mpv {
    Write-Status "Downloading mpv..." "Info"
    $tempDir = "$env:TEMP\mpv-download"
    $tempFile = "$tempDir\mpv.7z"

    if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # Step 1: Try to get latest release URL via GitHub API
    $latestUrl = Get-MpvDownloadUrl

    # Step 2: Build download list (latest API + hardcoded fallbacks)
    $downloads = @()
    if ($latestUrl) {
        $downloads += @{ Url = $latestUrl; Hash = "" }
    }
    # Hardcoded fallbacks from official mpv.io sources (shinchiro + zhongfly)
    $downloads += @(
        @{ Url = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260610/mpv-x86_64-20260610-git-304426c.7z"; Hash = "" },
        @{ Url = "https://github.com/zhongfly/mpv-winbuild/releases/latest/download/mpv-x86_64-20260610-git-304426c.7z"; Hash = "" }
    )

    # Step 3: Try each source with retries
    foreach ($dl in $downloads) {
        Write-Status "Trying: $($dl.Url)" "Info"
        $maxRetries = 2
        for ($retry = 0; $retry -le $maxRetries; $retry++) {
            if ($retry -gt 0) {
                Write-Status "Retry $retry..." "Info"
                Start-Sleep -Seconds 5
            }

            if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force }

            # Method 1: Try curl.exe (most reliable - handles Schannel/TLS independently)
            if (Download-Mpv-WithCurl -Url $dl.Url -OutFile $tempFile) {
                Write-Status "Downloaded ($([math]::Round((Get-Item $tempFile).Length/1MB, 1)) MB)" "Success"
                return $tempFile
            }

            # Method 2: Try .NET WebClient (simpler TLS handling)
            try {
                $webClient = New-Object System.Net.WebClient
                $webClient.Headers.Add("User-Agent", "Mozilla/5.0")
                $webClient.DownloadFile($dl.Url, $tempFile)
                if (Test-Path $tempFile) {
                    $size = (Get-Item $tempFile).Length
                    if ($size -gt 10MB) {
                        Write-Status "Downloaded via WebClient ($([math]::Round($size/1MB, 1)) MB)" "Success"
                        return $tempFile
                    }
                    Remove-Item -Path $tempFile -Force
                }
            } catch {
                $errMsg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                Write-Status "WebClient failed: $errMsg" "Warning"
                if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force }
            }

            # Method 3: Fallback to Invoke-WebRequest
            try {
                $progressPreferenceBak = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $dl.Url -OutFile $tempFile -UseBasicParsing -TimeoutSec 300
                $ProgressPreference = $progressPreferenceBak
                if (Test-Path $tempFile) {
                    $size = (Get-Item $tempFile).Length
                    if ($size -gt 10MB) {
                        if ($dl.Hash -and $dl.Hash -ne "") {
                            $fileHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
                            if ($fileHash -ne $dl.Hash) {
                                Write-Status "Hash mismatch! Expected: $($dl.Hash) Got: $fileHash" "Warning"
                                Remove-Item -Path $tempFile -Force
                                continue
                            }
                            Write-Status "Hash verified" "Success"
                        } else {
                            Write-Status "Downloaded via Invoke-WebRequest ($([math]::Round($size/1MB, 1)) MB)" "Success"
                        }
                        return $tempFile
                    } else {
                        Write-Status "File too small ($size bytes), skipping" "Warning"
                        Remove-Item -Path $tempFile -Force
                    }
                }
            } catch {
                $ProgressPreference = $progressPreferenceBak
                Write-Status "Invoke-WebRequest failed: $($_.Exception.Message)" "Warning"
                if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force }
            }
        }
    }

    return $null
}

function Copy-MpvFromExisting {
    param([string]$SourcePath)
    Write-Status "Copying MPV from: $SourcePath" "Info"
    $sourceDir = Split-Path -Parent $SourcePath
    if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path "$sourceDir\*" -Destination $InstallDir -Recurse -Force

    # Remove portable_config from source - it may contain incompatible options
    # from other MPV installations (e.g. Cinex-Player). Our own config goes to $ConfigDir.
    $portableConfig = Join-Path $InstallDir "portable_config"
    if (Test-Path $portableConfig) {
        Remove-Item -Path $portableConfig -Recurse -Force
        Write-Status "Removed source portable_config (incompatible options avoided)" "Info"
    }

    Write-Status "MPV copied to: $InstallDir" "Success"
}

function Install-Icon {
    Write-Status "Installing app icon..." "Info"
    $iconSource = "$PackageConfigDir\rmn-icon.ico"
    $iconDest = "$InstallDir\rmn-icon.ico"

    if (Test-Path $iconSource) {
        if (!(Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        Copy-Item -Path $iconSource -Destination $iconDest -Force
        Write-Status "Icon file installed: $iconDest" "Success"
    } else {
        Write-Status "rmn-icon.ico not found in config folder" "Warning"
        return
    }

    # Patch mpv.exe with custom icon (updates Alt+Tab icon)
    $mpvExe = "$InstallDir\mpv.exe"
    if (Test-Path $mpvExe) {
        Write-Status "Patching mpv.exe icon..." "Info"
        $patched = Patch-MpvIcon -ExePath $mpvExe -IcoPath $iconSource
        if ($patched) {
            Write-Status "mpv.exe icon patched successfully" "Success"
        } else {
            Write-Status "Failed to patch mpv.exe icon - Alt+Tab may still show old icon" "Warning"
        }
    }

    # Phase 2: Registry & ProgId Cleanup
    # Set the default icon for the custom ProgId strictly to the patched binary
    Write-Status "Setting file association icons (Phase 2)..." "Info"
    $patchedExeIcon = "`"$InstallDir\mpv.exe`",0"
    $iconFileIcon = "`"$iconDest`",0"

    # === LAYER 1: Set DefaultIcon to PATCHED BINARY (not .ico file) ===
    # This ensures Alt+Tab reads from the patched EXE, not a cached .ico
    Write-Status "Setting DefaultIcon to patched mpv.exe binary..." "Info"

    # Primary: RMN-Player ProgId points to patched EXE
    $rmnProgId = "HKCU:\Software\Classes\RMN-Player"
    if (!(Test-Path "$rmnProgId\DefaultIcon")) { New-Item -Path "$rmnProgId\DefaultIcon" -Force | Out-Null }
    Set-ItemProperty -Path "$rmnProgId\DefaultIcon" -Name "(Default)" -Value $patchedExeIcon

    # Also set RMN-Player Applications key
    $rmnApps = "HKCU:\Software\Classes\Applications\RMN-Player.exe\DefaultIcon"
    if (!(Test-Path $rmnApps)) { New-Item -Path $rmnApps -Force | Out-Null }
    Set-ItemProperty -Path $rmnApps -Name "(Default)" -Value $patchedExeIcon

    # Also set mpv.exe Applications key to point to patched binary
    $mpvApps = "HKCU:\Software\Classes\Applications\mpv.exe\DefaultIcon"
    if (!(Test-Path $mpvApps)) { New-Item -Path $mpvApps -Force | Out-Null }
    Set-ItemProperty -Path $mpvApps -Name "(Default)" -Value $patchedExeIcon

    # Generic mpv ProgId (override any stale entries)
    $mpvProgId = "HKCU:\Software\Classes\mpv\DefaultIcon"
    if (Test-Path $mpvProgId) {
        Set-ItemProperty -Path $mpvProgId -Name "(Default)" -Value $patchedExeIcon
    }

    # === LAYER 2: Per-extension SystemFileAssociations ===
    # Ensure all file extensions map to RMN-Player ProgId, not generic mpv
    $videoExts = @(".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".mpg", ".mpeg", ".ts", ".m2ts")
    $audioExts = @(".mp3", ".flac", ".wav", ".aac", ".ogg", ".opus", ".wma", ".m4a")

    foreach ($ext in ($videoExts + $audioExts)) {
        # RMN-Player extension-specific ProgId
        $rmnExtKey = "HKCU:\Software\Classes\RMN-Player$ext"
        if (!(Test-Path "$rmnExtKey\DefaultIcon")) { New-Item -Path "$rmnExtKey\DefaultIcon" -Force | Out-Null }
        Set-ItemProperty -Path "$rmnExtKey\DefaultIcon" -Name "(Default)" -Value $patchedExeIcon -ErrorAction SilentlyContinue

        # SystemFileAssociations
        $sfaKey = "HKCU:\Software\Classes\SystemFileAssociations\$ext\DefaultIcon"
        if (!(Test-Path $sfaKey)) { New-Item -Path $sfaKey -Force | Out-Null }
        Set-ItemProperty -Path $sfaKey -Name "(Default)" -Value $patchedExeIcon -ErrorAction SilentlyContinue

        # Direct extension key
        $extKey = "HKCU:\Software\Classes\$ext\DefaultIcon"
        if (!(Test-Path $extKey)) { New-Item -Path $extKey -Force | Out-Null }
        Set-ItemProperty -Path $extKey -Name "(Default)" -Value $patchedExeIcon -ErrorAction SilentlyContinue
    }
    Write-Status "DefaultIcon registry entries updated (patched EXE)" "Success"

    # === LAYER 3: Clean stale MuiCache entries ===
    # Windows caches application names/icons in MuiCache; stale entries cause old icons
    Write-Status "Cleaning stale MuiCache entries..." "Info"
    Clean-StaleMuiCache

    # === LAYER 4: Deep icon cache purge ===
    Write-Status "Performing deep icon cache purge (Phase 3)..." "Info"
    Purge-IconCache
}

function Register-Mpv {
    Write-Status "Registering RMN-Player in Windows..." "Info"

    # Phase 4: Ensure we ONLY use the patched mpv.exe from InstallDir
    $mpvPath = "$InstallDir\mpv.exe"
    $iconPath = "$InstallDir\rmn-icon.ico"
    $isAdmin = Test-AdminPrivileges

    # Verify the patched EXE exists before registering
    if (!(Test-Path $mpvPath)) {
        Write-Status "CRITICAL: Patched mpv.exe not found at $mpvPath" "Error"
        return
    }

    # Use HKCU for non-admin, HKLM for admin
    $root = if ($isAdmin) { "HKLM:\SOFTWARE" } else { "HKCU:\SOFTWARE" }

    try {
        # Register in App Paths (so "mpv" is findable)
        $appPathsKey = "$root\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe"
        New-Item -Path $appPathsKey -Force | Out-Null
        Set-ItemProperty -Path $appPathsKey -Name "(Default)" -Value $mpvPath
        Set-ItemProperty -Path $appPathsKey -Name "UseUrl" -Value 1 -Type DWord

        # Also register RMN-Player.exe in App Paths (so "RMN-Player" is findable)
        $rmnAppPathsKey = "$root\Microsoft\Windows\CurrentVersion\App Paths\RMN-Player.exe"
        New-Item -Path $rmnAppPathsKey -Force | Out-Null
        Set-ItemProperty -Path $rmnAppPathsKey -Name "(Default)" -Value $mpvPath
        Set-ItemProperty -Path $rmnAppPathsKey -Name "UseUrl" -Value 1 -Type DWord
    } catch {
        Write-Status "Could not register App Paths" "Warning"
    }

    try {
        # Register as mpv.exe in Applications (Windows uses this to find the executable)
        $classesRoot = "$root\Classes"

        # === RMN-Player.exe Applications entry ===
        $rmnAppKey = "$classesRoot\Applications\RMN-Player.exe"
        New-Item -Path $rmnAppKey -Force | Out-Null
        Set-ItemProperty -Path $rmnAppKey -Name "FriendlyAppName" -Value "RMN-Player"
        if (Test-Path $iconPath) {
            Set-ItemProperty -Path $rmnAppKey -Name "DefaultIcon" -Value "`"$iconPath`""
            $defaultIconKey = "$rmnAppKey\DefaultIcon"
            if (!(Test-Path $defaultIconKey)) { New-Item -Path $defaultIconKey -Force | Out-Null }
            Set-ItemProperty -Path $defaultIconKey -Name "(Default)" -Value "`"$mpvPath`",0"
        }
        $rmnShellKey = "$rmnAppKey\shell"
        New-Item -Path "$rmnShellKey\open\command" -Force | Out-Null
        Set-ItemProperty -Path $rmnShellKey -Name "(Default)" -Value "open"
        Set-ItemProperty -Path "$rmnShellKey\open\command" -Name "(Default)" -Value "`"$mpvPath`" `"%1`""

        # === mpv.exe Applications entry (override to point to patched binary) ===
        $appKey = "$classesRoot\Applications\mpv.exe"
        New-Item -Path $appKey -Force | Out-Null
        Set-ItemProperty -Path $appKey -Name "FriendlyAppName" -Value "RMN-Player"
        if (Test-Path $iconPath) {
            Set-ItemProperty -Path $appKey -Name "DefaultIcon" -Value "`"$iconPath`""
            $defaultIconKey = "$appKey\DefaultIcon"
            if (!(Test-Path $defaultIconKey)) { New-Item -Path $defaultIconKey -Force | Out-Null }
            # Phase 2: Set DefaultIcon to PATCHED BINARY, not .ico file
            Set-ItemProperty -Path $defaultIconKey -Name "(Default)" -Value "`"$mpvPath`",0"
        }
        $shellKey = "$appKey\shell"
        New-Item -Path "$shellKey\open\command" -Force | Out-Null
        Set-ItemProperty -Path $shellKey -Name "(Default)" -Value "open"
        Set-ItemProperty -Path "$shellKey\open\command" -Name "(Default)" -Value "`"$mpvPath`" `"%1`""

        # Register in Open With for video and audio file types
        $videoTypes = @("mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "ts", "m2ts")
        $audioTypes = @("mp3", "flac", "wav", "aac", "ogg", "opus", "wma", "m4a")

        foreach ($ext in ($videoTypes + $audioTypes)) {
            $extClasses = "$classesRoot\$ext"
            if (!(Test-Path $extClasses)) { New-Item -Path $extClasses -Force | Out-Null }

            # Phase 4: Ensure OpenWithProgids maps to RMN-Player, not generic mpv
            $owaProgIds = "$extClasses\OpenWithProgids"
            if (!(Test-Path $owaProgIds)) { New-Item -Path $owaProgIds -Force | Out-Null }
            Set-ItemProperty -Path $owaProgIds -Name "RMN-Player$ext" -Value "" -ErrorAction SilentlyContinue

            # OpenWithList
            $owaList = "$extClasses\OpenWithList"
            if (!(Test-Path $owaList)) { New-Item -Path $owaList -Force | Out-Null }
            Set-ItemProperty -Path $owaList -Name "RMN-Player.exe" -Value "" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $owaList -Name "mpv.exe" -Value "" -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Status "Could not register Applications" "Warning"
    }

    # Register Capabilities for Default Programs (both admin and user level)
    try {
        $capKey = "$root\Clients\Media\RMN-Player\Capabilities"
        New-Item -Path $capKey -Force | Out-Null
        Set-ItemProperty -Path $capKey -Name "ApplicationName" -Value "RMN-Player"
        Set-ItemProperty -Path $capKey -Name "ApplicationDescription" -Value "RMN-Player media player"
        Set-ItemProperty -Path $capKey -Name "ApplicationIcon" -Value "`"$mpvPath`""
        Set-ItemProperty -Path $capKey -Name "ApplicationVersion" -Value "1.0.0"
        Set-ItemProperty -Path $capKey -Name "Publisher" -Value "RMN-Player"

        $videoExts = @(".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".mpg", ".mpeg", ".ts", ".m2ts")
        $audioExts = @(".mp3", ".flac", ".wav", ".aac", ".ogg", ".opus", ".wma", ".m4a")
        $fileAssoc = @{}
        foreach ($ext in ($videoExts + $audioExts)) { $fileAssoc[$ext] = "RMN-Player$ext" }
        Set-ItemProperty -Path $capKey -Name "FileAssociations" -Value $fileAssoc

        $regApps = "$root\RegisteredApplications"
        if (!(Test-Path $regApps)) { New-Item -Path $regApps -Force | Out-Null }
        $capPath = "SOFTWARE\Clients\Media\RMN-Player\Capabilities"
        Set-ItemProperty -Path $regApps -Name "RMN-Player" -Value $capPath
        Write-Status "Registered in Default Programs" "Success"
    } catch {
        Write-Status "Could not register in Default Programs" "Warning"
    }

    Write-Status "RMN-Player registered (file associations point to patched EXE)" "Success"
}

function Register-Uninstall {
    Write-Status "Creating uninstall entry..." "Info"

    $mpvPath = "$InstallDir\mpv.exe"
    $iconPath = "$InstallDir\rmn-icon.ico"
    $isAdmin = Test-AdminPrivileges

    # Copy standalone uninstall script
    $uninstallScriptPath = "$InstallDir\uninstall.ps1"
    $sourceUninstall = Join-Path $ScriptDir "uninstall.ps1"
    try {
        if (Test-Path $sourceUninstall) {
            Copy-Item -Path $sourceUninstall -Destination $uninstallScriptPath -Force
        } else {
            Write-Status "uninstall.ps1 not found in project folder" "Warning"
        }
        $uninstallCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$uninstallScriptPath`""
    } catch {
        $uninstallCmd = "powershell.exe -ExecutionPolicy Bypass -Command `"Remove-Item -Path '$InstallDir' -Recurse -Force; Remove-Item -Path '$ConfigDir' -Recurse -Force`""
    }

    $uninstallKey = if ($isAdmin) { "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RMN-Player" } else { "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RMN-Player" }

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

function Create-Shortcuts {
    Write-Status "Creating shortcuts..." "Info"

    $mpvPath = "$InstallDir\mpv.exe"
    $iconPath = "$InstallDir\rmn-icon.ico"
    $mpvArgs = ""

    # Desktop shortcut
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $shell = New-Object -COM WScript.Shell
    $shortcut = $shell.CreateShortcut("$desktopPath\RMN-Player.lnk")
    $shortcut.TargetPath = $mpvPath
    $shortcut.Arguments = $mpvArgs
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Description = "RMN-Player Media Player"
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Save()
    Write-Status "Desktop shortcut created" "Success"

    # Start Menu folder and shortcuts (user level)
    $startMenuPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\RMN-Player"
    if (!(Test-Path $startMenuPath)) { New-Item -ItemType Directory -Path $startMenuPath -Force | Out-Null }

    # App shortcut in Start Menu folder
    $shortcut = $shell.CreateShortcut("$startMenuPath\RMN-Player.lnk")
    $shortcut.TargetPath = $mpvPath
    $shortcut.Arguments = $mpvArgs
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Description = "RMN-Player Media Player"
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Save()
    Write-Status "Start Menu shortcut created" "Success"

    # Uninstall shortcut in Start Menu folder
    $uninstallScriptPath = "$InstallDir\uninstall.ps1"
    if (Test-Path $uninstallScriptPath) {
        $shortcut = $shell.CreateShortcut("$startMenuPath\Uninstall RMN-Player.lnk")
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$uninstallScriptPath`""
        $shortcut.Description = "Uninstall RMN-Player"
        $shortcut.Save()
        Write-Status "Uninstall shortcut created" "Success"
    }
}

function Add-ToPath {
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$InstallDir*") {
        Write-Status "Adding MPV to PATH..." "Info"
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$InstallDir", "User")
        $env:Path = "$env:Path;$InstallDir"
        Write-Status "MPV added to PATH" "Success"
    }
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

    # Remove any portable_config that mpv may have created in the install dir
    $portableConfig = Join-Path $InstallDir "portable_config"
    if (Test-Path $portableConfig) {
        Remove-Item -Path $portableConfig -Recurse -Force
        Write-Status "Removed portable_config (MPV_HOME takes precedence)" "Info"
    }
}

function Set-FileAssociations {
    Write-Status "Setting up file associations..." "Info"

    # Phase 4: Ensure we ONLY use the patched mpv.exe from InstallDir
    $mpvPath = "$InstallDir\mpv.exe"
    $iconPath = "$InstallDir\rmn-icon.ico"

    # Verify the patched EXE exists
    if (!(Test-Path $mpvPath)) {
        Write-Status "CRITICAL: Patched mpv.exe not found at $mpvPath" "Error"
        return
    }

    $extensions = @(
        ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v",
        ".mpg", ".mpeg", ".ts", ".m2ts", ".vob", ".ogv", ".3gp", ".3g2",
        ".divx", ".f4v", ".rm", ".rmvb", ".mp3", ".flac", ".wav", ".aac",
        ".ogg", ".opus", ".wma", ".m4a"
    )

    # Phase 2: Register RMN-Player ProgId (needed for Open With dialog and default prompts)
    $progIdRoot = "Registry::HKEY_CURRENT_USER\Software\Classes\RMN-Player"
    try {
        if (!(Test-Path $progIdRoot)) { New-Item -Path $progIdRoot -Force | Out-Null }
        Set-ItemProperty -Path $progIdRoot -Name "(Default)" -Value "RMN-Player Media File"
        Set-ItemProperty -Path $progIdRoot -Name "FriendlyAppName" -Value "RMN-Player"

        # Phase 2: Set DefaultIcon to PATCHED BINARY (not .ico file)
        # This ensures Alt+Tab reads from the patched EXE
        Set-ItemProperty -Path $progIdRoot -Name "DefaultIcon" -Value "`"$mpvPath`""

        $shellKey = "$progIdRoot\shell\open\command"
        if (!(Test-Path $shellKey)) { New-Item -Path $shellKey -Force | Out-Null }
        Set-ItemProperty -Path $shellKey -Name "(Default)" -Value "`"$mpvPath`" `"%1`""
    } catch {
        Write-Status "Could not register ProgId" "Warning"
    }

    foreach ($ext in $extensions) {
        $extProgId = "RMN-Player$ext"
        try {
            # Create extension-specific ProgId with shell\open\command
            $extKey = "Registry::HKEY_CURRENT_USER\Software\Classes\$extProgId"
            if (!(Test-Path $extKey)) { New-Item -Path $extKey -Force | Out-Null }
            Set-ItemProperty -Path $extKey -Name "(Default)" -Value "RMN-Player Media File"

            # Phase 2: Set DefaultIcon to PATCHED BINARY
            Set-ItemProperty -Path $extKey -Name "DefaultIcon" -Value "`"$mpvPath`""

            $extShell = "$extKey\shell\open\command"
            if (!(Test-Path $extShell)) { New-Item -Path $extShell -Force | Out-Null }
            Set-ItemProperty -Path $extShell -Name "(Default)" -Value "`"$mpvPath`" `"%1`""

            # Add to OpenWithProgids so it appears in Open With menu
            $openWith = "Registry::HKEY_CURRENT_USER\Software\Classes\$ext\OpenWithProgids"
            if (!(Test-Path $openWith)) { New-Item -Path $openWith -Force | Out-Null }
            Set-ItemProperty -Path $openWith -Name $extProgId -Value ""

            # Phase 4: Register in OpenWithList (point to patched EXE)
            $openWithList = "Registry::HKEY_CURRENT_USER\Software\Classes\$ext\OpenWithList"
            if (!(Test-Path $openWithList)) { New-Item -Path $openWithList -Force | Out-Null }
            Set-ItemProperty -Path $openWithList -Name "RMN-Player.exe" -Value ""
            Set-ItemProperty -Path $openWithList -Name "mpv.exe" -Value ""
        } catch {}
    }
    Write-Status "File associations configured (RMN-Player in Open With)" "Success"
}

function Install-ConfigFiles {
    Write-Status "Installing configuration files..." "Config"
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts\uosc" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts\uosc\elements" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\scripts\uosc\lib" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\script-opts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\fonts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ConfigDir\watch_later" -Force | Out-Null

    if (Test-Path $PackageConfigDir) {
        Copy-Item -Path "$PackageConfigDir\player.conf" -Destination $ConfigDir -Force
        Copy-Item -Path "$PackageConfigDir\input.conf" -Destination $ConfigDir -Force
        # Copy episode-tracker data if it exists
        if (Test-Path "$PackageConfigDir\episode-tracker.json") {
            Copy-Item -Path "$PackageConfigDir\episode-tracker.json" -Destination $ConfigDir -Force
        }
        if (Test-Path "$PackageConfigDir\script-opts") {
            Copy-Item -Path "$PackageConfigDir\script-opts\*" -Destination "$ConfigDir\script-opts" -Force
        }
        if (Test-Path "$PackageConfigDir\fonts") {
            Copy-Item -Path "$PackageConfigDir\fonts\*" -Destination "$ConfigDir\fonts" -Force
        }
        if (Test-Path "$PackageConfigDir\scripts") {
            Copy-Item -Path "$PackageConfigDir\scripts\*.lua" -Destination "$ConfigDir\scripts" -Force
            if (Test-Path "$PackageConfigDir\scripts\uosc") {
                Copy-Item -Path "$PackageConfigDir\scripts\uosc\*" -Destination "$ConfigDir\scripts\uosc" -Force -Recurse
            }
        }
        Write-Status "Configuration files installed" "Success"
    }
    
    Fix-ThumbfastConfig
}

function Fix-ThumbfastConfig {
    Write-Status "Configuring thumbfast thumbnail preview..." "Config"
    
    $mpvExe = ""
    if (Test-Path "$InstallDir\mpv.exe") {
        $mpvExe = "$InstallDir\mpv.exe"
    } elseif (Get-Command mpv -ErrorAction SilentlyContinue) {
        $mpvExe = (Get-Command mpv).Source
    } else {
        $found = Find-MpvOnSystem
        if ($found) { $mpvExe = $found }
        else { $mpvExe = "mpv" }
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

# Custom path to mpv executable (auto-detected)
mpv_path=$mpvExe
"@
$thumbfastConf | Set-Content -Path "$ConfigDir\script-opts\thumbfast.conf" -Encoding UTF8

    Write-Status "thumbfast configured: $mpvExe" "Success"
}

function Download-File {
    param([string]$Url, [string]$OutFile)
    # Try curl first, then Invoke-WebRequest
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        try {
            & curl.exe -L --retry 2 -k --ssl-no-revoke --connect-timeout 15 --max-time 120 -o $OutFile $Url 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile)) { return $true }
        } catch {}
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
        return (Test-Path $OutFile)
    } catch {
        Write-Status "Download failed for $Url : $($_.Exception.Message)" "Warning"
        return $false
    }
}

function Install-Scripts {
    Write-Status "Checking scripts..." "Info"

    if (!(Test-Path "$ConfigDir\scripts\uosc\main.lua")) {
        Write-Status "Downloading uosc..." "Info"
        try {
            $tempZip = "$env:TEMP\uosc.zip"
            if (Download-File -Url "https://github.com/tomasklaen/uosc/releases/latest/download/uosc.zip" -OutFile $tempZip) {
                Expand-Archive -Path $tempZip -DestinationPath "$ConfigDir\scripts" -Force
                Remove-Item -Path $tempZip -Force
                Write-Status "uosc installed" "Success"
            } else {
                Write-Status "Failed to download uosc" "Warning"
            }
        } catch { Write-Status "Failed to install uosc: $($_.Exception.Message)" "Warning" }
    }

    if (!(Test-Path "$ConfigDir\scripts\thumbfast.lua")) {
        Write-Status "Downloading thumbfast..." "Info"
        if (Download-File -Url "https://raw.githubusercontent.com/po5/thumbfast/master/thumbfast.lua" -OutFile "$ConfigDir\scripts\thumbfast.lua") {
            Write-Status "thumbfast.lua installed" "Success"
        } else {
            Write-Status "Failed to download thumbfast.lua" "Warning"
        }
    }

    if (!(Test-Path "$ConfigDir\scripts\autoload.lua")) {
        Write-Status "Downloading autoload..." "Info"
        if (Download-File -Url "https://raw.githubusercontent.com/mpv-player/mpv/master/TOOLS/lua/autoload.lua" -OutFile "$ConfigDir\scripts\autoload.lua") {
            Write-Status "autoload.lua installed" "Success"
        } else {
            Write-Status "Failed to download autoload.lua" "Warning"
        }
    }
}

function Update-Configs {
    Write-Status "Checking for config updates..." "Config"
    $thumbfastConf = "$ConfigDir\script-opts\thumbfast.conf"
    if (Test-Path $thumbfastConf) {
        $content = Get-Content $thumbfastConf -Raw
        $mpvPath = ""
        if ($content -match "mpv_path=(.+)") { $mpvPath = $matches[1].Trim() }
        if ($mpvPath -and !(Test-Path $mpvPath)) {
            Write-Status "thumbfast mpv_path invalid, fixing..." "Warning"
            Fix-ThumbfastConfig
        }
    }
}

# === MAIN SCRIPT ===
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "    RMN-Player Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Features:" -ForegroundColor Yellow
Write-Host "  - Desktop & Start Menu shortcuts"
Write-Host "  - File associations"
Write-Host "  - PATH configuration"
Write-Host "  - Thumbfast thumbnail preview"
Write-Host "  - uosc modern UI"
Write-Host ""

$isAdmin = Test-AdminPrivileges
if ($isAdmin) {
    Write-Status "Running as Administrator" "Success"
} else {
    Write-Status "Running as standard user (some features limited)" "Warning"
}

# Note: mpv.exe icon will be patched automatically during installation
$bundledMpv = Join-Path $ScriptDir "mpv\mpv.exe"
if (Test-Path $bundledMpv) {
    $bundledSize = (Get-Item $bundledMpv).Length
    if ($bundledSize -gt 55MB) {
        Write-Status "Bundled mpv.exe appears pre-patched ($([math]::Round($bundledSize/1MB,1)) MB)" "Info"
    } else {
        Write-Status "Bundled mpv.exe will be patched during installation" "Info"
    }
}

if ($ConfigOnly) {
    Install-ConfigFiles
    Install-Scripts
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
    Write-Status "Performing full install (update + config)..." "Info"
    Set-MpvHome
    Install-Icon
    Register-Mpv
    Register-Uninstall
    Create-Shortcuts
    Set-FileAssociations
}

try {
    if (!$installed -or $Update -or $Force) {
        $existingMpv = Find-MpvOnSystem
        
        if ($existingMpv) {
            Write-Status "Found existing MPV installation" "Success"
            Copy-MpvFromExisting -SourcePath $existingMpv
        } else {
            Write-Status "No existing MPV found on system" "Warning"
            Write-Status "Attempting to install mpv..." "Info"
            
            # Try winget first
            $wingetMpv = Install-MpvViaWinget
            if ($wingetMpv) {
                Write-Status "mpv installed via winget" "Success"
                Copy-MpvFromExisting -SourcePath $wingetMpv
            } else {
                # Try downloading
                $downloaded = Download-Mpv
                if ($downloaded) {
                    Write-Status "Extracting mpv..." "Info"
                    $7zPaths = @(
                        "C:\Program Files\7-Zip\7z.exe",
                        "C:\Program Files (x86)\7-Zip\7z.exe",
                        "$env:LOCALAPPDATA\7-Zip\7z.exe"
                    )
                    $7z = $null
                    foreach ($p in $7zPaths) {
                        if (Test-Path $p) { $7z = $p; break }
                    }
                    # Try to install 7-Zip if not found
                    if (-not $7z) {
                        Write-Status "7-Zip not found, trying to install..." "Info"
                        try { winget install --id 7zip.7zip -e --accept-source-agreements --accept-package-agreements 2>$null } catch {}
                        foreach ($p in $7zPaths) {
                            if (Test-Path $p) { $7z = $p; break }
                        }
                    }
                    if ($7z) {
                        & $7z x $downloaded -o"$InstallDir" -y 2>$null
                        # Move files from subdirectory if needed
                        $subDir = Get-ChildItem -Path $InstallDir -Directory | Where-Object { $_.Name -like "mpv-*" } | Select-Object -First 1
                        if ($subDir) {
                            Get-ChildItem -Path $subDir.FullName -File | Move-Item -Destination $InstallDir -Force
                            Get-ChildItem -Path $subDir.FullName -Directory | Move-Item -Destination $InstallDir -Force
                            Remove-Item -Path $subDir.FullName -Recurse -Force
                        }
                        Write-Status "mpv installed from download" "Success"
                    } else {
                        Write-Status "7-Zip required to extract. Install 7-Zip first." "Error"
                        exit 1
                    }
                } else {
                    Write-Status "Could not download mpv. Check your internet connection." "Error"
                    Write-Status "Or manually place mpv.exe in: $InstallDir" "Info"
                    exit 1
                }
            }
        }
        
        Add-ToPath
        Set-MpvHome
        Install-Icon
        Register-Mpv
        Register-Uninstall
        Create-Shortcuts
        Set-FileAssociations
    }
    
    Install-ConfigFiles
    Install-Scripts

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
    Write-Host "  Ctrl+T     - Episode tracker status"
    Write-Host ""
    Write-Host "Thumbnail preview: Hover over timeline" -ForegroundColor Green
    Write-Host ""

    # Prompt to set as default video player
    Write-Host ""
    Write-Host "Set RMN-Player as default video player?" -ForegroundColor Yellow
    Write-Host "Windows requires you to manually choose the default app." -ForegroundColor Gray
    $response = Read-Host "Open Windows Default Apps settings? (Y/n)"
    if ($response -ne 'n' -and $response -ne 'N') {
        Write-Status "Opening Windows Default Apps settings..." "Info"
        Start-Process "ms-settings:defaultapps"
        Write-Host ""
        Write-Host "In the settings window:" -ForegroundColor Cyan
        Write-Host "  1. Click 'Video player'" -ForegroundColor White
        Write-Host "  2. Select 'RMN-Player'" -ForegroundColor White
        Write-Host ""
        Write-Host "Tip: You can also right-click any video file," -ForegroundColor Gray
        Write-Host "     select 'Open with' > Choose another app," -ForegroundColor Gray
        Write-Host "     pick RMN-Player, and check 'Always use this app'" -ForegroundColor Gray
    }

    # Prompt to pin to taskbar
    Write-Host ""
    $pinResponse = Read-Host "Pin RMN-Player to taskbar? (Y/n)"
    if ($pinResponse -ne 'n' -and $pinResponse -ne 'N') {
        Write-Status "Opening Taskbar settings..." "Info"
        Start-Process "ms-settings:taskbar"
        Write-Host ""
        Write-Host "To pin RMN-Player:" -ForegroundColor Cyan
        Write-Host "  1. Right-click RMN-Player in Start Menu" -ForegroundColor White
        Write-Host "  2. Select 'Pin to taskbar'" -ForegroundColor White
    }
} catch {
    Write-Status "Installation failed" "Error"
    exit 1
}
