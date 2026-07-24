#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$WithExtension,
    [switch]$AdoptLegacy,
    [switch]$SkipPathUpdate
)

$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$appRoot = if ($env:BYOK_CLI_HUB_INSTALL_ROOT) { [IO.Path]::GetFullPath($env:BYOK_CLI_HUB_INSTALL_ROOT) } else { Join-Path $env:LOCALAPPDATA 'byok-cli-hub' }
$targetDir = Join-Path $appRoot 'app'
$dataDir = if ($env:BYOK_CLI_HUB_DATA_DIR) { [IO.Path]::GetFullPath($env:BYOK_CLI_HUB_DATA_DIR) } else { Join-Path $env:USERPROFILE '.byok-cli-hub' }
$copilotHome = if ($env:COPILOT_HOME) { [IO.Path]::GetFullPath($env:COPILOT_HOME) } else { Join-Path $env:USERPROFILE '.copilot' }
$extensionDir = Join-Path $copilotHome 'extensions\byok-cli-hub-copilot'
$manifestName = '.byok-cli-hub-install.json'
$markerName = '.byok-cli-hub-managed'

function Test-SameOrChild([string]$Parent, [string]$Child) {
    $p = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $c = [IO.Path]::GetFullPath($Child).TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafePath([string]$Label, [string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if (-not $full -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label resolves to a filesystem root: $full" }
    if ($full.Equals([IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw "$Label must not be the user profile." }
    if ($full.Equals($sourceRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw "$Label must not be the repository root." }
}

Assert-SafePath 'install root' $appRoot
Assert-SafePath 'data dir' $dataDir
Assert-SafePath 'extension dir' $extensionDir
if ((Test-SameOrChild $targetDir $dataDir) -or (Test-SameOrChild $dataDir $targetDir)) { throw 'Application and data directories must not overlap.' }

$existingManifest = Join-Path $targetDir $manifestName
if (Test-Path -LiteralPath $existingManifest) {
    $previous = Get-Content -Raw -LiteralPath $existingManifest -Encoding UTF8 | ConvertFrom-Json
    if ($previous.product -ne 'byok-cli-hub' -or $previous.schemaVersion -ne 1) { throw 'The existing install manifest is invalid.' }
    if (-not $env:BYOK_CLI_HUB_DATA_DIR) { $dataDir = [IO.Path]::GetFullPath($previous.dataDir) }
    if (-not $env:COPILOT_HOME) { $extensionDir = [IO.Path]::GetFullPath($previous.extensionDir) }
    if ($previous.withExtension) { $WithExtension = $true }
    Assert-SafePath 'data dir' $dataDir
    Assert-SafePath 'extension dir' $extensionDir
    if ((Test-SameOrChild $targetDir $dataDir) -or (Test-SameOrChild $dataDir $targetDir)) { throw 'Application and data directories must not overlap.' }
}
if ((Test-Path -LiteralPath $targetDir) -and -not (Test-Path -LiteralPath $existingManifest)) {
    throw "Refusing to replace unowned application directory '$targetDir'."
}
if ($WithExtension -and (Test-Path -LiteralPath $extensionDir) -and -not (Test-Path -LiteralPath (Join-Path $extensionDir $markerName))) {
    $recognizableLegacy = (Test-Path -LiteralPath (Join-Path $extensionDir 'extension.mjs')) -and (Test-Path -LiteralPath (Join-Path $extensionDir 'package.json'))
    if (-not ($AdoptLegacy -and $recognizableLegacy)) { throw "Refusing to replace unowned extension '$extensionDir'. Use -AdoptLegacy only for a verified legacy install." }
}

New-Item -ItemType Directory -Force -Path $appRoot, $dataDir | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $dataDir '.byok-cli-hub-data') | Out-Null
$legacyConfig = Join-Path $dataDir 'config\providers.json'
$configPath = Join-Path $dataDir 'providers.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    $sourceConfig = if (Test-Path -LiteralPath $legacyConfig) { $legacyConfig } else { Join-Path $sourceRoot 'config\providers.example.json' }
    Copy-Item -LiteralPath $sourceConfig -Destination $configPath
    Write-Host "Initialized provider configuration: $configPath"
} else {
    Write-Host "Preserved provider configuration: $configPath"
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\providers.example.json') -Destination (Join-Path $dataDir 'providers.example.json') -Force

$transactionId = [Guid]::NewGuid().ToString('N')
$stagingDir = Join-Path $appRoot "app.staging.$transactionId"
$backupDir = Join-Path $appRoot "app.backup.$transactionId"
$extensionStaging = Join-Path (Split-Path -Parent $extensionDir) "byok-cli-hub-copilot.staging.$transactionId"
$extensionBackup = Join-Path (Split-Path -Parent $extensionDir) "byok-cli-hub-copilot.backup.$transactionId"
$appSwitched = $false
$extensionSwitched = $false

try {
    New-Item -ItemType Directory -Path $stagingDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'manager') -Destination $stagingDir -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config') -Destination $stagingDir -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'extension') -Destination $stagingDir -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run.cmd') -Destination (Join-Path $stagingDir 'run.cmd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'byok-cli-hub.cmd') -Destination (Join-Path $stagingDir 'byok-cli-hub.cmd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.cmd') -Destination (Join-Path $stagingDir 'uninstall.cmd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination (Join-Path $stagingDir 'uninstall.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'README.md') -Destination (Join-Path $stagingDir 'README.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'package.json') -Destination (Join-Path $stagingDir 'package.json')

    $manifest = [ordered]@{
        schemaVersion = 1
        product = 'byok-cli-hub'
        installedAt = [DateTime]::UtcNow.ToString('o')
        installDir = $targetDir
        dataDir = $dataDir
        extensionDir = $extensionDir
        withExtension = [bool]$WithExtension
    }
    [IO.File]::WriteAllText((Join-Path $stagingDir $manifestName), (($manifest | ConvertTo-Json -Depth 5) + "`n"), (New-Object Text.UTF8Encoding $false))

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stagingDir 'manager\smoke-test.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Staged PowerShell smoke test failed.' }

    if ($WithExtension) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $extensionDir) | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'extension') -Destination $extensionStaging -Recurse
        New-Item -ItemType File -Path (Join-Path $extensionStaging $markerName) | Out-Null
    }

    if (Test-Path -LiteralPath $targetDir) { Move-Item -LiteralPath $targetDir -Destination $backupDir }
    Move-Item -LiteralPath $stagingDir -Destination $targetDir
    $appSwitched = $true

    if ($WithExtension) {
        if (Test-Path -LiteralPath $extensionDir) { Move-Item -LiteralPath $extensionDir -Destination $extensionBackup }
        Move-Item -LiteralPath $extensionStaging -Destination $extensionDir
        $extensionSwitched = $true
    }

    $pathScript = Join-Path $targetDir 'manager\update-user-path.ps1'
    $shouldSkipPath = $SkipPathUpdate -or $env:BYOK_CLI_HUB_SKIP_PATH_UPDATE -eq '1'
    if (-not $shouldSkipPath) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pathScript -Directory $dataDir -Remove
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pathScript -Directory $targetDir
        if ($LASTEXITCODE -ne 0) { throw 'User PATH update failed.' }
    }

    Remove-Item -LiteralPath $backupDir, $extensionBackup -Recurse -Force -ErrorAction SilentlyContinue
    $appSwitched = $false
    $extensionSwitched = $false
} catch {
    if ($extensionSwitched) {
        Remove-Item -LiteralPath $extensionDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $extensionBackup) { Move-Item -LiteralPath $extensionBackup -Destination $extensionDir }
    }
    if ($appSwitched) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $backupDir) { Move-Item -LiteralPath $backupDir -Destination $targetDir }
    }
    throw
} finally {
    Remove-Item -LiteralPath $stagingDir, $extensionStaging -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Installation complete.' -ForegroundColor Green
Write-Host "Application: $targetDir"
Write-Host "Data:        $dataDir"
if ($WithExtension) { Write-Host "Extension:   $extensionDir" }
Write-Host 'Open a new terminal, then run: byok-cli-hub'
