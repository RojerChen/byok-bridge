#requires -Version 5.1
<###
    Official BYOK CLI Hub manager entry point.
    The implementation remains in the legacy-named script for compatibility;
    this forwarding entry point allows existing callers to migrate safely.
###>
[CmdletBinding()]
param(
    [string]$Provider,
    [string]$Cli,
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$Model,
    [switch]$DryRun,
    [switch]$Refresh,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$LaunchArgs
)

$forward = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $forward[$entry.Key] = $entry.Value
}

$legacy = Join-Path $PSScriptRoot 'start-copilot-byok-v3.ps1'
& $legacy @forward
exit $LASTEXITCODE
