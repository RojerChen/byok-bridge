#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('byok-win-installer-' + [Guid]::NewGuid().ToString('N'))))
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
if (-not $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root.' }

$appRoot = Join-Path $testRoot 'app-root'
$dataRoot = Join-Path $testRoot 'data'
try {
    $env:BYOK_CLI_HUB_INSTALL_ROOT = $appRoot
    $env:BYOK_CLI_HUB_DATA_DIR = $dataRoot
    $installer = Join-Path $repoRoot 'bin\win\install.ps1'
    & $installer -SkipPathUpdate
    & $installer -SkipPathUpdate

    $appDir = Join-Path $appRoot 'app'
    if (-not (Test-Path -LiteralPath (Join-Path $appDir '.byok-cli-hub-install.json'))) { throw 'Manifest missing.' }
    if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json'))) { throw 'Canonical config missing.' }
    if (-not (Test-Path -LiteralPath (Join-Path $dataRoot '.byok-cli-hub-data'))) { throw 'Data ownership marker missing.' }

    & (Join-Path $appDir 'uninstall.ps1')
    if (Test-Path -LiteralPath $appDir) { throw 'Application was not removed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'providers.json'))) { throw 'Data was not preserved.' }

    & $installer -SkipPathUpdate
    & (Join-Path $appDir 'uninstall.ps1') -PurgeData -Yes
    if (Test-Path -LiteralPath $dataRoot) { throw 'Confirmed data purge did not remove data.' }
    Write-Host 'Windows installer/update/uninstaller test passed.' -ForegroundColor Green
} finally {
    Remove-Item Env:\BYOK_CLI_HUB_INSTALL_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\BYOK_CLI_HUB_DATA_DIR -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath $testRoot) -and $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
