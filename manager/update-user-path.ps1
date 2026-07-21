#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [switch]$Remove
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
    try {
        if (-not ('ByokCliHub.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ByokCliHub {
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
        [void][ByokCliHub.NativeMethods]::SendMessageTimeout(
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

$target = Get-NormalizedPathEntry $Directory
if (-not $target) { throw 'A non-empty directory is required.' }

$current = [Environment]::GetEnvironmentVariable('Path', 'User')
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
    [Environment]::SetEnvironmentVariable('Path', ($updatedEntries -join ';'), 'User')
    Send-EnvironmentChangedNotification
    if ($Remove) { Write-Host "Removed from user PATH: $target" }
    else { Write-Host "Added to user PATH: $target" }
}
