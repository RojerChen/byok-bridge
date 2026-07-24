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
    $local = Join-Path $DataDir 'providers.json'
    if (Test-Path -LiteralPath $local) { return $local }
    $legacy = Join-Path $DataDir 'config\providers.json'
    if (Test-Path -LiteralPath $legacy) {
        $legacyValue = Read-ByokJson $legacy $null
        Write-ByokJsonAtomic $local $legacyValue
        return $local
    }
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
    } catch {
        throw "Invalid or unreadable JSON file '$Path': $($_.Exception.Message)"
    }
}

function Write-ByokJsonAtomic {
    param([string]$Path, $Value)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $lock = "$Path.lock"
    $tmp = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).replace-backup"
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $lockStream = $null
    while (-not $lockStream) {
        try {
            $lockStream = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if (Test-Path -LiteralPath $lock) {
                $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $lock).LastWriteTimeUtc
                if ($age.TotalSeconds -gt 30) { Remove-Item -LiteralPath $lock -Force; continue }
            }
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for data lock '$lock'." }
            Start-Sleep -Milliseconds 25
        }
    }
    try {
        $lockBytes = [Text.Encoding]::UTF8.GetBytes("$PID $([DateTime]::UtcNow.ToString('o'))`n")
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush($true)
        $lockStream.Dispose(); $lockStream = $null

        $json = ($Value | ConvertTo-Json -Depth 20) + "`n"
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
        $stream = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tmp, $Path, $replaceBackup, $true)
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } finally {
        if ($lockStream) { $lockStream.Dispose() }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ByokEnvMap {
    param($Map, [string]$JsonPath)
    if (-not $Map) { return }
    foreach ($property in $Map.PSObject.Properties) {
        if ($property.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid provider config at $JsonPath.$($property.Name): invalid environment variable name."
        }
        if ($null -eq $property.Value -or ($property.Value -is [System.Collections.IEnumerable] -and $property.Value -isnot [string])) {
            throw "Invalid provider config at $JsonPath.$($property.Name): template value must be scalar."
        }
    }
}

function Assert-ByokProviderConfig {
    param($Config)
    if (-not $Config -or $Config.version -ne 1) { throw 'Invalid provider config at $.version: must equal 1.' }
    if (-not $Config.clis) { throw 'Invalid provider config at $.clis: at least one CLI is required.' }
    if (-not $Config.providers) { throw 'Invalid provider config at $.providers: object is required.' }
    foreach ($cliProperty in $Config.clis.PSObject.Properties) {
        $id = $cliProperty.Name; $cli = $cliProperty.Value; $basePath = "$.clis.$id"
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid provider config at ${basePath}: invalid CLI id." }
        if ($cli.command -and "$($cli.command)" -notmatch '^[A-Za-z0-9._+\-\\/:]+$') { throw "Invalid provider config at $basePath.command: invalid executable." }
        foreach ($arg in @($cli.args)) {
            if ($null -eq $arg -or $arg -isnot [string]) { throw "Invalid provider config at $basePath.args: strings are required." }
            if ($arg.Contains('{api_key}') -or $arg.Contains('${api_key}')) { throw "Invalid provider config at $basePath.args: API keys must use child environment variables, not process arguments." }
        }
        if ($cli.modelEnvName -and "$($cli.modelEnvName)" -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid provider config at $basePath.modelEnvName." }
        Assert-ByokEnvMap $cli.environment "$basePath.environment"
        Assert-ByokEnvMap $cli.settings "$basePath.settings"
    }
    foreach ($providerProperty in $Config.providers.PSObject.Properties) {
        $id = $providerProperty.Name; $provider = $providerProperty.Value; $basePath = "$.providers.$id"
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid provider config at ${basePath}: invalid provider id." }
        if ($provider.baseUrl) {
            $uri = $null
            if (-not [Uri]::TryCreate("$($provider.baseUrl)", [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
                throw "Invalid provider config at $basePath.baseUrl: absolute http(s) URL without credentials/query/fragment required."
            }
        }
        foreach ($field in @('apiKeyEnv','apiKeyEnvNames','modelEnvNames')) {
            foreach ($name in @($provider.$field)) {
                if ($name -and "$name" -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid provider config at $basePath.${field}: invalid environment variable name." }
            }
        }
        if ($provider.environment) {
            foreach ($override in $provider.environment.PSObject.Properties) { Assert-ByokEnvMap $override.Value "$basePath.environment.$($override.Name)" }
        }
        Assert-ByokEnvMap $provider.settings "$basePath.settings"
    }
    return $Config
}

# --- provider config ----------------------------------------------------------

function Load-ByokProviderConfig {
    param([string]$DataDir = (Get-ByokDataDir))
    $configPath = Get-ByokConfigPath $DataDir
    $parsed = Read-ByokJson $configPath @{ version = 1; providers = @{} }
    Assert-ByokProviderConfig $parsed | Out-Null
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
    $existingEntry = if ($caches.Contains($ProviderId)) { $caches[$ProviderId] } else { $null }
    $existingApiPath = if ($existingEntry.apiPath) { $existingEntry.apiPath } else { $existingEntry.modelsApiPath }
    $sameIdentity = $existingEntry -and "$($existingEntry.baseUrl)".TrimEnd('/') -eq "$BaseUrl".TrimEnd('/') -and "$existingApiPath" -eq "$ApiPath"
    if ($sameIdentity -and $existingEntry.models) {
        $existingModels = @($existingEntry.models)
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
        providerId = $ProviderId
        updatedAt  = $now
        baseUrl    = "$BaseUrl".TrimEnd('/')
        apiPath    = $ApiPath
        models     = $modelsList
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
    if (-not $Provider) { return 3600 }
    if ($Provider.PSObject.Properties.Name -contains 'modelCacheTtlSeconds') {
        $raw = $Provider.modelCacheTtlSeconds
        if ($null -eq $raw) { return 3600 }
        try {
            $seconds = [int]$raw
        } catch {
            return 3600
        }
        if ($seconds -lt 0) { return 0 }
        return $seconds
    }
    return 3600
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
        if ($model -is [string]) {
            $id = "$model".Trim()
            if ($id) { $ids += $id }
        } elseif ($model -and $model.available -ne $false) {
            $id = "$($model.id)".Trim()
            if ($id) { $ids += $id }
        }
    }
    return @($ids)
}

function Test-ByokModelCacheFresh {
    param([string]$ProviderId, $Provider, [string]$DataDir = (Get-ByokDataDir), [string]$BaseUrl, [string]$ApiPath = '/models')
    $ttl = Get-ByokModelCacheTtlSeconds $Provider
    if ($ttl -le 0) { return $false }
    $entry = Get-ByokProviderCacheEntry $ProviderId $DataDir
    $updatedAt = if ($entry.updatedAt) { $entry.updatedAt } else { $entry.lastQueried }
    if (-not $entry -or -not $updatedAt) { return $false }
    if ($BaseUrl) {
        $entryApiPath = if ($entry.apiPath) { $entry.apiPath } else { $entry.modelsApiPath }
        if ("$($entry.baseUrl)".TrimEnd('/') -ne "$BaseUrl".TrimEnd('/') -or "$entryApiPath" -ne "$ApiPath") { return $false }
    }
    try {
        $lastQueried = [DateTime]::Parse($updatedAt)
    } catch {
        return $false
    }
    $ageSeconds = [int]([DateTime]::UtcNow - $lastQueried.ToUniversalTime()).TotalSeconds
    return ($ageSeconds -ge 0 -and $ageSeconds -lt $ttl)
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
    return 'gpt-4o'
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
    Assert-ByokProviderConfig $parsed | Out-Null

    # Always write into the data-dir config so future loads pick it up.
    $targetPath = Join-Path $DataDir 'providers.json'
    $configDir = Split-Path -Parent $targetPath
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }
    Write-ByokJsonAtomic $targetPath $parsed

    return [pscustomobject]@{ id = $id; apiKeyEnvName = $envName; configPath = $targetPath }
}

function Get-ByokApiKeySource {
    param([string]$EnvName, [bool]$FromPrompt, [bool]$FromArgument, [bool]$HasKey)
    if ($FromPrompt) { return 'prompt' }
    if ($FromArgument) { return 'argument' }
    if ($HasKey -and $EnvName) { return "env:$EnvName" }
    return 'none'
}

Export-ModuleMember -Function Get-ByokDataDir, Get-ByokConfigPath, Read-ByokJson, Write-ByokJsonAtomic,
    Load-ByokProviderConfig, Get-ByokStatePath, Read-ByokState, Write-ByokState,
    Get-ByokCachePath, Read-ByokCache, Write-ByokCache, Update-ByokCacheForProvider,
    Resolve-ByokEnvValue, Get-ByokApiKeyEnvName, Get-ByokModelCacheTtlSeconds,
    Get-ByokProviderCacheEntry, Get-ByokCachedModelIds, Test-ByokModelCacheFresh,
    Resolve-ByokChosenModel, Get-ByokCliSupportStatus, Expand-ByokTemplateValue, Resolve-ByokCliArgs,
    Build-ByokRuntimeEnvMap, Invoke-ByokModelFetch, Add-ByokProvider, Get-ByokApiKeySource,
    Assert-ByokProviderConfig
