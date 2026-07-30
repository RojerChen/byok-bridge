#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedAppVersion = "$(Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'package.json') -Encoding UTF8 | ConvertFrom-Json | Select-Object -ExpandProperty version)"
$newerAppVersion = "$(([version]$expectedAppVersion).Major + 1).0.0"
$testRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('byok-win-installer-' + [Guid]::NewGuid().ToString('N'))))
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
if (-not $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root.' }
$installer = Join-Path $repoRoot 'bin\win\install.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-InstalledReadmeDocumentation([string]$ApplicationDir) {
    $readmePath = Join-Path $ApplicationDir 'README.md'
    Assert-True (Test-Path -LiteralPath $readmePath) 'Installed README is missing.'
    $readme = Get-Content -Raw -LiteralPath $readmePath -Encoding UTF8
    $documentationLinks = [regex]::Matches($readme, '\]\((doc/[^)#]+)(?:#[^)]+)?\)')
    Assert-True ($documentationLinks.Count -gt 0) 'Installed README has no relative documentation links.'
    foreach ($link in $documentationLinks) {
        $relativePath = $link.Groups[1].Value.Replace('/', '\')
        Assert-True (Test-Path -LiteralPath (Join-Path $ApplicationDir $relativePath)) "Installed README link does not resolve: $($link.Groups[1].Value)"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ApplicationDir 'doc\plan.md'))) 'Internal planning file was included in the application snapshot.'
    Assert-True (Test-Path -LiteralPath (Join-Path $ApplicationDir 'ui\theme.json')) 'Installed UI theme is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $ApplicationDir 'ui\messages\app.json')) 'Installed UI messages are missing.'
}

function Set-TestEnvironment([string]$CaseRoot) {
    $script:appRoot = Join-Path $CaseRoot 'app-root'
    $script:dataRoot = Join-Path $CaseRoot 'data'
    $script:copilotHome = Join-Path $CaseRoot 'copilot-home'
    $script:pathFile = Join-Path $CaseRoot 'user-path.txt'
    New-Item -ItemType Directory -Force -Path $CaseRoot | Out-Null
    [IO.File]::WriteAllText($script:pathFile, 'C:\ExistingTool', (New-Object Text.UTF8Encoding $false))
    $env:BYOK_CLI_HUB_INSTALL_ROOT = $script:appRoot
    $env:BYOK_CLI_HUB_DATA_DIR = $script:dataRoot
    $env:COPILOT_HOME = $script:copilotHome
    $env:BYOK_CLI_HUB_TEST_USER_PATH_FILE = $script:pathFile
    Remove-Item Env:\BYOK_CLI_HUB_TEST_FAIL_AT -ErrorAction SilentlyContinue
}

function Get-TestPathEntries {
    return @(([IO.File]::ReadAllText($script:pathFile, [Text.Encoding]::UTF8) -split ';') | Where-Object { $_ })
}

function New-Legacy001Fixture([string]$CaseRoot, [switch]$InvalidConfig, [switch]$MalformedConfig) {
    Set-TestEnvironment $CaseRoot
    New-Item -ItemType Directory -Force -Path (Join-Path $script:dataRoot 'manager'), (Join-Path $script:dataRoot 'config') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'manager\start-byok-cli-hub.ps1') -Destination (Join-Path $script:dataRoot 'manager\start-byok-cli-hub.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'manager\ByokManager.psm1') -Destination (Join-Path $script:dataRoot 'manager\ByokManager.psm1')
    Set-Content -LiteralPath (Join-Path $script:dataRoot 'run.cmd') -Value '@echo legacy-run' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $script:dataRoot 'byok-cli-hub.cmd') -Value '@echo legacy-launcher' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $script:dataRoot 'README.md') -Value 'legacy-readme' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:dataRoot 'package.json') -Value '{"version":"0.0.1"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:dataRoot 'unknown-user-file.txt') -Value 'preserve-me' -Encoding UTF8
    if ($MalformedConfig) {
        Set-Content -LiteralPath (Join-Path $script:dataRoot 'config\providers.json') -Value '{malformed-json' -Encoding UTF8
    } elseif ($InvalidConfig) {
        Set-Content -LiteralPath (Join-Path $script:dataRoot 'config\providers.json') -Value '{"version":1,"providers":{}}' -Encoding UTF8
    } else {
        Copy-Item -LiteralPath (Join-Path $repoRoot 'config\providers.example.json') -Destination (Join-Path $script:dataRoot 'config\providers.json')
    }
    [IO.File]::WriteAllText((Join-Path $script:dataRoot 'state.json'), '{"providerId":"legacy","model":"legacy-model"}', (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $script:dataRoot 'models-cache.json'), '{"version":1,"caches":{}}', (New-Object Text.UTF8Encoding $false))
    New-Item -ItemType Directory -Force -Path (Join-Path $script:copilotHome 'extensions') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'extension') -Destination (Join-Path $script:copilotHome 'extensions\byok-cli-hub-copilot') -Recurse
    [IO.File]::WriteAllText($script:pathFile, "$script:dataRoot;C:\ExistingTool", (New-Object Text.UTF8Encoding $false))
}

try {
    # Fresh install, managed update, failure injection, uninstall, and purge.
    Set-TestEnvironment (Join-Path $testRoot 'fresh-rollback')
    $env:BYOK_CLI_HUB_TEST_FAIL_AT = 'after-app-backup'
    $failed = $false
    try { & $installer -WithExtension } catch { $failed = $true }
    Remove-Item Env:\BYOK_CLI_HUB_TEST_FAIL_AT -ErrorAction SilentlyContinue
    Assert-True $failed 'Injected fresh-install failure unexpectedly succeeded.'
    Assert-True (-not (Test-Path -LiteralPath $dataRoot)) 'Fresh-install rollback left initialized data behind.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'app'))) 'Fresh-install rollback left an application snapshot.'

    # A malformed existing canonical config must fail with the exact path and
    # remain byte-for-byte unchanged.
    Set-TestEnvironment (Join-Path $testRoot 'malformed-canonical')
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
    $malformedCanonicalPath = Join-Path $dataRoot 'providers.json'
    [IO.File]::WriteAllText($malformedCanonicalPath, '{"version":1,}', (New-Object Text.UTF8Encoding $false))
    $malformedBytes = [IO.File]::ReadAllBytes($malformedCanonicalPath)
    $failed = $false
    $failureMessage = ''
    try { & $installer } catch { $failed = $true; $failureMessage = $_.Exception.Message }
    Assert-True $failed 'Malformed canonical config was accepted.'
    Assert-True ($failureMessage.Contains($malformedCanonicalPath)) 'Malformed canonical config error omitted its path.'
    Assert-True ([Convert]::ToBase64String($malformedBytes) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($malformedCanonicalPath))) 'Malformed canonical config was modified.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'app'))) 'Malformed canonical config installed an application snapshot.'

    Set-TestEnvironment (Join-Path $testRoot 'fresh')
    & $installer -WithExtension
    $appDir = Join-Path $appRoot 'app'
    Assert-InstalledReadmeDocumentation $appDir
    & $installer
    Assert-InstalledReadmeDocumentation $appDir

    $extensionDir = Join-Path $copilotHome 'extensions\byok-cli-hub-copilot'
    $manifestPath = Join-Path $appDir '.byok-cli-hub-install.json'
    Assert-True (Test-Path -LiteralPath $manifestPath) 'Manifest missing.'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($manifest.appVersion -eq $expectedAppVersion) 'Manifest appVersion mismatch.'
    Assert-True ($manifest.withExtension -eq $true) 'Managed update did not preserve extension choice.'
    Assert-True (-not $manifest.migratedFrom) 'Fresh install must not report migratedFrom.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json')) 'Canonical config missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $extensionDir '.byok-cli-hub-managed')) 'Extension marker missing.'
    Assert-True ((Get-TestPathEntries) -contains $appDir) 'Application PATH entry missing.'

    $originalCopilotHome = $copilotHome
    $env:COPILOT_HOME = Join-Path (Split-Path -Parent $copilotHome) 'relocated-copilot-home'
    $failed = $false
    try { & $installer } catch { $failed = $true }
    $env:COPILOT_HOME = $originalCopilotHome
    Assert-True $failed 'Managed update unexpectedly relocated the extension directory.'
    Assert-True (Test-Path -LiteralPath (Join-Path $extensionDir '.byok-cli-hub-managed')) 'Relocation rejection damaged the managed extension.'

    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $newerManifest = $manifest
    $newerManifest.appVersion = $newerAppVersion
    [IO.File]::WriteAllText($manifestPath, (($newerManifest | ConvertTo-Json -Depth 10) + "`n"), (New-Object Text.UTF8Encoding $false))
    $failed = $false
    try { & $installer } catch { $failed = $true }
    Assert-True $failed 'Installer accepted a managed manifest from a newer version.'
    [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)

    foreach ($failurePoint in @('after-app-backup', 'after-extension-backup', 'installed-smoke', 'after-path-remove', 'before-backup-cleanup')) {
        Set-Content -LiteralPath (Join-Path $appDir 'rollback-sentinel.txt') -Value $failurePoint -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $extensionDir 'rollback-sentinel.txt') -Value $failurePoint -Encoding UTF8
        $examplePath = Join-Path $dataRoot 'providers.example.json'
        [IO.File]::WriteAllText($examplePath, "example=$failurePoint", (New-Object Text.UTF8Encoding $false))
        $pathBefore = [IO.File]::ReadAllText($pathFile, [Text.Encoding]::UTF8)
        $env:BYOK_CLI_HUB_TEST_FAIL_AT = $failurePoint
        $failed = $false
        try { & $installer } catch { $failed = $true }
        Remove-Item Env:\BYOK_CLI_HUB_TEST_FAIL_AT -ErrorAction SilentlyContinue
        Assert-True $failed "Failure point '$failurePoint' did not fail."
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $appDir 'rollback-sentinel.txt')).Trim() -eq $failurePoint) "Application rollback failed at '$failurePoint'."
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $extensionDir 'rollback-sentinel.txt')).Trim() -eq $failurePoint) "Extension rollback failed at '$failurePoint'."
        Assert-True ([IO.File]::ReadAllText($pathFile, [Text.Encoding]::UTF8) -eq $pathBefore) "PATH rollback failed at '$failurePoint'."
        Assert-True ([IO.File]::ReadAllText($examplePath, [Text.Encoding]::UTF8) -eq "example=$failurePoint") "Data example rollback failed at '$failurePoint'."
    }

    & (Join-Path $appDir 'uninstall.ps1')
    Assert-True (-not (Test-Path -LiteralPath $appDir)) 'Application was not removed.'
    Assert-True (-not (Test-Path -LiteralPath $extensionDir)) 'Managed extension was not removed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json')) 'Data was not preserved.'
    Assert-True ((Get-TestPathEntries) -notcontains $appDir) 'Application PATH entry was not removed.'

    & $installer
    & (Join-Path $appDir 'uninstall.ps1') -PurgeData -Yes
    Assert-True (-not (Test-Path -LiteralPath $dataRoot)) 'Confirmed data purge did not remove data.'

    # A failed legacy migration must restore its launcher, extension, PATH, and data.
    New-Legacy001Fixture (Join-Path $testRoot 'legacy-rollback')
    $legacyPathBefore = [IO.File]::ReadAllText($pathFile, [Text.Encoding]::UTF8)
    $env:BYOK_CLI_HUB_TEST_FAIL_AT = 'after-path-remove'
    $failed = $false
    try { & $installer } catch { $failed = $true }
    Remove-Item Env:\BYOK_CLI_HUB_TEST_FAIL_AT -ErrorAction SilentlyContinue
    Assert-True $failed 'Legacy migration failure injection did not fail.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'manager')) 'Legacy manager was not restored after rollback.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'byok-cli-hub.cmd')) 'Legacy launcher was not restored after rollback.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json'))) 'Rolled-back migration left canonical config behind.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'app'))) 'Rolled-back migration left a new application snapshot.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $copilotHome 'extensions\byok-cli-hub-copilot\.byok-cli-hub-managed'))) 'Rolled-back migration claimed the legacy extension.'
    Assert-True ([IO.File]::ReadAllText($pathFile, [Text.Encoding]::UTF8) -eq $legacyPathBefore) 'Legacy PATH was not restored after rollback.'

    # A failure during the legacy move loop must restore items already moved.
    New-Legacy001Fixture (Join-Path $testRoot 'legacy-mid-move-rollback')
    $env:BYOK_CLI_HUB_TEST_FAIL_AT = 'after-legacy-move-run.cmd'
    $failed = $false
    try { & $installer } catch { $failed = $true }
    Remove-Item Env:\BYOK_CLI_HUB_TEST_FAIL_AT -ErrorAction SilentlyContinue
    Assert-True $failed 'Mid-move legacy failure injection did not fail.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'manager')) 'Mid-move rollback did not restore the legacy manager.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'run.cmd')) 'Mid-move rollback did not restore run.cmd.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'byok-cli-hub.cmd')) 'Mid-move rollback damaged an unmoved legacy launcher.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json'))) 'Mid-move rollback left canonical config behind.'

    # Public 0.0.1 Windows layout migration.
    New-Legacy001Fixture (Join-Path $testRoot 'legacy')
    $legacyState = [IO.File]::ReadAllBytes((Join-Path $dataRoot 'state.json'))
    $legacyCache = [IO.File]::ReadAllBytes((Join-Path $dataRoot 'models-cache.json'))
    & $installer
    $appDir = Join-Path $appRoot 'app'
    Assert-InstalledReadmeDocumentation $appDir
    $extensionDir = Join-Path $copilotHome 'extensions\byok-cli-hub-copilot'
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $appDir '.byok-cli-hub-install.json') -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($manifest.appVersion -eq $expectedAppVersion -and $manifest.migratedFrom -eq '0.0.1') 'Legacy migration metadata is incorrect.'
    Assert-True ($manifest.withExtension -eq $true) 'Legacy extension choice was not preserved.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json')) 'Legacy config was not migrated.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'config\providers.json')) 'Legacy config backup was not preserved.'
    Assert-True ([Convert]::ToBase64String($legacyState) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataRoot 'state.json')))) 'Legacy state changed during migration.'
    Assert-True ([Convert]::ToBase64String($legacyCache) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataRoot 'models-cache.json')))) 'Legacy cache changed during migration.'
    foreach ($legacyName in @('manager', 'run.cmd', 'byok-cli-hub.cmd', 'README.md', 'package.json')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataRoot $legacyName))) "Legacy application item was not cleaned: $legacyName"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'unknown-user-file.txt')) 'Unknown user file was removed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $extensionDir '.byok-cli-hub-managed')) 'Legacy extension was not adopted.'
    $entries = Get-TestPathEntries
    Assert-True ($entries -notcontains $dataRoot) 'Legacy PATH entry was not removed.'
    Assert-True ($entries -contains $appDir) 'New PATH entry was not added.'

    # Structurally invalid legacy config must not be migrated or partially installed.
    New-Legacy001Fixture (Join-Path $testRoot 'invalid-legacy') -InvalidConfig
    $failed = $false
    try { & $installer } catch { $failed = $true }
    Assert-True $failed 'Invalid legacy config was accepted.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json'))) 'Invalid legacy config created a canonical file.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'manager')) 'Invalid migration modified legacy application files.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'app'))) 'Invalid migration installed an application snapshot.'

    # Malformed legacy JSON must fail before creating canonical data.
    New-Legacy001Fixture (Join-Path $testRoot 'malformed-legacy') -MalformedConfig
    $failed = $false
    try { & $installer } catch { $failed = $true }
    Assert-True $failed 'Malformed legacy JSON was accepted.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json'))) 'Malformed legacy JSON created a canonical file.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'manager')) 'Malformed migration modified legacy application files.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'app'))) 'Malformed migration installed an application snapshot.'

    # Unknown legacy extension content is preserved without taking ownership.
    New-Legacy001Fixture (Join-Path $testRoot 'unknown-extension')
    $unknownExtensionDir = Join-Path $copilotHome 'extensions\byok-cli-hub-copilot'
    Remove-Item -LiteralPath (Join-Path $unknownExtensionDir 'package.json') -Force
    Set-Content -LiteralPath (Join-Path $unknownExtensionDir 'unknown-owner.txt') -Value 'preserve-me' -Encoding UTF8
    & $installer
    $appDir = Join-Path $appRoot 'app'
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $appDir '.byok-cli-hub-install.json') -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($manifest.withExtension -eq $false) 'Unknown extension was recorded as managed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $unknownExtensionDir 'unknown-owner.txt')) 'Unknown extension content was removed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unknownExtensionDir '.byok-cli-hub-managed'))) 'Unknown extension received a managed marker.'

    Write-Host 'Windows fresh/update/rollback/0.0.1 migration/ownership/uninstaller tests passed.' -ForegroundColor Green
} finally {
    foreach ($name in @('BYOK_CLI_HUB_INSTALL_ROOT','BYOK_CLI_HUB_DATA_DIR','COPILOT_HOME','BYOK_CLI_HUB_TEST_USER_PATH_FILE','BYOK_CLI_HUB_TEST_FAIL_AT')) {
        Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }
    if ((Test-Path -LiteralPath $testRoot) -and $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
