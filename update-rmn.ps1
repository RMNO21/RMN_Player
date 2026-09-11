<#
.SYNOPSIS
    RMN-Player Automated Updater
.DESCRIPTION
    Checks GitHub for the latest RMN-Player version and applies updates safely.
#>

param(
    [switch]$CheckOnly,
    [switch]$ApplyUpdate,
    [switch]$Silent,
    [switch]$Force,
    [string]$Repo = "RMNO21/RMN_Player"
)

$ErrorActionPreference = "Stop"
$ConfigDir = "$env:APPDATA\RMN-Player"
$LocalVersionFile = Join-Path $ConfigDir "version.json"
$RemoteRawUrl = "https://raw.githubusercontent.com/$Repo/main/version.json"
$RemoteApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
$ZipDownloadUrl = "https://github.com/$Repo/archive/refs/heads/main.zip"

function Get-LocalVersion {
    if (Test-Path $LocalVersionFile) {
        try {
            $content = Get-Content -Path $LocalVersionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($content.version) { return $content }
        } catch {}
    }
    return [PSCustomObject]@{
        name = "RMN-Player"
        version = "1.0.0"
        version_code = 100
        release_date = "2026-07-25"
        changelog = "Initial release"
    }
}

function Get-RemoteVersion {
    # 1. Try raw version.json on main branch
    try {
        $headers = @{ "User-Agent" = "RMN-Player-Updater" }
        $json = Invoke-RestMethod -Uri $RemoteRawUrl -Headers $headers -TimeoutSec 7 -UseBasicParsing
        if ($json -and $json.version) {
            return $json
        }
    } catch {}

    # 2. Fallback to GitHub Releases API
    try {
        $headers = @{ "User-Agent" = "RMN-Player-Updater" }
        $release = Invoke-RestMethod -Uri $RemoteApiUrl -Headers $headers -TimeoutSec 7 -UseBasicParsing
        if ($release -and $release.tag_name) {
            $v = $release.tag_name -replace '^(version|v)', ''
            if ($v -match '^\d+$') {
                $v = "1.0." + [int]$v
            }
            return [PSCustomObject]@{
                name = "RMN-Player"
                version = $v
                version_code = 110
                release_date = $release.published_at
                changelog = $release.body
                html_url = $release.html_url
                download_url = $ZipDownloadUrl
            }
        }
    } catch {}

    return $null
}

function Compare-Versions([string]$local, [string]$remote) {
    try {
        $v1Parts = ($local -replace '[^\d\.]', '').Split('.') | ForEach-Object { [int]$_ }
        $v2Parts = ($remote -replace '[^\d\.]', '').Split('.') | ForEach-Object { [int]$_ }
        
        $maxLen = [Math]::Max($v1Parts.Length, $v2Parts.Length)
        for ($i = 0; $i -lt $maxLen; $i++) {
            $p1 = if ($i -lt $v1Parts.Length) { $v1Parts[$i] } else { 0 }
            $p2 = if ($i -lt $v2Parts.Length) { $v2Parts[$i] } else { 0 }
            if ($p2 -gt $p1) { return $true }
            if ($p2 -lt $p1) { return $false }
        }
        return $false
    } catch {
        return ($local -ne $remote)
    }
}

$local = Get-LocalVersion
$remote = Get-RemoteVersion

if ($null -eq $remote) {
    $result = [PSCustomObject]@{
        success = $false
        error = "Could not connect to GitHub"
        current_version = $local.version
        update_available = $false
    }
    $result | ConvertTo-Json -Compress
    exit 0
}

$isNewer = Compare-Versions $local.version $remote.version

if ($CheckOnly) {
    $result = [PSCustomObject]@{
        success = $true
        current_version = $local.version
        latest_version = $remote.version
        update_available = $isNewer
        release_date = $remote.release_date
        changelog = $remote.changelog
        repo_url = "https://github.com/$Repo"
    }
    $result | ConvertTo-Json -Compress
    exit 0
}

if ($ApplyUpdate -or (-not $CheckOnly)) {
    if (-not $isNewer -and -not $Force) {
        if (-not $Silent) { Write-Host "Already on latest version ($($local.version))." -ForegroundColor Green }
        $result = [PSCustomObject]@{
            success = $true
            updated = $false
            message = "Already up to date"
            current_version = $local.version
        }
        $result | ConvertTo-Json -Compress
        exit 0
    }

    $tempZip = Join-Path $env:TEMP "rmn_update_$(Get-Random).zip"
    $tempExtract = Join-Path $env:TEMP "rmn_update_extracted_$(Get-Random)"

    try {
        if (-not $Silent) { Write-Host "Downloading latest version..." -ForegroundColor Cyan }
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "RMN-Player-Updater")
        $webClient.DownloadFile($ZipDownloadUrl, $tempZip)

        if (-not $Silent) { Write-Host "Extracting package..." -ForegroundColor Cyan }
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

        $extractedRoot = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
        if ($null -eq $extractedRoot) {
            throw "Invalid archive format"
        }

        $packageConfigDir = Join-Path $extractedRoot.FullName "config"

        # Apply update to %APPDATA%\RMN-Player
        if (Test-Path $packageConfigDir) {
            if (Test-Path "$packageConfigDir\scripts") {
                Copy-Item -Path "$packageConfigDir\scripts\*" -Destination "$ConfigDir\scripts" -Recurse -Force
            }
            if (Test-Path "$packageConfigDir\shaders") {
                Copy-Item -Path "$packageConfigDir\shaders\*" -Destination "$ConfigDir\shaders" -Recurse -Force
            }
            if (Test-Path "$packageConfigDir\fonts") {
                Copy-Item -Path "$packageConfigDir\fonts\*" -Destination "$ConfigDir\fonts" -Recurse -Force
            }
            if (Test-Path "$packageConfigDir\script-opts") {
                Copy-Item -Path "$packageConfigDir\script-opts\*" -Destination "$ConfigDir\script-opts" -Recurse -Force
            }
            if (Test-Path "$packageConfigDir\input.conf") {
                Copy-Item -Path "$packageConfigDir\input.conf" -Destination "$ConfigDir\input.conf" -Force
            }
            if (Test-Path "$packageConfigDir\version.json") {
                Copy-Item -Path "$packageConfigDir\version.json" -Destination "$ConfigDir\version.json" -Force
            } elseif (Test-Path (Join-Path $extractedRoot.FullName "version.json")) {
                Copy-Item -Path (Join-Path $extractedRoot.FullName "version.json") -Destination "$ConfigDir\version.json" -Force
            }
            if (Test-Path (Join-Path $extractedRoot.FullName "update-rmn.ps1")) {
                Copy-Item -Path (Join-Path $extractedRoot.FullName "update-rmn.ps1") -Destination "$ConfigDir\update-rmn.ps1" -Force
            }
        }

        if (-not $Silent) { Write-Host "Update installed successfully to v$($remote.version)!" -ForegroundColor Green }

        $result = [PSCustomObject]@{
            success = $true
            updated = $true
            new_version = $remote.version
            message = "Update applied successfully"
        }
        $result | ConvertTo-Json -Compress
    } catch {
        $result = [PSCustomObject]@{
            success = $false
            error = $_.Exception.Message
        }
        $result | ConvertTo-Json -Compress
    } finally {
        if (Test-Path $tempZip) { Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
