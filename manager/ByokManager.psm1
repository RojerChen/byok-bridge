# ByokManager.psm1 — shared PowerShell helpers for BYOK CLI Hub.
# Pure data layer: data dir, provider config, state, cache, model fetch, env map.
# No stdin interaction here — the calling script handles prompts.

# --- data dir -----------------------------------------------------------------

function Get-ByokDataDir {
    $override = if ($env:BYOK_CLI_HUB_DATA_DIR -and $env:BYOK_CLI_HUB_DATA_DIR.Trim()) {
        $env:BYOK_CLI_HUB_DATA_DIR
    } else { $env:BYOK_MODEL_V3_DATA_DIR }
    if ($override -and $override.Trim()) {
        $resolved = $override.Trim()
        if (-not (Test-Path $resolved)) { New-Item -ItemType Directory -Force -Path $resolved | Out-Null }
        return (Resolve-Path $resolved).Path
    }
    $newPath = Join-Path $env:USERPROFILE '.byok-cli-hub'
    $legacyPath = Join-Path $env:USERPROFILE '.copilot\byok-model-v3'
    if ((Test-Path $newPath) -or -not (Test-Path $legacyPath)) { return $newPath }
    return $legacyPath
}

function Get-ByokConfigPath {
    param([string]$DataDir)
    $local = Join-Path $DataDir 'config\providers.json'
    if (Test-Path $local) { return $local }
    $here = Split-Path -Parent $PSScriptRoot
    $repo = Join-Path $here 'config\providers.json'
    if (Test-Path $repo) { return $repo }
    $example = Join-Path $here 'config\providers.example.json'
    if (Test-Path $example) { return $example }
    return $local
}

# --- json io ------------------------------------------------------------------

function Read-ByokJson {
    param([string]$Path, $Fallback = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Fallback }
    try {
        $raw = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
        if (-not $raw) { return $Fallback }
        return ($raw | ConvertFrom-Json)
    } catch { return $Fallback }
}

function Write-ByokJsonAtomic {
    param([string]$Path, $Value)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.$PID.tmp"
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($tmp, "$json`n", (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# --- provider config ----------------------------------------------------------

function Load-ByokProviderConfig {
    param([string]$DataDir = (Get-ByokDataDir))
    $configPath = Get-ByokConfigPath $DataDir
    $parsed = Read-ByokJson $configPath @{ version = 1; providers = @{} }
    $list = @()
    if ($parsed.providers) {
        foreach ($p in $parsed.providers.PSObject.Properties) {
            $profile = $p.Value
            if ($profile.enabled -eq $false) { continue }
            $obj = [ordered]@{ id = $p.Name }
            foreach ($pp in $profile.PSObject.Properties) { $obj[$pp.Name] = $pp.Value }
            $list += ,[pscustomobject]$obj
        }
    }
    $sorted = $list | Sort-Object { if ($null -ne $_.order) { [double]$_.order } else { 0 } }

    # CLI configs (optional; if absent, callers fall back to copilot defaults).
    $cliList = @()
    if ($parsed.clis) {
        foreach ($c in $parsed.clis.PSObject.Properties) {
            $cli = $c.Value
            if ($cli.enabled -eq $false) { continue }
            $cobj = [ordered]@{ id = $c.Name }
            foreach ($cp in $cli.PSObject.Properties) { $cobj[$cp.Name] = $cp.Value }
            $cliList += ,[pscustomobject]$cobj
        }
    }
    $cliSorted = $cliList | Sort-Object { if ($null -ne $_.order) { [double]$_.order } else { 0 } }

    return [pscustomobject]@{ configPath = $configPath; providers = @($sorted); clis = @($cliSorted) }
}

# --- state --------------------------------------------------------------------

function Get-ByokStatePath { param([string]$DataDir = (Get-ByokDataDir)); (Join-Path $DataDir 'state.json') }
function Read-ByokState { param([string]$DataDir = (Get-ByokDataDir)); (Read-ByokJson (Get-ByokStatePath $DataDir) $null) }
function Write-ByokState { param($State, [string]$DataDir = (Get-ByokDataDir)); (Write-ByokJsonAtomic (Get-ByokStatePath $DataDir) $State) }

# --- cache --------------------------------------------------------------------

function Get-ByokCachePath { param([string]$DataDir = (Get-ByokDataDir)); (Join-Path $DataDir 'models-cache.json') }
function Read-ByokCache { param([string]$DataDir = (Get-ByokDataDir)); (Read-ByokJson (Get-ByokCachePath $DataDir) @{ version = 1; caches = @{} }) }

function Write-ByokCache {
    param($Cache, [string]$DataDir = (Get-ByokDataDir))
    Write-ByokJsonAtomic (Get-ByokCachePath $DataDir) $Cache
}

function Update-ByokCacheForProvider {
    param(
        [string]$ProviderId, [string]$BaseUrl, [string]$ApiPath,
        [string[]]$ModelIds, [string]$DataDir = (Get-ByokDataDir)
    )
    $cache = Read-ByokCache $DataDir
    # Normalize caches into a hashtable keyed by provider id.
    $caches = [ordered]@{}
    if ($cache.caches) {
        if ($cache.caches -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $cache.caches.PSObject.Properties) { $caches[$p.Name] = $p.Value }
        } elseif ($cache.caches -is [System.Collections.IDictionary]) {
            foreach ($k in $cache.caches.Keys) { $caches[$k] = $cache.caches[$k] }
        }
    }

    $now = (Get-Date).ToString('o')
    $existingModels = @()
    if ($caches.Contains($ProviderId) -and $caches[$ProviderId].models) {
        $existingModels = @($caches[$ProviderId].models)
    }
    $byId = [ordered]@{}
    $maxOrder = 0
    foreach ($m in $existingModels) {
        $ord = if ($null -ne $m.order) { [int]$m.order } else { 0 }
        if ($ord -gt $maxOrder) { $maxOrder = $ord }
        $byId[$m.id] = [ordered]@{ id = $m.id; order = $ord; available = $false; firstSeen = $m.firstSeen; lastSeen = $m.lastSeen }
    }
    $seenList = [ordered]@{}
    foreach ($id in $ModelIds) {
        if (-not $id) { continue }
        $seenList[$id] = $true
        if ($byId.Contains($id)) {
            $byId[$id].available = $true
            $byId[$id].lastSeen = $now
        } else {
            $maxOrder += 1
            $byId[$id] = [ordered]@{ id = $id; order = $maxOrder; available = $true; firstSeen = $now; lastSeen = $now }
        }
    }
    $sorted = $byId.Values | Sort-Object { [int]$_.order }
    $idx = 1
    $modelsList = @()
    foreach ($m in $sorted) { $m.order = $idx; $idx += 1; $modelsList += ,$m }

    $caches[$ProviderId] = [ordered]@{
        provider        = $ProviderId
        baseUrl         = $BaseUrl
        modelsApiPath   = $ApiPath
        lastQueried     = $now
        models          = $modelsList
    }
    $newCache = [ordered]@{ version = 1; caches = $caches }
    Write-ByokCache $newCache $DataDir
    return ($modelsList | Where-Object { $_.available } | ForEach-Object { $_.id })
}

# --- env map ------------------------------------------------------------------

function Resolve-ByokEnvValue {
    param($Names)
    if (-not $Names) { return $null }
    foreach ($n in @($Names)) {
        if (-not $n) { continue }
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v -and $v.Trim()) { return $v.Trim() }
    }
    return $null
}

function Get-ByokApiKeyEnvName {
    param($Provider)
    $names = $Provider.apiKeyEnvNames
    if (-not $names) { $names = $Provider.apiKeyEnv }
    if (-not $names) { return $null }
    foreach ($n in @($names)) {
        if (-not $n) { continue }
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v -and $v.Trim()) { return $n }
    }
    return (@($names | Where-Object { $_ }) | Select-Object -First 1)
}

function Get-ByokModelCacheTtlSeconds {
    param($Provider)
    if (-not $Provider) { return 0 }
    if ($Provider.PSObject.Properties.Name -contains 'modelCacheTtlSeconds') {
        $raw = $Provider.modelCacheTtlSeconds
        if ($null -eq $raw) { return 0 }
        try {
            $seconds = [int]$raw
        } catch {
            return 0
        }
        if ($seconds -lt 0) { return 0 }
        return $seconds
    }
    return 0
}

function Get-ByokProviderCacheEntry {
    param([string]$ProviderId, [string]$DataDir = (Get-ByokDataDir))
    $cache = Read-ByokCache $DataDir
    if (-not $cache.caches) { return $null }
    if ($cache.caches -is [System.Management.Automation.PSCustomObject]) {
        $prop = $cache.caches.PSObject.Properties[$ProviderId]
        if ($prop) { return $prop.Value }
    } elseif ($cache.caches -is [System.Collections.IDictionary]) {
        if ($cache.caches.Contains($ProviderId)) { return $cache.caches[$ProviderId] }
    }
    return $null
}

function Get-ByokCachedModelIds {
    param([string]$ProviderId, [string]$DataDir = (Get-ByokDataDir))
    $entry = Get-ByokProviderCacheEntry $ProviderId $DataDir
    if (-not $entry -or -not $entry.models) { return @() }
    $ids = @()
    foreach ($model in @($entry.models)) {
        if ($model -and $model.available -eq $true) {
            $id = "$($model.id)".Trim()
            if ($id) { $ids += $id }
        }
    }
    return @($ids)
}

function Test-ByokModelCacheFresh {
    param([string]$ProviderId, $Provider, [string]$DataDir = (Get-ByokDataDir))
    $ttl = Get-ByokModelCacheTtlSeconds $Provider
    if ($ttl -le 0) { return $false }
    $entry = Get-ByokProviderCacheEntry $ProviderId $DataDir
    if (-not $entry -or -not $entry.lastQueried) { return $false }
    try {
        $lastQueried = [DateTime]::Parse($entry.lastQueried)
    } catch {
        return $false
    }
    $ageSeconds = [int]([DateTime]::UtcNow - $lastQueried.ToUniversalTime()).TotalSeconds
    return ($ageSeconds -le $ttl)
}

function Resolve-ByokChosenModel {
    param([string]$RequestedModel, [string]$EnvironmentModel, [string]$RememberedModel, [string[]]$AvailableModels, [bool]$ForceFirstModel)
    $requested = "$RequestedModel".Trim()
    if ($requested) { return $requested }

    if ($ForceFirstModel -and $AvailableModels.Count -gt 0) {
        return "$($AvailableModels[0])".Trim()
    }

    $env = "$EnvironmentModel".Trim()
    if ($env) { return $env }

    $remembered = "$RememberedModel".Trim()
    if ($remembered) {
        foreach ($model in @($AvailableModels)) {
            if ("$model".Trim() -eq $remembered) { return $remembered }
        }
    }

    if ($AvailableModels.Count -gt 0) { return "$($AvailableModels[0])".Trim() }
    return ''
}

function Get-ByokCliEnvironmentMap {
    param($Cli)
    if (-not $Cli) { return $null }
    # Current schema: environment directly contains the required env map.
    if ($Cli.environment) {
        return $Cli.environment
    }
    return $Cli.settings
}

function Get-ByokCliSupportStatus {
    param($Cli)
    if (-not $Cli) { return 'unsupported' }
    if ($Cli.status) { return "$($Cli.status)".Trim().ToLowerInvariant() }
    if ($Cli.capabilities -and $Cli.capabilities.status) {
        return "$($Cli.capabilities.status)".Trim().ToLowerInvariant()
    }
    return 'supported'
}

function Get-ByokProviderCliOverrides {
    param($Provider, $Cli)
    if (-not $Provider -or -not $Cli -or -not $Provider.environment) { return $null }
    $prop = $Provider.environment.PSObject.Properties[$Cli.id]
    if ($prop) { return $prop.Value }
    return $null
}

function Expand-ByokTemplateValue {
    param([string]$Value, $Substitutions)
    if ($null -eq $Value) { return $null }
    $text = "$Value"
    foreach ($k in $Substitutions.Keys) { $text = $text.Replace($k, $Substitutions[$k]) }
    return $text
}

function Resolve-ByokCliArgs {
    param($Cli, $Provider, [string]$BaseUrl, [string]$Model, [string]$ApiKey, [string]$ProviderId)
    if (-not $Cli) { return @() }
    $rawArgs = @($Cli.args)
    if ($rawArgs.Count -eq 0) { return @() }

    $providerName = if ($Provider -and $Provider.name) { "$($Provider.name)" } else { '' }
    $subs = [ordered]@{
        '{url}'            = $BaseUrl
        '${url}'           = $BaseUrl
        '{api_key}'        = $ApiKey
        '${api_key}'       = $ApiKey
        '{model}'          = $Model
        '${model}'         = $Model
        '{provider_id}'    = $ProviderId
        '${provider_id}'   = $ProviderId
        '{provider_name}'  = $providerName
        '${provider_name}' = $providerName
    }

    $expanded = @()
    foreach ($arg in $rawArgs) {
        $expanded += ,(Expand-ByokTemplateValue "$arg" $subs)
    }
    return $expanded
}

function Build-ByokRuntimeEnvMap {
    param($Provider, [string]$BaseUrl, [string]$Model, [string]$ApiKey, [string]$ProviderId, $Cli = $null)
    $map = [ordered]@{}
    $subs = [ordered]@{
        '{url}'            = $BaseUrl
        '${url}'           = $BaseUrl
        '{api_key}'        = $ApiKey
        '${api_key}'       = $ApiKey
        '{model}'          = $Model
        '${model}'         = $Model
        '{provider_id}'    = $ProviderId
        '${provider_id}'   = $ProviderId
        '{provider_name}'  = ($Provider.name)
        '${provider_name}' = ($Provider.name)
    }

    $cliEnvironment = Get-ByokCliEnvironmentMap $Cli
    if ($cliEnvironment) {
        foreach ($p in $cliEnvironment.PSObject.Properties) {
            $val = "$($p.Value)"
            foreach ($k in $subs.Keys) { $val = $val.Replace($k, $subs[$k]) }
            $map[$p.Name] = $val
        }
    }

    $cliModelEnvName = if ($Cli -and $Cli.modelEnvName) { "$($Cli.modelEnvName)".Trim() } else { $null }
    if ($cliModelEnvName) { $map[$cliModelEnvName] = $Model }

    $cliApiKeyEnvNames = @()
    if ($Cli -and $Cli.defaultApiKeyEnv) { $cliApiKeyEnvNames += @($Cli.defaultApiKeyEnv) }
    if ($Cli -and $Cli.apiKeyEnv) { $cliApiKeyEnvNames += @($Cli.apiKeyEnv) }
    foreach ($t in $cliApiKeyEnvNames) {
        $name = "$t".Trim()
        if ($name) { $map[$name] = $ApiKey }
    }

    $providerOverrides = Get-ByokProviderCliOverrides $Provider $Cli
    if ($providerOverrides) {
        foreach ($p in $providerOverrides.PSObject.Properties) {
            $name = "$($p.Name)".Trim()
            if (-not $name) { continue }
            $val = "$($p.Value)"
            foreach ($k in $subs.Keys) { $val = $val.Replace($k, $subs[$k]) }
            $map[$name] = $val
        }
    }

    # Legacy provider-level settings remain supported for existing user configs.
    if ($Provider.settings) {
        foreach ($p in $Provider.settings.PSObject.Properties) {
            $name = "$($p.Name)".Trim()
            if (-not $name) { continue }
            $val = "$($p.Value)"
            foreach ($k in $subs.Keys) { $val = $val.Replace($k, $subs[$k]) }
            $map[$name] = $val
        }
    }

    $keyTargets = @()
    if ($Provider.apiKeyEnvNames) { $keyTargets += @($Provider.apiKeyEnvNames) }
    elseif ($Provider.apiKeyEnv) { $keyTargets += @($Provider.apiKeyEnv) }
    foreach ($t in $keyTargets) {
        $name = "$t".Trim()
        if ($name) { $map[$name] = $ApiKey }
    }

    $modelTargets = @()
    if ($Provider.modelEnvNames) { $modelTargets += @($Provider.modelEnvNames) }
    foreach ($t in $modelTargets) {
        $name = "$t".Trim()
        if ($name) { $map[$name] = $Model }
    }

    return $map
}

# --- model fetch --------------------------------------------------------------

function Invoke-ByokModelFetch {
    param($Provider, [string]$BaseUrl, [string]$ApiKey)
    $api = $Provider.modelsApi
    if (-not $api) { $api = [pscustomobject]@{} }
    $apiPath = if ($api.path) { $api.path } else { '/models' }
    $cleanBase = $BaseUrl.TrimEnd('/')
    if (-not $apiPath.StartsWith('/')) { $apiPath = '/' + $apiPath }
    $fullUrl = "$cleanBase$apiPath"

    $headers = @{ 'Accept' = 'application/json' }
    if ($ApiKey) {
        $headerName = if ($api.apiKeyHeader) { $api.apiKeyHeader } elseif ($Provider.apiKeyHeader) { $Provider.apiKeyHeader } else { 'Authorization' }
        $prefix = if ($api.apiKeyPrefix) { $api.apiKeyPrefix } elseif ($Provider.apiKeyPrefix) { $Provider.apiKeyPrefix } else { 'Bearer ' }
        $headers[$headerName] = "$prefix$ApiKey"
    }

    try {
        $resp = Invoke-RestMethod -Uri $fullUrl -Method Get -Headers $headers -TimeoutSec 10 -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            throw "Provider returned HTTP $code."
        }
        throw "Unable to fetch models: $msg"
    }

    $itemsPath = if ($api.itemsPath) { $api.itemsPath } else { 'data' }
    $idPath = if ($api.idPath) { $api.idPath } else { 'id' }
    $items = $resp
    foreach ($part in ($itemsPath -split '\.')) { $items = $items.$part }
    if ($null -eq $items) { throw 'Provider returned an unsupported models payload.' }

    $ids = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($item in @($items)) {
        $cur = $item
        foreach ($part in ($idPath -split '\.')) { $cur = $cur.$part }
        if ($null -ne $cur) {
            $s = "$cur".Trim()
            if ($s -and -not $seen.ContainsKey($s)) { $seen[$s] = $true; $ids.Add($s) }
        }
    }
    return $ids.ToArray()
}

# --- add provider ------------------------------------------------------------

function Add-ByokProvider {
    param(
        [string]$Name,
        [string]$BaseUrl,
        [string]$ApiKey,
        $Cli = $null,
        [string]$DataDir = (Get-ByokDataDir)
    )
    $name = "$Name".Trim()
    $url = "$BaseUrl".Trim().TrimEnd('/')
    if (-not $name) { throw 'Provider name is required.' }
    if (-not $url) { throw 'Base URL is required.' }

    # Slug id from the display name.
    $id = $name.ToLower() -replace '[^a-z0-9]+', '-' -replace '^-+|-+$', ''
    if (-not $id) { $id = 'custom-provider' }

    # Defaults derived from the selected CLI (if any), otherwise copilot.
    $defaultApiKeyEnv    = if ($Cli -and $Cli.defaultApiKeyEnv)    { @($Cli.defaultApiKeyEnv) } else { @('COPILOT_PROVIDER_API_KEY') }
    $defaultModelEnvNames = if ($Cli -and $Cli.defaultModelEnvNames) { @($Cli.defaultModelEnvNames) } else { @('COPILOT_MODEL') }

    $configPath = Get-ByokConfigPath $DataDir
    $parsed = Read-ByokJson $configPath ([pscustomobject]@{ version = 1; providers = [pscustomobject]@{} })
    if (-not $parsed.providers) {
        $parsed | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not ($parsed.providers -is [pscustomobject] -or $parsed.providers.PSObject)) {
        $parsed.providers = [pscustomobject]@{}
    }

    # Ensure a unique provider id.
    $existing = @()
    if ($parsed.providers.PSObject) { $existing = @($parsed.providers.PSObject.Properties.Name) }
    $baseId = $id; $n = 2
    while ($existing -contains $id) { $id = "$baseId-$n"; $n++ }

    $envName = (($id.ToUpper() -replace '[^A-Z0-9]+', '_').Trim('_')) + '_API_KEY'
    $apiKeyEnvList = @(@($envName) + @($defaultApiKeyEnv) | Select-Object -Unique)

    $provider = [pscustomobject][ordered]@{
        name          = $name
        enabled       = $true
        type          = 'openai'
        baseUrl       = $url
        apiKeyEnv     = $apiKeyEnvList
        modelEnvNames = @($defaultModelEnvNames)
        apiKeyHeader  = 'Authorization'
        apiKeyPrefix  = 'Bearer '
        modelsApi     = [pscustomobject][ordered]@{ path = '/models'; itemsPath = 'data'; idPath = 'id' }
        environment = [pscustomobject]@{}
    }

    $parsed.providers | Add-Member -NotePropertyName $id -NotePropertyValue $provider -Force

    # Always write into the data-dir config so future loads pick it up.
    $targetPath = Join-Path $DataDir 'config\providers.json'
    $configDir = Split-Path -Parent $targetPath
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }
    Write-ByokJsonAtomic $targetPath $parsed

    return [pscustomobject]@{ id = $id; apiKeyEnvName = $envName; configPath = $targetPath }
}

function Get-ByokApiKeySource {
    param([string]$EnvName, [bool]$FromPrompt)
    if ($FromPrompt) { return 'prompt' }
    if ($EnvName) { return "environment:$EnvName" }
    return 'prompt'
}

Export-ModuleMember -Function Get-ByokDataDir, Get-ByokConfigPath, Read-ByokJson, Write-ByokJsonAtomic,
    Load-ByokProviderConfig, Get-ByokStatePath, Read-ByokState, Write-ByokState,
    Get-ByokCachePath, Read-ByokCache, Write-ByokCache, Update-ByokCacheForProvider,
    Resolve-ByokEnvValue, Get-ByokApiKeyEnvName, Get-ByokModelCacheTtlSeconds,
    Get-ByokProviderCacheEntry, Get-ByokCachedModelIds, Test-ByokModelCacheFresh,
    Resolve-ByokChosenModel, Get-ByokCliSupportStatus, Expand-ByokTemplateValue, Resolve-ByokCliArgs,
    Build-ByokRuntimeEnvMap, Invoke-ByokModelFetch, Add-ByokProvider, Get-ByokApiKeySource
