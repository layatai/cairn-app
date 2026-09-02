# Install or update the standalone Cairn TUI and its native terminal host.
param(
    [string]$Version = "latest",
    [string]$InstallDir,
    [string]$DataDir,
    [switch]$NoPathUpdate,
    [switch]$DryRun,
    [switch]$Verify,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$ReleaseRepository = "layatai/cairn-app"
$ManagedNodeVersion = "22.23.1"

function Show-Usage {
    Write-Host @"
Install or update the standalone Cairn TUI.

Usage:
  install.ps1 [-Version latest|vX.Y.Z] [-InstallDir path] [-DataDir path]
              [-NoPathUpdate] [-DryRun] [-Verify] [-Help]

Environment:
  CAIRN_VERSION, CAIRN_INSTALL_DIR, CAIRN_DATA_DIR
  CAIRN_SKIP_PATH_UPDATE=1, CAIRN_DRY_RUN=1, CAIRN_VERIFY_INSTALL=1
  CAIRN_DOWNLOAD_BASE_URL    Override the Cairn release download base
  CAIRN_NODE_BASE_URL        Override the official Node.js download base
  CAIRN_ALLOW_INSECURE_DOWNLOADS=1 permits HTTP overrides for local mirrors/tests
"@
}

if ($Help) {
    Show-Usage
    return
}

if (-not $PSBoundParameters.ContainsKey("Version") -and $env:CAIRN_VERSION) {
    $Version = $env:CAIRN_VERSION
}
if (-not $PSBoundParameters.ContainsKey("InstallDir") -and $env:CAIRN_INSTALL_DIR) {
    $InstallDir = $env:CAIRN_INSTALL_DIR
}
if (-not $PSBoundParameters.ContainsKey("DataDir") -and $env:CAIRN_DATA_DIR) {
    $DataDir = $env:CAIRN_DATA_DIR
}
if (-not $PSBoundParameters.ContainsKey("NoPathUpdate") -and $env:CAIRN_SKIP_PATH_UPDATE -eq "1") {
    $NoPathUpdate = $true
}
if (-not $PSBoundParameters.ContainsKey("DryRun") -and $env:CAIRN_DRY_RUN -eq "1") {
    $DryRun = $true
}
if (-not $PSBoundParameters.ContainsKey("Verify") -and $env:CAIRN_VERIFY_INSTALL -eq "1") {
    $Verify = $true
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "Cairn TUI requires PowerShell 5 or newer."
}

try {
    $Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
} catch {
    $Architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
}
switch -Regex ($Architecture) {
    '^(X64|AMD64)$' { $CairnArch = "x64"; $NodeArch = "x64"; break }
    '^(Arm64|ARM64)$' { $CairnArch = "arm64"; $NodeArch = "arm64"; break }
    default { throw "Unsupported Windows architecture: $Architecture" }
}

if ([string]::IsNullOrWhiteSpace($InstallDir) -or [string]::IsNullOrWhiteSpace($DataDir)) {
    $LocalAppData = [Environment]::GetFolderPath("LocalApplicationData")
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
        throw "Could not resolve the current user's LocalApplicationData directory."
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Join-Path $LocalAppData "Cairn\bin" }
    if ([string]::IsNullOrWhiteSpace($DataDir)) { $DataDir = Join-Path $LocalAppData "Cairn" }
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$DataDir = [IO.Path]::GetFullPath($DataDir)

if ($Version -eq "latest") {
    $ReleasePath = "latest/download"
} elseif ($Version -match '^v?\d+\.\d+\.\d+$') {
    if (-not $Version.StartsWith("v")) { $Version = "v$Version" }
    $ReleasePath = "download/$Version"
} else {
    throw "Invalid Cairn version: $Version"
}

$Package = "cairn-tui-windows-$CairnArch.zip"
$DefaultCairnBase = "https://github.com/$ReleaseRepository/releases/$ReleasePath"
$DefaultNodeBase = "https://nodejs.org/dist/v$ManagedNodeVersion"
$CairnBase = if ($env:CAIRN_DOWNLOAD_BASE_URL) { $env:CAIRN_DOWNLOAD_BASE_URL.TrimEnd('/') } else { $DefaultCairnBase }
$NodeBase = if ($env:CAIRN_NODE_BASE_URL) { $env:CAIRN_NODE_BASE_URL.TrimEnd('/') } else { $DefaultNodeBase }
$NodePackage = "node-v$ManagedNodeVersion-win-$NodeArch.zip"
$NodeRuntimeDir = Join-Path $DataDir "runtime\node-v$ManagedNodeVersion-win-$NodeArch"
$NodeExecutable = Join-Path $NodeRuntimeDir "node.exe"

Write-Host "Cairn TUI install plan:"
Write-Host "  platform : Windows/$CairnArch"
Write-Host "  release  : $Version ($Package)"
Write-Host "  launcher : $(Join-Path $InstallDir 'cairn.cmd')"
Write-Host "  data     : $DataDir"
Write-Host "  node     : v$ManagedNodeVersion ($NodePackage)"
Write-Host "  verify   : $Verify"

if ($DryRun) {
    $Git = Get-Command git -ErrorAction SilentlyContinue
    if ($Git) { Write-Host "  git      : $(& git --version)" }
    else { Write-Host "  git      : install with winget, Chocolatey, or Scoop" }
    Write-Host ""
    Write-Host "(dry run; no downloads or files changed)"
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("cairn-install-" + [Guid]::NewGuid().ToString("N"))

function Invoke-Download {
    param([string]$Uri, [string]$Destination)
    if (-not $Uri.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase) -and $env:CAIRN_ALLOW_INSECURE_DOWNLOADS -ne "1") {
        throw "Refusing non-HTTPS download: $Uri"
    }
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
}

function Get-ExpectedChecksum {
    param([string]$Manifest, [string]$FileName)
    $Pattern = '^\s*(?<hash>[0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($FileName) + '\s*$'
    foreach ($Line in Get-Content -LiteralPath $Manifest) {
        $Match = [regex]::Match($Line, $Pattern)
        if ($Match.Success) { return $Match.Groups["hash"].Value.ToLowerInvariant() }
    }
    throw "Checksum for $FileName is missing."
}

function Assert-Checksum {
    param([string]$Archive, [string]$Manifest, [string]$FileName)
    $Expected = Get-ExpectedChecksum -Manifest $Manifest -FileName $FileName
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant()
    if ($Expected -ne $Actual) { throw "Checksum mismatch for $FileName." }
}

function Assert-SafeZip {
    param([string]$Archive)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($Entry in $Zip.Entries) {
            $Normalized = $Entry.FullName.Replace('\', '/')
            $Segments = @($Normalized.Split('/') | Where-Object { $_ -ne "" })
            if ([IO.Path]::IsPathRooted($Entry.FullName) -or $Segments -contains "..") {
                throw "Archive contains an unsafe path: $($Entry.FullName)"
            }
        }
    } finally {
        $Zip.Dispose()
    }
}

function Refresh-ProcessPath {
    $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($MachinePath, $UserPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

function Test-GitAvailable {
    return $null -ne (Get-Command git -ErrorAction SilentlyContinue)
}

function Install-Git {
    if (Test-GitAvailable) { return }
    Write-Host ""
    Write-Host "==> Installing Git"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) { throw "winget failed to install Git with exit code $LASTEXITCODE." }
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        & choco install git -y
        if ($LASTEXITCODE -ne 0) { throw "Chocolatey failed to install Git with exit code $LASTEXITCODE." }
    } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
        & scoop install git
        if ($LASTEXITCODE -ne 0) { throw "Scoop failed to install Git with exit code $LASTEXITCODE." }
    } else {
        throw "Git is missing and winget, Chocolatey, and Scoop are unavailable."
    }
    Refresh-ProcessPath
    if (-not (Test-GitAvailable)) { throw "Git installation completed but git is not on PATH." }
}

function Install-ManagedNode {
    if (Test-Path -LiteralPath $NodeExecutable -PathType Leaf) {
        $InstalledVersion = (& $NodeExecutable --version 2>$null)
        if ($InstalledVersion -eq "v$ManagedNodeVersion") { return }
    }

    Write-Host ""
    Write-Host "==> Installing managed Node.js v$ManagedNodeVersion"
    $Archive = Join-Path $TempDir $NodePackage
    $Checksums = Join-Path $TempDir "node-checksums.txt"
    Invoke-Download -Uri "$NodeBase/$NodePackage" -Destination $Archive
    Invoke-Download -Uri "$NodeBase/SHASUMS256.txt" -Destination $Checksums
    Assert-Checksum -Archive $Archive -Manifest $Checksums -FileName $NodePackage
    Assert-SafeZip -Archive $Archive

    $Extracted = Join-Path $TempDir "node-extracted"
    Expand-Archive -LiteralPath $Archive -DestinationPath $Extracted
    $Source = Join-Path $Extracted "node-v$ManagedNodeVersion-win-$NodeArch"
    $SourceNode = Join-Path $Source "node.exe"
    if (-not (Test-Path -LiteralPath $SourceNode -PathType Leaf)) { throw "Managed Node.js archive is missing node.exe." }
    if ((& $SourceNode --version) -ne "v$ManagedNodeVersion") { throw "Managed Node.js version is invalid." }

    $RuntimeParent = Split-Path -Parent $NodeRuntimeDir
    $Stage = Join-Path $RuntimeParent (".node-install-" + [Guid]::NewGuid().ToString("N"))
    $Backup = Join-Path $RuntimeParent (".node-backup-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $RuntimeParent | Out-Null
    Move-Item -LiteralPath $Source -Destination $Stage
    if (Test-Path -LiteralPath $NodeRuntimeDir) { Move-Item -LiteralPath $NodeRuntimeDir -Destination $Backup }
    try {
        Move-Item -LiteralPath $Stage -Destination $NodeRuntimeDir
        if ((& $NodeExecutable --version) -ne "v$ManagedNodeVersion") { throw "Installed Node.js verification failed." }
        if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
    } catch {
        if (Test-Path -LiteralPath $NodeRuntimeDir) { Remove-Item -LiteralPath $NodeRuntimeDir -Recurse -Force }
        if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $NodeRuntimeDir }
        throw
    }
}

function ConvertTo-CmdLiteral {
    param([string]$Value)
    return $Value.Replace('%', '%%').Replace('"', '""')
}

try {
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    Install-Git
    Install-ManagedNode

    Write-Host ""
    Write-Host "==> Downloading Cairn TUI"
    $Archive = Join-Path $TempDir $Package
    $Checksums = Join-Path $TempDir "cairn-checksums.txt"
    Invoke-Download -Uri "$CairnBase/$Package" -Destination $Archive
    Invoke-Download -Uri "$CairnBase/cairn-tui-checksums.txt" -Destination $Checksums
    Assert-Checksum -Archive $Archive -Manifest $Checksums -FileName $Package
    Assert-SafeZip -Archive $Archive

    $Extracted = Join-Path $TempDir "cairn-package"
    Expand-Archive -LiteralPath $Archive -DestinationPath $Extracted
    $TuiSource = Join-Path $Extracted "cairn.mjs"
    $HostSource = Join-Path $Extracted "cairn-terminal-host.exe"
    foreach ($Required in @($TuiSource, $HostSource, (Join-Path $Extracted "VERSION"), (Join-Path $Extracted "PROTOCOL_VERSION"), (Join-Path $Extracted "HOST_BUILD_ID"), (Join-Path $Extracted "PACKAGE"))) {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Cairn package is missing $(Split-Path -Leaf $Required)." }
    }
    if ((Get-Content -LiteralPath $TuiSource -TotalCount 1) -ne '#!/usr/bin/env node') { throw "Invalid Cairn TUI executable." }
    $PackageVersion = (Get-Content -Raw -LiteralPath (Join-Path $Extracted "VERSION")).Trim()
    $ProtocolVersion = (Get-Content -Raw -LiteralPath (Join-Path $Extracted "PROTOCOL_VERSION")).Trim()
    $HostBuildId = (Get-Content -Raw -LiteralPath (Join-Path $Extracted "HOST_BUILD_ID")).Trim()
    $PackageMarker = (Get-Content -Raw -LiteralPath (Join-Path $Extracted "PACKAGE")).Trim()
    if ($PackageVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid Cairn package version." }
    if ($ProtocolVersion -notmatch '^\d+$') { throw "Invalid terminal-host protocol version." }
    if ($HostBuildId -notmatch '^[0-9a-f]{16}$') { throw "Invalid terminal-host build id." }
    if ($PackageMarker -ne "cairn-tui $PackageVersion windows $CairnArch") { throw "Incompatible Cairn package metadata: $PackageMarker" }
    if ($Version -ne "latest" -and $Version -ne "v$PackageVersion") { throw "Package version $PackageVersion does not match requested release $Version." }

    $VersionsDir = Join-Path $DataDir "tui\versions"
    $PackageDir = Join-Path $VersionsDir $PackageVersion
    $Stage = Join-Path $VersionsDir (".cairn-install-" + [Guid]::NewGuid().ToString("N"))
    $Backup = Join-Path $VersionsDir (".cairn-backup-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $VersionsDir | Out-Null
    Move-Item -LiteralPath $Extracted -Destination $Stage
    if (Test-Path -LiteralPath $PackageDir) { Move-Item -LiteralPath $PackageDir -Destination $Backup }
    try {
        Move-Item -LiteralPath $Stage -Destination $PackageDir
        $InstalledTui = Join-Path $PackageDir "cairn.mjs"
        if ((& $NodeExecutable $InstalledTui --version) -ne "cairn $PackageVersion") {
            throw "Installed Cairn package failed version verification."
        }
        if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
    } catch {
        if (Test-Path -LiteralPath $PackageDir) { Remove-Item -LiteralPath $PackageDir -Recurse -Force }
        if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $PackageDir }
        throw
    }

    Write-Host ""
    Write-Host "==> Installing Cairn launcher"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $Launcher = Join-Path $InstallDir "cairn.cmd"
    $Action = if (Test-Path -LiteralPath $Launcher) { "Updated" } else { "Installed" }
    $LauncherTemp = Join-Path $InstallDir (".cairn-install-" + [Guid]::NewGuid().ToString("N") + ".cmd")
    $CmdData = ConvertTo-CmdLiteral -Value $DataDir
    $CmdNode = ConvertTo-CmdLiteral -Value $NodeExecutable
    $CmdTui = ConvertTo-CmdLiteral -Value (Join-Path $PackageDir "cairn.mjs")
    $LauncherContent = "@echo off`r`nset `"CAIRN_DATA_DIR=$CmdData`"`r`n`"$CmdNode`" `"$CmdTui`" %*`r`n"
    Set-Content -LiteralPath $LauncherTemp -Value $LauncherContent -Encoding ASCII -NoNewline
    Move-Item -LiteralPath $LauncherTemp -Destination $Launcher -Force

    $PathNote = $null
    if (-not $NoPathUpdate) {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $PathEntries = @($UserPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (-not ($PathEntries | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') })) {
            [Environment]::SetEnvironmentVariable("Path", ((@($PathEntries) + $InstallDir) -join ';'), "User")
            $PathNote = "Added $InstallDir to the user PATH; open a new terminal."
        }
    }
    if ($Verify -and ((& $Launcher --version) -ne "cairn $PackageVersion")) {
        throw "Installed launcher verification failed."
    }

    Write-Host ""
    Write-Host "$Action Cairn TUI $PackageVersion."
    Write-Host "  command: $Launcher"
    Write-Host "  package: $PackageDir"
    Write-Host "  node:    $NodeExecutable"
    if ($PathNote) { Write-Host "  note:    $PathNote" }
    Write-Host "Run: cairn"
} finally {
    if (Test-Path -LiteralPath $TempDir) { Remove-Item -LiteralPath $TempDir -Recurse -Force }
}
