#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$PurgeData,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$appRoot = if ($env:BYOK_BRIDGE_INSTALL_ROOT) { [IO.Path]::GetFullPath($env:BYOK_BRIDGE_INSTALL_ROOT) } else { Join-Path $env:LOCALAPPDATA 'byok-bridge' }
$targetDir = [IO.Path]::GetFullPath((Join-Path $appRoot 'app'))

function Test-SameOrChild([string]$Parent, [string]$Child) {
    $p = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $c = [IO.Path]::GetFullPath($Child).TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafePath([string]$Label, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label cannot be empty." }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if (-not $full -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label resolves to a filesystem root: $full" }
    if ($full.Equals([IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw "$Label must not be the user profile." }
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

Assert-SafePath 'install root' $appRoot
Assert-SafePath 'application dir' $targetDir
$manifestPath = Join-Path $targetDir '.byok-bridge-install.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No managed BYOK Bridge install was found at '$targetDir'." }

$manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
if ($manifest.product -ne 'byok-bridge' -or $manifest.schemaVersion -ne 1 -or "$($manifest.appVersion)" -notmatch '^\d+\.\d+\.\d+$' -or $manifest.withExtension -isnot [bool]) { throw 'The install manifest is invalid.' }
$manifestInstallDir = Resolve-ManifestPath 'installDir' $manifest.installDir
if (-not $manifestInstallDir.Equals([IO.Path]::GetFullPath($targetDir), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The install manifest does not own the requested application path.'
}

$dataDir = Resolve-ManifestPath 'dataDir' $manifest.dataDir
$extensionDir = Resolve-ManifestPath 'extensionDir' $manifest.extensionDir
Assert-SafePath 'data dir' $dataDir
Assert-SafePath 'extension dir' $extensionDir
Assert-NotOverlapping 'application dir' $targetDir 'data dir' $dataDir
Assert-NotOverlapping 'application dir' $targetDir 'extension dir' $extensionDir
Assert-NotOverlapping 'data dir' $dataDir 'extension dir' $extensionDir

$pathScript = Join-Path $targetDir 'manager\update-user-path.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pathScript -Directory $targetDir -Remove
if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the application directory from the user PATH.' }

if ($manifest.withExtension -and (Test-Path -LiteralPath $extensionDir)) {
    $marker = Join-Path $extensionDir '.byok-bridge-managed'
    if (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $extensionDir -Recurse -Force
        Write-Host "Removed managed extension: $extensionDir"
    } else {
        Write-Warning "Preserved unowned extension: $extensionDir"
    }
}

Remove-Item -LiteralPath $targetDir -Recurse -Force
if ((Test-Path -LiteralPath $appRoot) -and -not (Get-ChildItem -LiteralPath $appRoot -Force)) {
    Remove-Item -LiteralPath $appRoot -Force
}
Write-Host "Removed application: $targetDir"

if ($PurgeData -and (Test-Path -LiteralPath $dataDir)) {
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir '.byok-bridge-data'))) {
        throw "Data directory has no BYOK Bridge ownership marker; refusing purge: $dataDir"
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
