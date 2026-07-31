#requires -Version 5.1
<###
    Official BYOK Bridge manager entry point.
    The implementation is kept in start-copilot-byok.ps1; this forwarding
    entry point keeps the platform-neutral command name stable.
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
    [switch]$NoClear,
    [string]$EnvFile,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$LaunchArgs
)

$forward = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $forward[$entry.Key] = $entry.Value
}

$implementation = Join-Path $PSScriptRoot 'start-copilot-byok.ps1'
& $implementation @forward
exit $LASTEXITCODE
