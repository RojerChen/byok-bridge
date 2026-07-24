#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$WithExtension,
    [switch]$AdoptLegacy,
    [switch]$SkipPathUpdate
)

$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sourcePackage = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'package.json') -Encoding UTF8 | ConvertFrom-Json
$appVersion = "$($sourcePackage.version)"
if ($appVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Source package version must use numeric major.minor.patch format.' }
$sourceSemanticVersion = [version]$appVersion

$appRoot = if ($env:BYOK_CLI_HUB_INSTALL_ROOT) { [IO.Path]::GetFullPath($env:BYOK_CLI_HUB_INSTALL_ROOT) } else { Join-Path $env:LOCALAPPDATA 'byok-cli-hub' }
$targetDir = [IO.Path]::GetFullPath((Join-Path $appRoot 'app'))
$dataDir = if ($env:BYOK_CLI_HUB_DATA_DIR) { [IO.Path]::GetFullPath($env:BYOK_CLI_HUB_DATA_DIR) } else { Join-Path $env:USERPROFILE '.byok-cli-hub' }
$copilotHome = if ($env:COPILOT_HOME) { [IO.Path]::GetFullPath($env:COPILOT_HOME) } else { Join-Path $env:USERPROFILE '.copilot' }
$extensionDir = [IO.Path]::GetFullPath((Join-Path $copilotHome 'extensions\byok-cli-hub-copilot'))
$manifestName = '.byok-cli-hub-install.json'
$markerName = '.byok-cli-hub-managed'
$dataMarkerName = '.byok-cli-hub-data'

function Test-SameOrChild([string]$Parent, [string]$Child) {
    $p = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $c = [IO.Path]::GetFullPath($Child).TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafePath([string]$Label, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label cannot be empty." }
    if ($Path.Contains("`r") -or $Path.Contains("`n")) { throw "$Label must not contain newlines." }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if (-not $full -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label resolves to a filesystem root: $full" }
    if ($full.Equals([IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw "$Label must not be the user profile." }
    if ($full.Equals($sourceRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw "$Label must not be the repository root." }
}

function Assert-NotOverlapping([string]$LeftLabel, [string]$Left, [string]$RightLabel, [string]$Right) {
    if ((Test-SameOrChild $Left $Right) -or (Test-SameOrChild $Right $Left)) {
        throw "$LeftLabel and $RightLabel must not overlap: '$Left' / '$Right'"
    }
}

function Resolve-ManifestPath([string]$Label, $Value) {
    $text = "$Value"
    if ([string]::IsNullOrWhiteSpace($text) -or -not [IO.Path]::IsPathRooted($text)) {
        throw "$Label in the install manifest must be an absolute path."
    }
    return [IO.Path]::GetFullPath($text)
}

function Invoke-FailurePoint([string]$Name) {
    if ($env:BYOK_CLI_HUB_TEST_FAIL_AT -and $env:BYOK_CLI_HUB_TEST_FAIL_AT -eq $Name) {
        throw "Injected installer failure at '$Name'."
    }
}

function Get-UserPathValue {
    $testFile = $env:BYOK_CLI_HUB_TEST_USER_PATH_FILE
    if ($testFile) {
        if (Test-Path -LiteralPath $testFile) { return [IO.File]::ReadAllText([IO.Path]::GetFullPath($testFile), [Text.Encoding]::UTF8) }
        return ''
    }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Restore-UserPathValue([string]$Value, [bool]$TestFileExisted) {
    $testFile = $env:BYOK_CLI_HUB_TEST_USER_PATH_FILE
    if ($testFile) {
        $full = [IO.Path]::GetFullPath($testFile)
        if (-not $TestFileExisted) {
            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            return
        }
        [IO.File]::WriteAllText($full, $Value, (New-Object Text.UTF8Encoding $false))
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

function Test-RecognizableLegacyApplication([string]$Root) {
    return (Test-Path -LiteralPath (Join-Path $Root 'manager\start-byok-cli-hub.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Root 'manager\ByokManager.psm1')) -and
        (Test-Path -LiteralPath (Join-Path $Root 'run.cmd')) -and
        (Test-Path -LiteralPath (Join-Path $Root 'byok-cli-hub.cmd')) -and
        ((Test-Path -LiteralPath (Join-Path $Root 'config\providers.json')) -or (Test-Path -LiteralPath (Join-Path $Root 'providers.json')))
}

function Test-RecognizableLegacyExtension([string]$Path) {
    return (Test-Path -LiteralPath (Join-Path $Path 'extension.mjs')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'package.json'))
}

Assert-SafePath 'install root' $appRoot
Assert-SafePath 'application dir' $targetDir
Assert-SafePath 'data dir' $dataDir
Assert-SafePath 'extension dir' $extensionDir
Assert-NotOverlapping 'application dir' $targetDir 'data dir' $dataDir
Assert-NotOverlapping 'application dir' $targetDir 'extension dir' $extensionDir
Assert-NotOverlapping 'data dir' $dataDir 'extension dir' $extensionDir

$existingManifest = Join-Path $targetDir $manifestName
if (Test-Path -LiteralPath $existingManifest) {
    $previous = Get-Content -Raw -LiteralPath $existingManifest -Encoding UTF8 | ConvertFrom-Json
    if ($previous.product -ne 'byok-cli-hub' -or $previous.schemaVersion -ne 1) { throw 'The existing install manifest is invalid.' }
    $previousAppVersion = "$($previous.appVersion)"
    if ($previousAppVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'The existing install manifest has an invalid appVersion.' }
    if ([version]$previousAppVersion -gt $sourceSemanticVersion) { throw "Refusing to downgrade installed version $previousAppVersion to $appVersion." }
    $manifestInstallDir = Resolve-ManifestPath 'installDir' $previous.installDir
    $manifestDataDir = Resolve-ManifestPath 'dataDir' $previous.dataDir
    $manifestExtensionDir = Resolve-ManifestPath 'extensionDir' $previous.extensionDir
    if (-not $manifestInstallDir.Equals($targetDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The existing install manifest does not own the target application directory.'
    }
    if ($previous.withExtension -isnot [bool]) { throw 'The existing install manifest has an invalid withExtension value.' }
    Assert-SafePath 'manifest data dir' $manifestDataDir
    Assert-SafePath 'manifest extension dir' $manifestExtensionDir
    Assert-NotOverlapping 'application dir' $targetDir 'manifest data dir' $manifestDataDir
    Assert-NotOverlapping 'application dir' $targetDir 'manifest extension dir' $manifestExtensionDir
    Assert-NotOverlapping 'manifest data dir' $manifestDataDir 'manifest extension dir' $manifestExtensionDir
    if (-not $env:BYOK_CLI_HUB_DATA_DIR) { $dataDir = $manifestDataDir }
    if (-not $env:COPILOT_HOME) { $extensionDir = $manifestExtensionDir }
    if ($previous.withExtension) { $WithExtension = $true }
    Assert-SafePath 'data dir' $dataDir
    Assert-SafePath 'extension dir' $extensionDir
    Assert-NotOverlapping 'application dir' $targetDir 'data dir' $dataDir
    Assert-NotOverlapping 'application dir' $targetDir 'extension dir' $extensionDir
    Assert-NotOverlapping 'data dir' $dataDir 'extension dir' $extensionDir
}
if ((Test-Path -LiteralPath $targetDir) -and -not (Test-Path -LiteralPath $existingManifest)) {
    throw "Refusing to replace unowned application directory '$targetDir'."
}

$legacySignals = @('manager', 'run.cmd', 'byok-cli-hub.cmd') | Where-Object { Test-Path -LiteralPath (Join-Path $dataDir $_) }
$legacyRecognized = Test-RecognizableLegacyApplication $dataDir
if ($legacySignals.Count -gt 0 -and -not $legacyRecognized) {
    throw "Existing content in '$dataDir' resembles an incomplete or unknown legacy installation. Refusing automatic migration."
}
$isLegacyMigration = [bool]$legacyRecognized

$extensionExists = Test-Path -LiteralPath $extensionDir
$extensionManaged = $extensionExists -and (Test-Path -LiteralPath (Join-Path $extensionDir $markerName))
$legacyExtensionRecognized = $extensionExists -and -not $extensionManaged -and (Test-RecognizableLegacyExtension $extensionDir)
if ($isLegacyMigration -and $legacyExtensionRecognized) {
    $WithExtension = $true
} elseif ($WithExtension -and $extensionExists -and -not $extensionManaged) {
    if (-not ($AdoptLegacy -and $legacyExtensionRecognized)) {
        throw "Refusing to replace unowned extension '$extensionDir'. Use -AdoptLegacy only for a verified legacy install."
    }
} elseif ($extensionExists -and -not $extensionManaged) {
    Write-Warning "Preserving unowned extension '$extensionDir'; it will not be recorded in the install manifest."
}

New-Item -ItemType Directory -Force -Path $appRoot, $dataDir | Out-Null

# Validate the config before creating or replacing the canonical path.
Import-Module (Join-Path $sourceRoot 'manager\ByokManager.psm1') -DisableNameChecking -Force -ErrorAction Stop
$legacyConfig = Join-Path $dataDir 'config\providers.json'
$configPath = Join-Path $dataDir 'providers.json'
$createdCanonicalConfig = $false
if (Test-Path -LiteralPath $configPath) {
    $configValue = Get-Content -Raw -LiteralPath $configPath -Encoding UTF8 | ConvertFrom-Json
    Assert-ByokProviderConfig $configValue | Out-Null
} else {
    $sourceConfig = if (Test-Path -LiteralPath $legacyConfig) { $legacyConfig } else { Join-Path $sourceRoot 'config\providers.example.json' }
    try {
        $configValue = Get-Content -Raw -LiteralPath $sourceConfig -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Invalid provider configuration '$sourceConfig': $($_.Exception.Message)"
    }
    Assert-ByokProviderConfig $configValue | Out-Null
    Write-ByokJsonAtomic $configPath $configValue
    $createdCanonicalConfig = $true
    Write-Host "Initialized provider configuration: $configPath"
}

$transactionId = [Guid]::NewGuid().ToString('N')
$stagingDir = Join-Path $appRoot "app.staging.$transactionId"
$backupDir = Join-Path $appRoot "app.backup.$transactionId"
$extensionStaging = Join-Path (Split-Path -Parent $extensionDir) "byok-cli-hub-copilot.staging.$transactionId"
$extensionBackup = Join-Path (Split-Path -Parent $extensionDir) "byok-cli-hub-copilot.backup.$transactionId"
$legacyBackup = Join-Path $appRoot "legacy-0.0.1.backup.$transactionId"
$dataMarkerPath = Join-Path $dataDir $dataMarkerName
$createdDataMarker = $false
$appBackupCreated = $false
$appInstalled = $false
$extensionBackupCreated = $false
$extensionInstalled = $false
$legacyFilesMoved = $false
$pathTouched = $false
$originalUserPath = Get-UserPathValue
$testPathFileExisted = [bool]($env:BYOK_CLI_HUB_TEST_USER_PATH_FILE -and (Test-Path -LiteralPath $env:BYOK_CLI_HUB_TEST_USER_PATH_FILE))

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
        appVersion = $appVersion
        installedAt = [DateTime]::UtcNow.ToString('o')
        installDir = $targetDir
        dataDir = $dataDir
        extensionDir = $extensionDir
        withExtension = [bool]$WithExtension
        migratedFrom = if ($isLegacyMigration) { '0.0.1' } else { $null }
    }
    [IO.File]::WriteAllText((Join-Path $stagingDir $manifestName), (($manifest | ConvertTo-Json -Depth 5) + "`n"), (New-Object Text.UTF8Encoding $false))

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stagingDir 'manager\smoke-test.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Staged PowerShell smoke test failed.' }

    if ($WithExtension) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $extensionDir) | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'extension') -Destination $extensionStaging -Recurse
        New-Item -ItemType File -Path (Join-Path $extensionStaging $markerName) | Out-Null
    }

    if (Test-Path -LiteralPath $targetDir) {
        Move-Item -LiteralPath $targetDir -Destination $backupDir
        $appBackupCreated = $true
    }
    Invoke-FailurePoint 'after-app-backup'
    Move-Item -LiteralPath $stagingDir -Destination $targetDir
    $appInstalled = $true

    if ($WithExtension) {
        if (Test-Path -LiteralPath $extensionDir) {
            Move-Item -LiteralPath $extensionDir -Destination $extensionBackup
            $extensionBackupCreated = $true
        }
        Invoke-FailurePoint 'after-extension-backup'
        Move-Item -LiteralPath $extensionStaging -Destination $extensionDir
        $extensionInstalled = $true
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $targetDir 'manager\smoke-test.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Installed PowerShell smoke test failed.' }
    Invoke-FailurePoint 'installed-smoke'

    if ($isLegacyMigration) {
        New-Item -ItemType Directory -Path $legacyBackup | Out-Null
        foreach ($name in @('manager', 'run.cmd', 'byok-cli-hub.cmd', 'README.md', 'package.json')) {
            $legacyPath = Join-Path $dataDir $name
            if (Test-Path -LiteralPath $legacyPath) { Move-Item -LiteralPath $legacyPath -Destination (Join-Path $legacyBackup $name) }
        }
        $legacyFilesMoved = $true
    }

    $pathScript = Join-Path $targetDir 'manager\update-user-path.ps1'
    $shouldSkipPath = $SkipPathUpdate -or $env:BYOK_CLI_HUB_SKIP_PATH_UPDATE -eq '1'
    if (-not $shouldSkipPath) {
        $pathTouched = $true
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pathScript -Directory $dataDir -Remove
        if ($LASTEXITCODE -ne 0) { throw 'Legacy user PATH removal failed.' }
        Invoke-FailurePoint 'after-path-remove'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pathScript -Directory $targetDir
        if ($LASTEXITCODE -ne 0) { throw 'User PATH update failed.' }
    }

    if (-not (Test-Path -LiteralPath $dataMarkerPath)) {
        New-Item -ItemType File -Path $dataMarkerPath | Out-Null
        $createdDataMarker = $true
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\providers.example.json') -Destination (Join-Path $dataDir 'providers.example.json') -Force

    Invoke-FailurePoint 'before-backup-cleanup'
    Remove-Item -LiteralPath $backupDir, $extensionBackup, $legacyBackup -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    $failure = $_
    if ($pathTouched) {
        try { Restore-UserPathValue $originalUserPath $testPathFileExisted } catch { Write-Warning "Failed to restore user PATH: $($_.Exception.Message)" }
    }
    if ($legacyFilesMoved -and (Test-Path -LiteralPath $legacyBackup)) {
        foreach ($item in Get-ChildItem -LiteralPath $legacyBackup -Force) {
            $restorePath = Join-Path $dataDir $item.Name
            if (-not (Test-Path -LiteralPath $restorePath)) { Move-Item -LiteralPath $item.FullName -Destination $restorePath }
        }
    }
    if ($extensionInstalled -and (Test-Path -LiteralPath $extensionDir)) {
        Remove-Item -LiteralPath $extensionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($extensionBackupCreated -and (Test-Path -LiteralPath $extensionBackup)) {
        Move-Item -LiteralPath $extensionBackup -Destination $extensionDir
    }
    if ($appInstalled -and (Test-Path -LiteralPath $targetDir)) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($appBackupCreated -and (Test-Path -LiteralPath $backupDir)) {
        Move-Item -LiteralPath $backupDir -Destination $targetDir
    }
    if ($createdDataMarker) { Remove-Item -LiteralPath $dataMarkerPath -Force -ErrorAction SilentlyContinue }
    if ($createdCanonicalConfig) { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
    throw $failure
} finally {
    Remove-Item -LiteralPath $stagingDir, $extensionStaging, $legacyBackup -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Installation complete.' -ForegroundColor Green
Write-Host "Version:     $appVersion"
Write-Host "Application: $targetDir"
Write-Host "Data:        $dataDir"
if ($WithExtension) { Write-Host "Extension:   $extensionDir" }
if ($isLegacyMigration) { Write-Host 'Migrated Windows installation from version 0.0.1.' }
Write-Host 'Open a new terminal, then run: byok-cli-hub'
