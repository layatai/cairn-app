# Bootstrap Node.js when absent, then hand all setup work to setup-wizard.mjs.
param(
    [switch]$All,
    [string]$Tool,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$SetupBaseDefault = "https://layatai.github.io/cairn-app"
$NodeBaseDefault = "https://nodejs.org/dist"
$ManagedNodeVersion = "22.23.1"
$MinimumNodeMajor = 18

if ($Help) {
    Write-Host "Usage: setup.ps1 (-All | -Tool <id>) [-Yes] [-DryRun]"
    return
}
if (($All -and $Tool) -or (-not $All -and [string]::IsNullOrWhiteSpace($Tool))) {
    throw "Choose -All or -Tool <id>."
}
if ($Tool -and $Tool -notmatch '^[a-z0-9-]+$') {
    throw "Invalid tool id."
}
if (-not $DryRun -and $env:CAIRN_SETUP_DRY_RUN -eq "1") { $DryRun = $true }

try {
    $Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
} catch {
    $Architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
}
switch -Regex ($Architecture) {
    '^(X64|AMD64)$' { $NodeArch = "x64"; break }
    '^(Arm64|ARM64)$' { $NodeArch = "arm64"; break }
    default { throw "Unsupported Windows architecture: $Architecture" }
}

$LocalAppData = [Environment]::GetFolderPath("LocalApplicationData")
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw "Could not resolve LocalApplicationData." }
$DataDir = if ($env:CAIRN_DATA_DIR) { $env:CAIRN_DATA_DIR } else { Join-Path $LocalAppData "Cairn" }
$NodeRuntimeDir = Join-Path $DataDir "runtime\node-v$ManagedNodeVersion-win-$NodeArch"
$ManagedNode = Join-Path $NodeRuntimeDir "node.exe"
$ExistingNode = Get-Command node -ErrorAction SilentlyContinue

if ($ExistingNode) {
    $NodeExecutable = $ExistingNode.Source
    $Version = (& $NodeExecutable --version).Trim()
    if ($Version -notmatch '^v?(\d+)') { throw "Could not determine the existing Node.js version." }
    if ([int]$Matches[1] -lt $MinimumNodeMajor) {
        throw "Node.js exists but is too old ($Version); upgrade it to Node.js $MinimumNodeMajor+ and retry."
    }
    $NodeSource = "existing"
} elseif (Test-Path -LiteralPath $ManagedNode -PathType Leaf) {
    $NodeExecutable = $ManagedNode
    $Version = (& $NodeExecutable --version).Trim()
    if ($Version -notmatch '^v?(\d+)') { throw "Could not determine the Cairn-managed Node.js version." }
    if ([int]$Matches[1] -lt $MinimumNodeMajor) {
        throw "Cairn-managed Node.js exists but is too old ($Version); remove or upgrade it and retry."
    }
    $NodeSource = "managed-existing"
} else {
    $NodeExecutable = $ManagedNode
    $NodeSource = "managed"
}

$ModeLabel = if ($All) { "all" } else { "tool/$Tool" }
Write-Host "Cairn setup bootstrap:"
Write-Host "  platform : windows/$NodeArch"
Write-Host "  node     : $NodeExecutable ($NodeSource)"
Write-Host "  mode     : $ModeLabel"
if ($DryRun) {
    if ($NodeSource -eq "managed") {
        Write-Host "  action   : would install managed Node.js v$ManagedNodeVersion because node is absent"
    } else {
        Write-Host "  action   : would reuse $(& $NodeExecutable --version)"
    }
    Write-Host "(dry run; no downloads or files changed)"
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("cairn-setup-" + [Guid]::NewGuid().ToString("N"))
$SetupBase = if ($env:CAIRN_SETUP_BASE_URL) { $env:CAIRN_SETUP_BASE_URL.TrimEnd('/') } else { $SetupBaseDefault }
$NodeBase = if ($env:CAIRN_NODE_BASE_URL) { $env:CAIRN_NODE_BASE_URL.TrimEnd('/') } else { $NodeBaseDefault }

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

function Get-Sha256 {
    param([string]$File)
    $Stream = [IO.File]::OpenRead($File)
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace("-", "").ToLowerInvariant()
    } finally {
        $Hasher.Dispose()
        $Stream.Dispose()
    }
}

function Assert-Checksum {
    param([string]$File, [string]$Manifest, [string]$FileName)
    $Expected = Get-ExpectedChecksum -Manifest $Manifest -FileName $FileName
    $Actual = Get-Sha256 -File $File
    if ($Expected -ne $Actual) { throw "Checksum mismatch for $FileName." }
}

function Assert-SafeZip {
    param([string]$Archive)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($Entry in $Zip.Entries) {
            $Segments = @($Entry.FullName.Replace('\', '/').Split('/') | Where-Object { $_ })
            if ([IO.Path]::IsPathRooted($Entry.FullName) -or $Segments -contains "..") {
                throw "Archive contains an unsafe path: $($Entry.FullName)"
            }
        }
    } finally {
        $Zip.Dispose()
    }
}

function Add-UserPath {
    param([string]$Directory)
    $env:Path = "$Directory;$env:Path"
    $Entries = @([Environment]::GetEnvironmentVariable("Path", "User") -split ';' | Where-Object { $_ })
    if (-not ($Entries | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable("Path", ((@($Entries) + $Directory) -join ';'), "User")
    }
}

try {
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    if ($NodeSource -eq "managed") {
        Write-Host ""
        Write-Host "==> Installing managed Node.js v$ManagedNodeVersion"
        $NodePackage = "node-v$ManagedNodeVersion-win-$NodeArch.zip"
        $NodeUrl = "$NodeBase/v$ManagedNodeVersion"
        $Archive = Join-Path $TempDir $NodePackage
        $Checksums = Join-Path $TempDir "node-checksums.txt"
        Invoke-Download -Uri "$NodeUrl/$NodePackage" -Destination $Archive
        Invoke-Download -Uri "$NodeUrl/SHASUMS256.txt" -Destination $Checksums
        Assert-Checksum -File $Archive -Manifest $Checksums -FileName $NodePackage
        Assert-SafeZip -Archive $Archive

        $Extracted = Join-Path $TempDir "node"
        Expand-Archive -LiteralPath $Archive -DestinationPath $Extracted
        $Source = Join-Path $Extracted "node-v$ManagedNodeVersion-win-$NodeArch"
        if ((& (Join-Path $Source "node.exe") --version) -ne "v$ManagedNodeVersion") {
            throw "Downloaded Node.js version is invalid."
        }
        $RuntimeParent = Split-Path -Parent $NodeRuntimeDir
        $Stage = Join-Path $RuntimeParent (".node-install-" + [Guid]::NewGuid().ToString("N"))
        $Backup = Join-Path $RuntimeParent (".node-backup-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $RuntimeParent | Out-Null
        Move-Item -LiteralPath $Source -Destination $Stage
        if (Test-Path -LiteralPath $NodeRuntimeDir) { Move-Item -LiteralPath $NodeRuntimeDir -Destination $Backup }
        try {
            Move-Item -LiteralPath $Stage -Destination $NodeRuntimeDir
            if ((& $ManagedNode --version) -ne "v$ManagedNodeVersion") { throw "Managed Node.js verification failed." }
            if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
        } catch {
            if (Test-Path -LiteralPath $NodeRuntimeDir) { Remove-Item -LiteralPath $NodeRuntimeDir -Recurse -Force }
            if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $NodeRuntimeDir }
            throw
        }
        Add-UserPath -Directory (Split-Path -Parent $ManagedNode)
    } elseif ($NodeSource -eq "managed-existing") {
        Add-UserPath -Directory (Split-Path -Parent $ManagedNode)
    }

    $Wizard = Join-Path $TempDir "setup-wizard.mjs"
    $Catalog = Join-Path $TempDir "setup-tools.json"
    if ($env:CAIRN_SETUP_SCRIPT -or $env:CAIRN_SETUP_CATALOG) {
        if (-not (Test-Path -LiteralPath $env:CAIRN_SETUP_SCRIPT -PathType Leaf) -or
            -not (Test-Path -LiteralPath $env:CAIRN_SETUP_CATALOG -PathType Leaf)) {
            throw "CAIRN_SETUP_SCRIPT and CAIRN_SETUP_CATALOG must both name existing files."
        }
        Copy-Item -LiteralPath $env:CAIRN_SETUP_SCRIPT -Destination $Wizard
        Copy-Item -LiteralPath $env:CAIRN_SETUP_CATALOG -Destination $Catalog
    } else {
        $SetupChecksums = Join-Path $TempDir "setup-checksums.txt"
        Invoke-Download -Uri "$SetupBase/setup-wizard.mjs" -Destination $Wizard
        Invoke-Download -Uri "$SetupBase/setup-tools.json" -Destination $Catalog
        Invoke-Download -Uri "$SetupBase/setup-checksums.txt" -Destination $SetupChecksums
        Assert-Checksum -File $Wizard -Manifest $SetupChecksums -FileName "setup-wizard.mjs"
        Assert-Checksum -File $Catalog -Manifest $SetupChecksums -FileName "setup-tools.json"
    }

    $Arguments = @($Wizard, "--catalog", $Catalog)
    if ($All) { $Arguments += "--all" } else { $Arguments += @("--tool", $Tool) }
    if ($Yes) { $Arguments += "--yes" }
    & $NodeExecutable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Cairn setup wizard exited with code $LASTEXITCODE." }
} finally {
    if (Test-Path -LiteralPath $TempDir) { Remove-Item -LiteralPath $TempDir -Recurse -Force }
}
