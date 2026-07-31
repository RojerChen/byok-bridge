#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [switch]$Remove,
    [string]$PathValueFile = $env:BYOK_BRIDGE_TEST_USER_PATH_FILE
)

$ErrorActionPreference = 'Stop'

function Get-NormalizedPathEntry {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $trimmed = $Value.Trim().Trim('"')
    try {
        return [System.IO.Path]::GetFullPath($trimmed).TrimEnd([char[]]'\/')
    } catch {
        return $trimmed.TrimEnd([char[]]'\/')
    }
}

function Send-EnvironmentChangedNotification {
    if ($PathValueFile) { return }
    try {
        if (-not ('ByokBridge.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ByokBridge {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result);
    }
}
'@
        }

        $result = [UIntPtr]::Zero
        [void][ByokBridge.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff,
            0x001a,
            [UIntPtr]::Zero,
            'Environment',
            0x0002,
            5000,
            [ref]$result)
    } catch {
        Write-Warning 'PATH was updated, but Windows could not be notified. Open a new terminal before using the command.'
    }
}

function Get-UserPathValue {
    if ($PathValueFile) {
        if (Test-Path -LiteralPath $PathValueFile) {
            return [IO.File]::ReadAllText([IO.Path]::GetFullPath($PathValueFile), [Text.Encoding]::UTF8)
        }
        return ''
    }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserPathValue([string]$Value) {
    if ($PathValueFile) {
        $full = [IO.Path]::GetFullPath($PathValueFile)
        $parent = Split-Path -Parent $full
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        [IO.File]::WriteAllText($full, $Value, (New-Object Text.UTF8Encoding $false))
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

$target = Get-NormalizedPathEntry $Directory
if (-not $target) { throw 'A non-empty directory is required.' }

$current = Get-UserPathValue
$entries = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$matching = @($entries | Where-Object {
    (Get-NormalizedPathEntry $_).Equals($target, [StringComparison]::OrdinalIgnoreCase)
})

if ($Remove) {
    if ($matching.Count -eq 0) {
        Write-Host "User PATH does not contain: $target"
        return
    }
    $updatedEntries = @($entries | Where-Object {
        -not (Get-NormalizedPathEntry $_).Equals($target, [StringComparison]::OrdinalIgnoreCase)
    })
    $action = 'Remove directory from the user PATH'
} else {
    if ($matching.Count -gt 0) {
        Write-Host "User PATH already contains: $target"
        return
    }
    $updatedEntries = @($entries) + $target
    $action = 'Add directory to the user PATH'
}

if ($PSCmdlet.ShouldProcess($target, $action)) {
    Set-UserPathValue ($updatedEntries -join ';')
    Send-EnvironmentChangedNotification
    if ($Remove) { Write-Host "Removed from user PATH: $target" }
    else { Write-Host "Added to user PATH: $target" }
}
