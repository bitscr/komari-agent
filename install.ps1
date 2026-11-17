# Windows PowerShell installation script for Komari Agent
#Requires -Version 5.1

# Logging functions with colors
function Log-Info { param([string]$Message) Write-Host "$Message"    -ForegroundColor Cyan }
function Log-Success { param([string]$Message) Write-Host "$Message"    -ForegroundColor Green }
function Log-Warning { param([string]$Message) Write-Host "[WARNING] $Message"    -ForegroundColor Yellow }
function Log-Error { param([string]$Message) Write-Host "[ERROR] $Message"    -ForegroundColor Red }
function Log-Step { param([string]$Message) Write-Host "$Message"    -ForegroundColor Magenta }
function Log-Config { param([string]$Message) Write-Host "- $Message"    -ForegroundColor White }

# Default parameters
$InstallDir = Join-Path $Env:ProgramFiles "Komari"
$ServiceName = "komari-agent"
$GitHubProxy = ""
$KomariArgs = @()
$InstallVersion = ""

# Parse script arguments
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--install-dir" { $InstallDir = $args[$i + 1]; $i++; continue }
        "--install-service-name" { $ServiceName = $args[$i + 1]; $i++; continue }
        "--install-ghproxy" { $GitHubProxy = $args[$i + 1]; $i++; continue }
        "--install-version" { $InstallVersion = $args[$i + 1]; $i++; continue }
        Default { $KomariArgs += $args[$i] }
    }
}
if ($GitHubProxy) { $GitHubProxy = $GitHubProxy.TrimEnd('/') }

# GitHub 在 Windows PowerShell 5.1 上默认可能还是 TLS 1.0/SSL3，会直接导致
# Invoke-WebRequest 报 "Could not create SSL/TLS secure channel"。这里显式打开 TLS 1.2/1.3。
try {
    $tls = [Net.SecurityProtocolType]::Tls12
    if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $tls = $tls -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $tls
}
catch {
    Log-Warning "Unable to raise TLS version, continuing with system defaults: $_"
}

$ProgressPreference = 'SilentlyContinue'

# Ensure running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Log-Error "Please run this script as Administrator."
    exit 1
}

# Prepare GitHub proxy display
if ($GitHubProxy -ne '') { $ProxyDisplay = $GitHubProxy } else { $ProxyDisplay = '(direct)' }

# Detect architecture early for constructing binary name.
# PROCESSOR_ARCHITEW6432 is set when a 32-bit PowerShell runs on a 64-bit OS,
# in which case PROCESSOR_ARCHITECTURE would wrongly report x86.
$procArch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $procArch = $env:PROCESSOR_ARCHITEW6432 }
switch ($procArch) {
    'AMD64' { $arch = 'amd64' }
    'ARM64' { $arch = 'arm64' }
    'x86' { $arch = '386' }
    Default { Log-Error "Unsupported architecture: $procArch"; exit 1 }
}

# Download helper: GitHub release downloads are retried a few times before failing.
function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$Retries = 3
    )
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq $Retries) { throw }
            Log-Warning "Download attempt $attempt failed ($($_.Exception.Message)), retrying..."
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

# Build a list of candidate URLs: with the GitHub proxy first when one is configured.
function Get-CandidateUrls {
    param([Parameter(Mandatory = $true)][string]$Url)
    $urls = @()
    if ($GitHubProxy -ne '') { $urls += "$GitHubProxy/$Url" }
    $urls += $Url
    return $urls
}

# Download the first candidate that works and return the URL that succeeded.
function Invoke-DownloadWithProxy {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $lastError = $null
    foreach ($candidate in Get-CandidateUrls -Url $Url) {
        try {
            Log-Info "Downloading $candidate"
            Invoke-Download -Uri $candidate -OutFile $OutFile
            return $candidate
        }
        catch {
            $lastError = $_
            Log-Warning "Failed: $candidate"
        }
    }
    throw "All download sources failed. Last error: $lastError"
}

# Ensure installation directory exists for the agent (and optional nssm)
Log-Step "Ensuring installation directory exists: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction SilentlyContinue | Out-Null

# ---------------------------------------------------------------------------
# Service backend selection
#   nssm  : preferred when available, gives restart/backoff management
#   sc    : built into Windows, zero external dependencies (fallback)
# nssm.cc has been returning 5xx for a long time, so a missing nssm must never
# abort the installation — otherwise Windows users simply cannot install.
# ---------------------------------------------------------------------------
$nssmExeToUse = Join-Path $InstallDir "nssm.exe"
$nssmPath = $null

$nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
if ($nssmCmd) {
    try {
        nssm version 2>&1 | Out-Null
        $nssmPath = $nssmCmd.Source
        Log-Info "nssm found in PATH at $nssmPath."
    }
    catch {
        Log-Warning "nssm in PATH is not usable: $_"
    }
}

if (-not $nssmPath -and (Test-Path $nssmExeToUse)) {
    try {
        & $nssmExeToUse version 2>&1 | Out-Null
        $nssmPath = $nssmExeToUse
        Log-Info "nssm found at $nssmPath."
    }
    catch {
        Log-Warning "nssm at $nssmExeToUse is not usable: $_"
    }
}

if (-not $nssmPath) {
    $NssmVersion = "2.24"
    $NssmSources = @(
        "https://nssm.cc/release/nssm-$NssmVersion.zip",
        "https://github.com/kirillkovalenko/nssm/releases/download/v$NssmVersion/nssm-$NssmVersion.zip"
    )
    $TempNssmZipPath = Join-Path $env:TEMP "nssm-$NssmVersion.zip"
    $TempExtractDir = Join-Path $env:TEMP "nssm_extract_temp"

    foreach ($source in $NssmSources) {
        try {
            Log-Info "nssm not found, trying $source"
            Invoke-Download -Uri $source -OutFile $TempNssmZipPath -Retries 1

            if (Test-Path $TempExtractDir) { Remove-Item -Recurse -Force $TempExtractDir }
            New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
            Expand-Archive -Path $TempNssmZipPath -DestinationPath $TempExtractDir -Force

            $found = Get-ChildItem -Path $TempExtractDir -Recurse -Filter "nssm.exe" |
            Where-Object { $_.FullName -match '\\win32\\nssm\.exe$' } |
            Select-Object -First 1
            if (-not $found) {
                $found = Get-ChildItem -Path $TempExtractDir -Recurse -Filter "nssm.exe" | Select-Object -First 1
            }
            if (-not $found) { throw "nssm.exe not found inside $source" }

            Copy-Item -Path $found.FullName -Destination $nssmExeToUse -Force
            $nssmPath = $nssmExeToUse
            Log-Success "Downloaded nssm to $nssmExeToUse"
            break
        }
        catch {
            Log-Warning "Could not obtain nssm from $source : $($_.Exception.Message)"
        }
        finally {
            if (Test-Path $TempNssmZipPath) { Remove-Item $TempNssmZipPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

if ($nssmPath) {
    $ServiceBackend = 'nssm'
    $env:Path = "$(Split-Path -Parent $nssmPath);$($env:Path)"
}
else {
    $ServiceBackend = 'sc'
    Log-Warning "nssm is unavailable; falling back to the built-in sc.exe service manager."
    Log-Warning "Automatic restart-on-failure is still configured via 'sc failure'."
}

Log-Step "Installation configuration:"
Log-Config "Service name: $ServiceName"
Log-Config "Install directory: $InstallDir"
Log-Config "Service backend: $ServiceBackend"
Log-Config "GitHub proxy: $ProxyDisplay"
Log-Config "Agent arguments: $($KomariArgs -join ' ')"
if ($InstallVersion -ne "") {
    Log-Config "Specified agent version: $InstallVersion"
}
else {
    Log-Config "Agent version: Latest"
}

# Paths
$BinaryName = "komari-agent-windows-$arch.exe"
$AgentPath = Join-Path $InstallDir "komari-agent.exe"

# Quote arguments that contain whitespace so nssm/sc.exe keep them intact.
$quotedArgs = $KomariArgs | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}
$argString = ($quotedArgs -join ' ').Trim()

# Stop and remove any previous service (works for both nssm and sc services,
# because nssm-managed services are ordinary Windows services too).
function Remove-PreviousService {
    Log-Step "Checking for existing service..."
    $query = sc.exe query $ServiceName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log-Info "Stopping service $ServiceName..."
        sc.exe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        Log-Info "Removing service $ServiceName..."
        sc.exe delete $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 1
    }
    else {
        Log-Info "Service $ServiceName does not exist or was already removed."
    }

    if (Test-Path $AgentPath) {
        Log-Warning "Removing old binary..."
        Remove-Item $AgentPath -Force -ErrorAction SilentlyContinue
    }
}
Remove-PreviousService

function Get-LatestSnapshotVersion {
    param([Parameter(Mandatory = $true)][string]$AssetName)

    $ApiUrl = "https://api.github.com/repos/bitscr/komari-agent/releases?per_page=100"
    $ApiUrls = Get-CandidateUrls -Url $ApiUrl

    foreach ($candidate in $ApiUrls) {
        try {
            Log-Info "Fetching snapshot releases from GitHub API..."
            $releases = Invoke-RestMethod -Uri $candidate -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Log-Warning "Snapshot API request failed through $candidate"
            continue
        }

        $latestSnapshot = $releases |
        Where-Object {
            $_.draft -eq $false -and
            $_.prerelease -eq $true -and
            $_.tag_name -like "Snapshot-*" -and
            (@($_.assets.name) -contains $AssetName)
        } |
        Sort-Object -Property @{ Expression = { [datetime]$_.published_at }; Descending = $true }, @{ Expression = { $_.tag_name }; Descending = $true } |
        Select-Object -First 1

        if ($latestSnapshot) {
            return $latestSnapshot.tag_name
        }
    }

    throw "No snapshot release contains asset $AssetName."
}

$versionToInstall = ""
if ($InstallVersion -ne "") {
    Log-Info "Attempting to install specified version: $InstallVersion"
    if ($InstallVersion -ieq "snapshot") {
        Log-Info "Resolving the latest snapshot version..."
        try {
            $versionToInstall = Get-LatestSnapshotVersion -AssetName $BinaryName
            Log-Success "Latest snapshot version fetched: $versionToInstall"
        }
        catch {
            Log-Error "Failed to resolve the latest snapshot version: $_"
            exit 1
        }
    }
    else {
        $versionToInstall = $InstallVersion
    }
}
else {
    $ApiUrl = "https://api.github.com/repos/bitscr/komari-agent/releases/latest"
    $release = $null
    foreach ($candidate in (Get-CandidateUrls -Url $ApiUrl)) {
        try {
            Log-Step "Fetching latest release version from GitHub API..."
            $release = Invoke-RestMethod -Uri $candidate -UseBasicParsing -ErrorAction Stop
            break
        }
        catch {
            Log-Warning "Version lookup failed through $candidate : $($_.Exception.Message)"
        }
    }
    if (-not $release) {
        Log-Error "Failed to fetch latest version. Pass --install-version <tag> to skip the API call."
        exit 1
    }
    $versionToInstall = $release.tag_name
    Log-Success "Latest version fetched: $versionToInstall"
}
Log-Success "Installing Komari Agent version: $versionToInstall"

# Download the agent binary
$DownloadUrl = "https://github.com/bitscr/komari-agent/releases/download/$versionToInstall/$BinaryName"
try {
    $null = Invoke-DownloadWithProxy -Url $DownloadUrl -OutFile $AgentPath
}
catch {
    Log-Error "Download failed: $_"
    exit 1
}
Log-Success "Downloaded and saved to $AgentPath"

# Sanity check: an executable that cannot even print help will not run as a service.
try {
    $helpOutput = & $AgentPath --help 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log-Warning "The downloaded binary exited with code $LASTEXITCODE on --help. Installation will continue."
    }
    else {
        Log-Success "Binary check passed."
    }
}
catch {
    Log-Warning "Could not execute the downloaded binary for a sanity check: $_"
}

# ---------------------------------------------------------------------------
# Register and start the service
# ---------------------------------------------------------------------------
$binPathWithArgs = if ($argString) { "`"$AgentPath`" $argString" } else { "`"$AgentPath`"" }

if ($ServiceBackend -eq 'nssm') {
    Log-Step "Configuring Windows service with nssm..."
    & $nssmPath install $ServiceName $AgentPath $argString | Out-Null
    & $nssmPath set $ServiceName DisplayName "Komari Agent Service" | Out-Null
    & $nssmPath set $ServiceName Start SERVICE_AUTO_START | Out-Null
    & $nssmPath set $ServiceName AppExit Default Restart | Out-Null
    & $nssmPath set $ServiceName AppRestartDelay 5000 | Out-Null
    & $nssmPath start $ServiceName | Out-Null
}
else {
    Log-Step "Configuring Windows service with sc.exe..."
    sc.exe create $ServiceName binPath= $binPathWithArgs start= auto DisplayName= "Komari Agent Service" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Log-Error "Failed to create service $ServiceName (sc.exe exit code $LASTEXITCODE)."
        exit 1
    }
    sc.exe description $ServiceName "Komari Agent Service" | Out-Null
    # Restart the agent if it exits unexpectedly (5s delay, 3 attempts, reset daily).
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    sc.exe start $ServiceName | Out-Null
}

# Wait for the service to settle (StartPending -> Running) before judging it.
$state = $null
for ($i = 0; $i -lt 10; $i++) {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $state = if ($service) { $service.Status } else { $null }
    if ($state -eq 'Running') { break }
    Start-Sleep -Seconds 1
}
if ($state -eq 'Running') {
    Log-Success "Service $ServiceName installed and running (backend: $ServiceBackend)."
}
else {
    Log-Warning "Service $ServiceName state is '$state'. Inspect it with: sc.exe query $ServiceName"
    Log-Warning "Or run the agent in the foreground to see the startup error: \"$AgentPath\" $argString"
}

Log-Success "Komari Agent installation completed!"
Log-Config "Service name: $ServiceName"
Log-Config "Arguments: $argString"
Log-Config "Uninstall: sc.exe stop $ServiceName; sc.exe delete $ServiceName"
