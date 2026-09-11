param(
    [string]$Repo = "RMNO21/RMN_Player"
)

$ErrorActionPreference = "Stop"
$ConfigDir = "$env:APPDATA\RMN-Player"
$LocalVersionFile = Join-Path $ConfigDir "version.json"
$RemoteUrl = "https://raw.githubusercontent.com/$Repo/main/version.json"
$ZipUrl = "https://github.com/$Repo/archive/refs/heads/main.zip"

# Read local version
$localVersion = "1.0.0"
if (Test-Path $LocalVersionFile) {
    try {
        $local = Get-Content $LocalVersionFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($local.version) { $localVersion = $local.version }
    } catch {}
}

# Fetch remote version
try {
    $remote = Invoke-RestMethod -Uri $RemoteUrl -Headers @{"User-Agent"="RMN-Player"} -TimeoutSec 7 -UseBasicParsing
    $remoteVersion = $remote.version
} catch {
    Write-Output "ERROR: Connection failed"
    exit 1
}

if (-not $remoteVersion) {
    Write-Output "ERROR: Remote version not found"
    exit 1
}

# Compare versions
$v1 = ($localVersion -replace '[^\d\.]','').Split('.') | ForEach-Object { [int]$_ }
$v2 = ($remoteVersion -replace '[^\d\.]','').Split('.') | ForEach-Object { [int]$_ }
$maxLen = [Math]::Max($v1.Length, $v2.Length)
$isNewer = $false
for ($i = 0; $i -lt $maxLen; $i++) {
    $p1 = if ($i -lt $v1.Length) { $v1[$i] } else { 0 }
    $p2 = if ($i -lt $v2.Length) { $v2[$i] } else { 0 }
    if ($p2 -gt $p1) { $isNewer = $true; break }
    if ($p2 -lt $p1) { break }
}

# If already up to date
if (-not $isNewer) {
    Write-Output "UP_TO_DATE:$localVersion"
    exit 0
}

# Automatically download and install new version
$tempZip = Join-Path $env:TEMP "rmn_update_$([System.IO.Path]::GetRandomFileName()).zip"
$tempDir = Join-Path $env:TEMP "rmn_ext_$([System.IO.Path]::GetRandomFileName())"

try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "RMN-Player")
    $wc.DownloadFile($ZipUrl, $tempZip)

    Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
    $root = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
    $srcConfig = Join-Path $root.FullName "config"

    if (Test-Path $srcConfig) {
        if (Test-Path "$srcConfig\scripts") {
            Copy-Item "$srcConfig\scripts\*" "$ConfigDir\scripts" -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path "$srcConfig\shaders") {
            Copy-Item "$srcConfig\shaders\*" "$ConfigDir\shaders" -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path "$srcConfig\fonts") {
            Copy-Item "$srcConfig\fonts\*" "$ConfigDir\fonts" -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path "$srcConfig\script-opts") {
            Copy-Item "$srcConfig\script-opts\*" "$ConfigDir\script-opts" -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path "$srcConfig\input.conf") {
            Copy-Item "$srcConfig\input.conf" "$ConfigDir\input.conf" -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path "$srcConfig\version.json") {
            Copy-Item "$srcConfig\version.json" "$ConfigDir\version.json" -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path (Join-Path $root.FullName "update-rmn.ps1")) {
        Copy-Item (Join-Path $root.FullName "update-rmn.ps1") "$ConfigDir\update-rmn.ps1" -Force -ErrorAction SilentlyContinue
    }

    Write-Output "UPDATED:$remoteVersion"
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
} finally {
    if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
}
