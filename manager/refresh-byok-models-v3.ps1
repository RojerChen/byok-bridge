#requires -Version 5.1
<#
    refresh-byok-models-v3.ps1 — re-fetch models for a provider and refresh the cache.
    Does NOT touch the current session env or launch a CLI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$Provider,
    [string]$BaseUrl,
    [string]$ApiKey,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ByokManager.psm1') -ErrorAction Stop

$dataDir = Get-ByokDataDir
$cfg = Load-ByokProviderConfig $dataDir
$providers = @($cfg.providers)
if ($providers.Count -eq 0) { Write-Host 'No enabled providers were found.'; exit 1 }

$targets = if ($All) { $providers } elseif ($Provider) { @($providers | Where-Object { $_.id -eq $Provider }) } else { @($providers[0]) }
if (-not $targets -or $targets.Count -eq 0) { Write-Host "Unknown provider: $Provider"; exit 1 }

foreach ($p in $targets) {
    $base = if ($BaseUrl) { $BaseUrl }
            elseif ($p.baseUrl) { $p.baseUrl }
            else { Write-Host "No base URL for $($p.id)."; continue }
    $base = $base.Trim().TrimEnd('/')
    $key = if ($ApiKey) { $ApiKey } else { (Resolve-ByokEnvValue $(if ($p.apiKeyEnvNames) { $p.apiKeyEnvNames } else { $p.apiKeyEnv })) }
    $apiPath = if ($p.modelsApi -and $p.modelsApi.path) { $p.modelsApi.path } else { '/models' }
    try {
        Write-Host "Refreshing $($p.id) from $base..."
        $ids = @(Invoke-ByokModelFetch $p $base $key)
        if ($ids.Count -eq 0) { Write-Host "  No models returned for $($p.id)."; continue }
        Update-ByokCacheForProvider $p.id $base $apiPath $ids $dataDir | Out-Null
        Write-Host "  Saved $($ids.Count) models."
    } catch {
        Write-Host "  Failed: $($_.Exception.Message)"
    }
}
