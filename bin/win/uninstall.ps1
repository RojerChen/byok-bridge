#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$PurgeData,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$appRoot = if ($env:BYOK_CLI_HUB_INSTALL_ROOT) { [IO.Path]::GetFullPath($env:BYOK_CLI_HUB_INSTALL_ROOT) } else { Join-Path $env:LOCALAPPDATA 'byok-cli-hub' }
$targetDir = Join-Path $appRoot 'app'
$manifestPath = Join-Path $targetDir '.byok-cli-hub-install.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No managed BYOK CLI Hub install was found at '$targetDir'." }

$manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
if ($manifest.product -ne 'byok-cli-hub' -or $manifest.schemaVersion -ne 1) { throw 'The install manifest is invalid.' }
if (-not ([IO.Path]::GetFullPath($manifest.installDir).Equals([IO.Path]::GetFullPath($targetDir), [StringComparison]::OrdinalIgnoreCase))) {
    throw 'The install manifest does not own the requested application path.'
}

$pathScript = Join-Path $targetDir 'manager\update-user-path.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pathScript -Directory $targetDir -Remove

if ($manifest.withExtension -and (Test-Path -LiteralPath $manifest.extensionDir)) {
    $marker = Join-Path $manifest.extensionDir '.byok-cli-hub-managed'
    if (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $manifest.extensionDir -Recurse -Force
        Write-Host "Removed managed extension: $($manifest.extensionDir)"
    } else {
        Write-Warning "Preserved unowned extension: $($manifest.extensionDir)"
    }
}

$dataDir = [IO.Path]::GetFullPath($manifest.dataDir)
Remove-Item -LiteralPath $targetDir -Recurse -Force
if ((Test-Path -LiteralPath $appRoot) -and -not (Get-ChildItem -LiteralPath $appRoot -Force)) {
    Remove-Item -LiteralPath $appRoot -Force
}
Write-Host "Removed application: $targetDir"

if ($PurgeData -and (Test-Path -LiteralPath $dataDir)) {
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir '.byok-cli-hub-data'))) {
        throw "Data directory has no BYOK CLI Hub ownership marker; refusing purge: $dataDir"
    }
    $confirmed = [bool]$Yes
    if (-not $confirmed) {
        $answer = Read-Host "Type 'yes' to delete user data '$dataDir'"
        $confirmed = $answer -ceq 'yes'
    }
    if ($confirmed) {
        $protectedPaths = @($env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ }
        $candidate = $dataDir.TrimEnd('\') + '\'
        foreach ($protected in $protectedPaths) {
            $protectedFull = [IO.Path]::GetFullPath($protected).TrimEnd('\') + '\'
            if ($candidate.Equals($protectedFull, [StringComparison]::OrdinalIgnoreCase) -or $protectedFull.StartsWith($candidate, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to purge protected path: $dataDir"
            }
        }
        Remove-Item -LiteralPath $dataDir -Recurse -Force
        Write-Host "Purged user data: $dataDir"
    } else {
        Write-Host "Preserved user data: $dataDir"
    }
} else {
    Write-Host "Preserved user data: $dataDir"
}
