#requires -Version 5.1
<#
    smoke-test.ps1 — deterministic verification of the BYOK v3 manager logic.
    No HTTP server: tests config load, cache merge, env-map templating, and
    state round-trip with synthetic inputs. The live fetch path is covered by
    running the real manager against a provider (see README / doc/summary.md).
    Uses an isolated BYOK_CLI_HUB_DATA_DIR so it never touches the real cache.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'ByokManager.psm1') -DisableNameChecking -ErrorAction Stop

$dataDir = Join-Path $env:TEMP "byok-v3-smoke-$PID"
if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'config') | Out-Null

try {
    $env:BYOK_CLI_HUB_DATA_DIR = $dataDir

    $providers = [ordered]@{
        version = 1
        clis = [ordered]@{
            'copilot' = [ordered]@{ name='GitHub Copilot CLI'; command='copilot'; args=@('--experimental'); modelEnvName='COPILOT_MODEL'; defaultApiKeyEnv=@('COPILOT_PROVIDER_API_KEY'); defaultModelEnvNames=@('COPILOT_MODEL'); settings=[ordered]@{ COPILOT_PROVIDER_BASE_URL='{url}'; COPILOT_PROVIDER_API_KEY='{api_key}'; COPILOT_PROVIDER_TYPE='openai'; COPILOT_MODEL='{model}'; BYOK_MODEL_PROVIDER_ID='{provider_id}' } }
            'gemini'  = [ordered]@{ name='Gemini CLI'; command='gemini'; args=@(); modelEnvName='GEMINI_MODEL'; defaultApiKeyEnv=@('GEMINI_API_KEY'); defaultModelEnvNames=@('GEMINI_MODEL'); settings=[ordered]@{ GEMINI_API_KEY='{api_key}'; GEMINI_MODEL='{model}' } }
        }
        providers = [ordered]@{
            'alpha' = [ordered]@{ name='Alpha'; enabled=$true; order=2; type='openai'; baseUrl='http://alpha/v1'; modelCacheTtlSeconds=3600; apiKeyEnv=@('ALPHA_KEY'); modelEnvNames=@('COPILOT_MODEL'); apiKeyHeader='Authorization'; apiKeyPrefix='Bearer '; modelsApi=[ordered]@{ path='/models'; itemsPath='data'; idPath='id' }; settings=[ordered]@{ COPILOT_PROVIDER_BASE_URL='{url}'; COPILOT_PROVIDER_API_KEY='{api_key}'; COPILOT_PROVIDER_TYPE='openai'; COPILOT_MODEL='{model}'; BYOK_MODEL_PROVIDER_ID='{provider_id}' } }
            'beta'  = [ordered]@{ name='Beta'; enabled=$false; order=1; baseUrl='http://beta/v1' }
        }
    }
    $providersPath = Join-Path $dataDir 'config\providers.json'
    $providers | ConvertTo-Json -Depth 20 | Set-Content -Path $providersPath -Encoding UTF8

    $cfg = Load-ByokProviderConfig $dataDir
    if ($cfg.providers.Count -ne 1) { throw "expected 1 enabled provider, got $($cfg.providers.Count)" }
    if ($cfg.providers[0].id -ne 'alpha') { throw "expected alpha, got $($cfg.providers[0].id)" }

    # CLI loading
    if ($cfg.clis.Count -ne 2) { throw "expected 2 CLIs, got $($cfg.clis.Count)" }
    $copilotCli = ($cfg.clis | Where-Object { $_.id -eq 'copilot' } | Select-Object -First 1)
    if (-not $copilotCli) { throw "copilot CLI not found" }
    if ($copilotCli.command -ne 'copilot') { throw "copilot CLI command mismatch: $($copilotCli.command)" }
    if ($copilotCli.modelEnvName -ne 'COPILOT_MODEL') { throw "copilot CLI modelEnvName mismatch" }
    $templatedArgs = Resolve-ByokCliArgs ([pscustomobject][ordered]@{ args=@('--model','{model}') }) $alpha 'https://alpha/v1' 'qwen3.5' 'sk-secret' 'alpha'
    if ($templatedArgs.Count -ne 2 -or $templatedArgs[0] -ne '--model' -or $templatedArgs[1] -ne 'qwen3.5') { throw "templated CLI args mismatch" }
    $geminiCli = ($cfg.clis | Where-Object { $_.id -eq 'gemini' } | Select-Object -First 1)
    if (-not $geminiCli) { throw "gemini CLI not found" }
    if ($geminiCli.command -ne 'gemini') { throw "gemini CLI command mismatch" }
    if ((Get-ByokCliSupportStatus $geminiCli) -ne 'supported') { throw "legacy test gemini should default to supported" }

    $first = @(Update-ByokCacheForProvider 'alpha' 'http://alpha/v1' '/models' @('m1','m2') $dataDir)
    if ($first.Count -ne 2) { throw "first fetch count mismatch: $($first.Count)" }
    $ttlSeconds = Get-ByokModelCacheTtlSeconds $cfg.providers[0]
    if ($ttlSeconds -ne 3600) { throw "model cache ttl mismatch: $ttlSeconds" }
    $cachedIds = @(Get-ByokCachedModelIds 'alpha' $dataDir)
    if ($cachedIds.Count -ne 2) { throw "cached model ids count mismatch: $($cachedIds.Count)" }
    if (-not (Test-ByokModelCacheFresh 'alpha' $cfg.providers[0] $dataDir)) { throw "cache should be fresh" }
    $chosen = Resolve-ByokChosenModel '' '' 'm1' @('m2','m3') $true
    if ($chosen -ne 'm2') { throw "provider switch fallback mismatch: $chosen" }
    $cache = Read-ByokCache $dataDir
    if ($cache.caches.alpha.baseUrl -ne 'http://alpha/v1') { throw "cache baseUrl mismatch" }
    if ($cache.caches.alpha.models.Count -ne 2) { throw "cache models count mismatch" }

    $second = @(Update-ByokCacheForProvider 'alpha' 'http://alpha/v1' '/models' @('m2','m3') $dataDir)
    $cache2 = Read-ByokCache $dataDir
    $byId = @{}; foreach ($m in $cache2.caches.alpha.models) { $byId[$m.id] = $m }
    if (-not $byId.ContainsKey('m1')) { throw "m1 should be retained (history)" }
    if ($byId.m1.available) { throw "m1 should be unavailable after second fetch" }
    if (-not $byId.m2.available) { throw "m2 should be available" }
    if (-not $byId.m3.available) { throw "m3 should be available" }
    if ($second.Count -ne 2) { throw "second fetch available count mismatch: $($second.Count)" }

    $alpha = $cfg.providers[0]
    $map = Build-ByokRuntimeEnvMap $alpha 'http://alpha/v1' 'm2' 'sk-secret' 'alpha' $copilotCli
    if ($map.COPILOT_PROVIDER_BASE_URL -ne 'http://alpha/v1') { throw "env url mismatch: $($map.COPILOT_PROVIDER_BASE_URL)" }
    if ($map.COPILOT_MODEL -ne 'm2') { throw "env model mismatch" }
    if ($map.COPILOT_PROVIDER_API_KEY -ne 'sk-secret') { throw "env key mismatch" }
    if ($map.BYOK_MODEL_PROVIDER_ID -ne 'alpha') { throw "env provider id mismatch" }

    $overrideProvider = [pscustomobject][ordered]@{
        name = 'Override'
        environment = [pscustomobject][ordered]@{
            copilot = [pscustomobject][ordered]@{
                'COPILOT_PROVIDER_MAX_PROMPT_TOKENS' = '32768'
                'COPILOT_PROVIDER_MAX_OUTPUT_TOKENS' = '32768'
            }
        }
    }
    $overrideMap = Build-ByokRuntimeEnvMap $overrideProvider 'https://override/v1' 'm3' 'sk-override' 'override' $copilotCli
    if ($overrideMap.COPILOT_PROVIDER_MAX_PROMPT_TOKENS -ne '32768') { throw "override prompt tokens mismatch" }
    if ($overrideMap.COPILOT_PROVIDER_MAX_OUTPUT_TOKENS -ne '32768') { throw "override output tokens mismatch" }

    $state = [ordered]@{ cliId='copilot'; cliName='GitHub Copilot CLI'; providerId='alpha'; providerName='Alpha'; baseUrl='http://alpha/v1'; model='m2'; apiKeySource='environment:ALPHA_KEY'; updatedAt=(Get-Date).ToString('o') }
    Write-ByokState $state $dataDir
    $readBack = Read-ByokState $dataDir
    if ($readBack.providerId -ne 'alpha') { throw "state round-trip mismatch" }
    if ($readBack.model -ne 'm2') { throw "state model mismatch" }
    if ($readBack.cliId -ne 'copilot') { throw "state cliId mismatch" }
    if ($readBack.cliName -ne 'GitHub Copilot CLI') { throw "state cliName mismatch" }

    $env:ALPHA_KEY = 'env-key'
    $name = Get-ByokApiKeyEnvName $alpha
    if ($name -ne 'ALPHA_KEY') { throw "apiKey env name mismatch: $name" }
    Remove-Item Env:\ALPHA_KEY -ErrorAction SilentlyContinue

    # Add-ByokProvider: write a new provider into the data-dir config, reload, verify.
    # Without -Cli: defaults to copilot env vars.
    $added = Add-ByokProvider -Name 'My Custom LLM' -BaseUrl 'https://custom.example.com/v1/' -ApiKey 'sk-custom' -DataDir $dataDir
    if ($added.id -ne 'my-custom-llm') { throw "add provider id mismatch: $($added.id)" }
    if ($added.apiKeyEnvName -ne 'MY_CUSTOM_LLM_API_KEY') { throw "add provider env name mismatch: $($added.apiKeyEnvName)" }
    if (-not (Test-Path $added.configPath)) { throw "add provider config file not written" }
    $cfg3 = Load-ByokProviderConfig $dataDir
    $custom = ($cfg3.providers | Where-Object { $_.id -eq 'my-custom-llm' } | Select-Object -First 1)
    if (-not $custom) { throw "added provider not found after reload" }
    if ($custom.baseUrl -ne 'https://custom.example.com/v1') { throw "added provider baseUrl mismatch: $($custom.baseUrl)" }
    if ($custom.type -ne 'openai') { throw "added provider type mismatch: $($custom.type)" }
    $map2 = Build-ByokRuntimeEnvMap $custom 'https://custom.example.com/v1' 'm1' 'sk-custom' 'my-custom-llm' $copilotCli
    if ($map2.COPILOT_PROVIDER_API_KEY -ne 'sk-custom') { throw "added provider env map key mismatch" }
    if ($map2.COPILOT_PROVIDER_BASE_URL -ne 'https://custom.example.com/v1') { throw "added provider env map url mismatch" }
    if ($map2.BYOK_MODEL_PROVIDER_ID -ne 'my-custom-llm') { throw "added provider env map id mismatch" }

    # Add-ByokProvider with -Cli gemini: defaults derived from CLI config.
    $geminiCliObj = [pscustomobject][ordered]@{
        defaultApiKeyEnv = @('GEMINI_API_KEY')
        defaultModelEnvNames = @('GEMINI_MODEL')
        settings = [pscustomobject][ordered]@{ 'GEMINI_API_KEY'='{api_key}'; 'GEMINI_MODEL'='{model}' }
    }
    $addedGem = Add-ByokProvider -Name 'Gemini Provider' -BaseUrl 'https://gem.example.com/v1/' -ApiKey 'sk-gem' -Cli $geminiCliObj -DataDir $dataDir
    if ($addedGem.id -ne 'gemini-provider') { throw "gemini add provider id mismatch: $($addedGem.id)" }
    $cfg4 = Load-ByokProviderConfig $dataDir
    $gemProv = ($cfg4.providers | Where-Object { $_.id -eq 'gemini-provider' } | Select-Object -First 1)
    if (-not $gemProv) { throw "gemini added provider not found after reload" }
    $mapGem = Build-ByokRuntimeEnvMap $gemProv 'https://gem.example.com/v1' 'gem-1' 'sk-gem' 'gemini-provider' $geminiCli
    if ($mapGem.GEMINI_API_KEY -ne 'sk-gem') { throw "gemini provider env map key mismatch" }
    if ($mapGem.GEMINI_MODEL -ne 'gem-1') { throw "gemini provider env map model mismatch" }
    # Should NOT contain copilot env vars when CLI is gemini
    if ($mapGem.Contains('COPILOT_PROVIDER_API_KEY')) { throw "gemini provider should not contain COPILOT env vars" }
    # apiKeyEnv should include both the provider-specific key and GEMINI_API_KEY
    if ($gemProv.apiKeyEnv -notcontains 'GEMINI_API_KEY') { throw "gemini provider apiKeyEnv should include GEMINI_API_KEY" }
    if ($gemProv.apiKeyEnv -notcontains 'GEMINI_PROVIDER_API_KEY') { throw "gemini provider apiKeyEnv should include GEMINI_PROVIDER_API_KEY" }

    Write-Host 'Smoke test passed.' -ForegroundColor Green
} finally {
    Remove-Item Env:\BYOK_CLI_HUB_DATA_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\BYOK_MODEL_V3_DATA_DIR -ErrorAction SilentlyContinue
    Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
}
