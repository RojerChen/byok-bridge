# ByokManager.psm1 — shared PowerShell helpers for BYOK Bridge.
# Pure data layer: data dir, provider config, state, cache, model fetch, env map.
# No stdin interaction here — the calling script handles prompts.

# --- data dir -----------------------------------------------------------------

function Get-ByokDataDir {
    param([switch]$NoCreate)
    $override = $env:BYOK_BRIDGE_DATA_DIR
    if ($override -and $override.Trim()) {
        $resolved = $override.Trim()
        if (-not (Test-Path $resolved)) {
            if (-not $NoCreate) { New-Item -ItemType Directory -Force -Path $resolved | Out-Null }
            return [IO.Path]::GetFullPath($resolved)
        }
        return (Resolve-Path -LiteralPath $resolved).Path
    }
    return (Join-Path $env:USERPROFILE '.byok-bridge')
}

function Get-ByokConfigPath {
    param([string]$DataDir, [switch]$NoMigrate)
    $local = Join-Path $DataDir 'providers.json'
    if (Test-Path -LiteralPath $local) { return $local }
    $legacy = Join-Path $DataDir 'config\providers.json'
    if (Test-Path -LiteralPath $legacy) {
        $legacyValue = Read-ByokJson $legacy $null
        Assert-ByokProviderConfig $legacyValue | Out-Null
        if ($NoMigrate) { return $legacy }
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

function Invoke-WithByokFileLock {
    param([string]$Path, [scriptblock]$Operation)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $lock = "$Path.lock"
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $lockStream = $null
    while (-not $lockStream) {
        try {
            $lockStream = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $lock)) { continue }

            $age = $null
            try { $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $lock -ErrorAction Stop).LastWriteTimeUtc } catch { }
            if ($age -and $age.TotalSeconds -gt 30) {
                $ownerStatus = 'unknown'
                try {
                    $ownerText = [IO.File]::ReadAllText($lock, [Text.Encoding]::UTF8).Trim()
                    $ownerPid = 0
                    if ([int]::TryParse(($ownerText -split '\s+')[0], [ref]$ownerPid) -and $ownerPid -gt 0) {
                        $ownerStatus = if ($null -ne (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) { 'alive' } else { 'dead' }
                    } else {
                        $ownerStatus = 'dead'
                    }
                } catch [System.IO.FileNotFoundException] {
                    continue
                } catch {
                    # An exclusively held or unreadable lock is still potentially live.
                    $ownerStatus = 'unknown'
                }

                if ($ownerStatus -eq 'dead') {
                    $removed = $false
                    try {
                        Remove-Item -LiteralPath $lock -Force -ErrorAction Stop
                        $removed = $true
                    } catch {
                        if (-not (Test-Path -LiteralPath $lock)) { $removed = $true }
                    }
                    if ($removed) { continue }
                }
            }
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for data lock '$lock'." }
            Start-Sleep -Milliseconds 25
        }
    }
    try {
        $lockBytes = [Text.Encoding]::UTF8.GetBytes("$PID $([DateTime]::UtcNow.ToString('o'))`n")
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush($true)
        return (& $Operation)
    } finally {
        if ($lockStream) { $lockStream.Dispose() }
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
}

function Write-ByokJsonAtomicUnlocked {
    param([string]$Path, $Value)
    $tmp = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $replaceBackup = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).replace-backup"
    try {
        $json = (($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n").Replace("`r", "`n")) + "`n"
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
        $stream = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # Re-read and parse the durable temp file before replacing a valid target.
        # A hashtable parse preserves JSON keys that differ only by case,
        # which is required for case-sensitive OpenCode model IDs.
        $durableJson = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('AsHashtable')) {
            $durableJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop | Out-Null
        } else {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = 67108864
            $serializer.RecursionLimit = 100
            $serializer.DeserializeObject($durableJson) | Out-Null
        }
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tmp, $Path, $replaceBackup, $true)
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    }
}

function Write-ByokJsonAtomic {
    param([string]$Path, $Value)
    Invoke-WithByokFileLock $Path { Write-ByokJsonAtomicUnlocked $Path $Value }
}

function Test-ByokJsonObject {
    param($Value)
    return $Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [System.Collections.IDictionary]
}

function Test-ByokHasProperty {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ByokObjectEntries {
    param($Object)
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { [pscustomobject]@{ Name = "$key"; Value = $Object[$key] } }
    } else {
        foreach ($property in $Object.PSObject.Properties) { $property }
    }
}

function Test-ByokJsonNumber {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    return [Type]::GetTypeCode($Value.GetType()) -in @(
        [TypeCode]::Byte,
        [TypeCode]::SByte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Single,
        [TypeCode]::Double,
        [TypeCode]::Decimal
    )
}

function Assert-ByokOpenCodeTemplate {
    param(
        $Value,
        [string]$JsonPath = '$',
        [int]$Depth = 0,
        [string]$PropertyName = '',
        [string]$ParentName = ''
    )
    if ($Depth -gt 32) { throw "OpenCode template exceeds the maximum depth of 32 at $JsonPath." }

    if ($Value -is [string]) {
        $text = "$Value"
        if ($text.Contains('{api_key}')) { throw "OpenCode templates must not contain plaintext API key placeholder '{api_key}' at $JsonPath." }
        $known = @('{url}', '{provider_id}', '{opencode_provider_id}', '{provider_name}', '{model}', '{models}', '{api_key_ref}')
        foreach ($match in [regex]::Matches($text, '\{[a-z][a-z0-9_]*\}')) {
            if ($known -cnotcontains $match.Value) { throw "Unknown OpenCode template placeholder '$($match.Value)' at $JsonPath." }
        }
        if ($text.Contains('{models}') -and $text -cne '{models}') {
            throw "'{models}' must be the complete template value at $JsonPath."
        }
        if ($text.Contains('{api_key_ref}') -and
            ($text -cne '{api_key_ref}' -or $PropertyName -cne 'apiKey' -or $ParentName -cne 'options')) {
            throw "'{api_key_ref}' is only allowed as the complete provider options.apiKey value at $JsonPath."
        }
        return
    }

    if ($Value -is [System.Array]) {
        for ($i = 0; $i -lt $Value.Count; $i++) {
            Assert-ByokOpenCodeTemplate $Value[$i] "$JsonPath[$i]" ($Depth + 1)
        }
        return
    }

    if (Test-ByokJsonObject $Value) {
        foreach ($entry in (Get-ByokObjectEntries $Value)) {
            Assert-ByokOpenCodeTemplate "$($entry.Name)" "$JsonPath key" ($Depth + 1)
            if ($entry.Name.Contains('{models}') -or $entry.Name.Contains('{api_key_ref}')) {
                throw "Typed OpenCode placeholders are not allowed in object keys at $JsonPath."
            }
            Assert-ByokOpenCodeTemplate $entry.Value "$JsonPath.$($entry.Name)" ($Depth + 1) $entry.Name $PropertyName
        }
        return
    }

    if ($null -eq $Value -or $Value -is [bool] -or (Test-ByokJsonNumber $Value)) { return }
    throw "Unsupported OpenCode template value at $JsonPath."
}

function Assert-ByokEnvMap {
    param($Map, [string]$JsonPath)
    if (-not (Test-ByokJsonObject $Map)) { throw "Invalid provider config at ${JsonPath}: object required." }
    foreach ($property in (Get-ByokObjectEntries $Map)) {
        if ($property.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid provider config at $JsonPath.$($property.Name): invalid environment variable name."
        }
        $value = $property.Value
        $allowedScalar = $value -is [string] -or $value -is [bool] -or (Test-ByokJsonNumber $value)
        if (-not $allowedScalar) {
            throw "Invalid provider config at $JsonPath.$($property.Name): template value must be scalar (string, number, or boolean)."
        }
    }
}

function Assert-ByokProviderConfig {
    param($Config)
    if (-not (Test-ByokJsonObject $Config)) {
        throw 'Invalid provider config at $.version: must equal 1.'
    }
    if (-not (Test-ByokHasProperty $Config 'version')) {
        throw 'Invalid provider config at $.version: must equal 1.'
    }
    $version = $Config.version
    if (-not (Test-ByokJsonNumber $version) -or $version -ne 1) {
        throw 'Invalid provider config at $.version: must be the number 1.'
    }
    if (-not (Test-ByokHasProperty $Config 'clis') -or -not (Test-ByokJsonObject $Config.clis) -or @(Get-ByokObjectEntries $Config.clis).Count -eq 0) {
        throw 'Invalid provider config at $.clis: at least one CLI is required.'
    }
    if (-not (Test-ByokHasProperty $Config 'providers') -or -not (Test-ByokJsonObject $Config.providers)) {
        throw 'Invalid provider config at $.providers: object is required.'
    }

    foreach ($cliProperty in (Get-ByokObjectEntries $Config.clis)) {
        $id = $cliProperty.Name; $cli = $cliProperty.Value; $basePath = "$.clis.$id"
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid provider config at ${basePath}: invalid CLI id." }
        if (-not (Test-ByokJsonObject $cli)) { throw "Invalid provider config at ${basePath}: object required." }

        if (Test-ByokHasProperty $cli 'command') {
            if ($cli.command -isnot [string] -or -not $cli.command.Trim()) { throw "Invalid provider config at $basePath.command: non-empty string required." }
            $command = $cli.command.Trim()
            if ([IO.Path]::IsPathRooted($command)) {
                if ($command -match '^[A-Za-z]:[^\\/]') {
                    throw "Invalid provider config at $basePath.command: drive-relative paths (e.g., C:file.exe) are not allowed; use fully-qualified paths."
                }
            } elseif ($command -notmatch '^[A-Za-z0-9._+\-]+$') {
                throw "Invalid provider config at $basePath.command: executable name or absolute path required."
            }
        }
        if (Test-ByokHasProperty $cli 'args') {
            if ($cli.args -isnot [System.Array]) { throw "Invalid provider config at $basePath.args: array of strings required." }
            foreach ($arg in $cli.args) {
                if ($arg -isnot [string]) { throw "Invalid provider config at $basePath.args: strings are required." }
                if ($arg.Contains('{api_key}') -or $arg.Contains('${api_key}')) { throw "Invalid provider config at $basePath.args: API keys must use child environment variables, not process arguments." }
            }
        }
        if (Test-ByokHasProperty $cli 'modelEnvName') {
            if ($null -ne $cli.modelEnvName -and ($cli.modelEnvName -isnot [string] -or $cli.modelEnvName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$')) { throw "Invalid provider config at $basePath.modelEnvName." }
        }
        foreach ($field in @('defaultApiKeyEnv', 'defaultModelEnvNames', 'apiKeyEnv')) {
            if (Test-ByokHasProperty $cli $field) {
                foreach ($name in @($cli.$field)) {
                    if ($name -isnot [string] -or $name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid provider config at $basePath.${field}: invalid environment variable name." }
                }
            }
        }
        if (Test-ByokHasProperty $cli 'status') {
            if ($cli.status -isnot [string] -or $cli.status.ToLowerInvariant() -notin @('supported','partial','unsupported')) {
                throw "Invalid provider config at $basePath.status: supported, partial, or unsupported required."
            }
        }
        if (Test-ByokHasProperty $cli 'environment') { Assert-ByokEnvMap $cli.environment "$basePath.environment" }
        if (Test-ByokHasProperty $cli 'settings') { Assert-ByokEnvMap $cli.settings "$basePath.settings" }
        if (Test-ByokHasProperty $cli 'adapter') {
            if ($cli.adapter -cne 'opencode-config-v1') { throw "Invalid provider config at $basePath.adapter: unsupported adapter '$($cli.adapter)'." }
            if ($cli.configEnvName -cne 'OPENCODE_CONFIG') { throw "Invalid provider config at $basePath.configEnvName: must equal 'OPENCODE_CONFIG'." }
            if ($cli.configFileName -cne 'opencode.json') { throw "Invalid provider config at $basePath.configFileName: must equal 'opencode.json'." }
            if (-not (Test-ByokHasProperty $cli 'template') -or -not (Test-ByokJsonObject $cli.template)) {
                throw "Invalid provider config at $basePath.template: object required."
            }
            try { Assert-ByokOpenCodeTemplate $cli.template } catch { throw "Invalid provider config at $basePath.template: $($_.Exception.Message)" }
        } elseif ((Test-ByokHasProperty $cli 'template') -or (Test-ByokHasProperty $cli 'configEnvName') -or (Test-ByokHasProperty $cli 'configFileName')) {
            throw "Invalid provider config at ${basePath}: template, configEnvName, and configFileName require an adapter."
        }
    }

    foreach ($providerProperty in (Get-ByokObjectEntries $Config.providers)) {
        $id = $providerProperty.Name; $provider = $providerProperty.Value; $basePath = "$.providers.$id"
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid provider config at ${basePath}: invalid provider id." }
        if (-not (Test-ByokJsonObject $provider)) { throw "Invalid provider config at ${basePath}: object required." }

        if (Test-ByokHasProperty $provider 'baseUrl') {
            if (-not ($provider.baseUrl -is [string] -and $provider.baseUrl -eq '')) {
                $uri = $null
                if ($provider.baseUrl -isnot [string] -or -not [Uri]::TryCreate($provider.baseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
                    throw "Invalid provider config at $basePath.baseUrl: absolute http(s) URL without credentials/query/fragment required."
                }
            }
        }
        if (Test-ByokHasProperty $provider 'modelCacheTtlSeconds') {
            $ttl = $provider.modelCacheTtlSeconds
            $ttlValue = 0.0
            $ttlText = if ($null -ne $ttl) { [Convert]::ToString($ttl, [Globalization.CultureInfo]::InvariantCulture) } else { '' }
            if ($ttl -is [string] -or $ttl -is [bool] -or -not [double]::TryParse($ttlText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ttlValue) -or $ttlValue -lt 0) {
                throw "Invalid provider config at $basePath.modelCacheTtlSeconds: non-negative number required."
            }
        }
        foreach ($field in @('apiKeyEnv','apiKeyEnvNames','modelEnvNames')) {
            if (Test-ByokHasProperty $provider $field) {
                foreach ($name in @($provider.$field)) {
                    if ($name -isnot [string] -or $name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid provider config at $basePath.${field}: invalid environment variable name." }
                }
            }
        }
        if (Test-ByokHasProperty $provider 'apiKeyHeader') {
            if ($provider.apiKeyHeader -isnot [string] -or $provider.apiKeyHeader -notmatch "^[!#\$%&'*+.^_``|~0-9A-Za-z-]+$") {
                throw "Invalid provider config at $basePath.apiKeyHeader: invalid HTTP header name."
            }
        }
        if (Test-ByokHasProperty $provider 'apiKeyPrefix') {
            if ($provider.apiKeyPrefix -isnot [string]) {
                throw "Invalid provider config at $basePath.apiKeyPrefix: string required."
            }
            if ($provider.apiKeyPrefix -match '[\x00-\x1F\x7F]') {
                throw "Invalid provider config at $basePath.apiKeyPrefix: control characters are not allowed."
            }
        }
        if (Test-ByokHasProperty $provider 'modelsApi') {
            if (-not (Test-ByokJsonObject $provider.modelsApi)) { throw "Invalid provider config at $basePath.modelsApi: object required." }
            foreach ($field in @('path', 'itemsPath', 'idPath')) {
                if ((Test-ByokHasProperty $provider.modelsApi $field) -and $provider.modelsApi.$field -isnot [string]) {
                    throw "Invalid provider config at $basePath.modelsApi.${field}: string required."
                }
            }
            if (Test-ByokHasProperty $provider.modelsApi 'apiKeyPrefix') {
                if ($provider.modelsApi.apiKeyPrefix -isnot [string]) {
                    throw "Invalid provider config at $basePath.modelsApi.apiKeyPrefix: string required."
                }
                if ($provider.modelsApi.apiKeyPrefix -match '[\x00-\x1F\x7F]') {
                    throw "Invalid provider config at $basePath.modelsApi.apiKeyPrefix: control characters are not allowed."
                }
            }
            if ((Test-ByokHasProperty $provider.modelsApi 'path') -and $provider.modelsApi.path -match '[\x00-\x1F\x7F?#]') {
                throw "Invalid provider config at $basePath.modelsApi.path: control characters, query, and fragment are not allowed."
            }
            if (Test-ByokHasProperty $provider.modelsApi 'apiKeyHeader') {
                if ($provider.modelsApi.apiKeyHeader -isnot [string] -or $provider.modelsApi.apiKeyHeader -notmatch "^[!#\$%&'*+.^_``|~0-9A-Za-z-]+$") {
                    throw "Invalid provider config at $basePath.modelsApi.apiKeyHeader: invalid HTTP header name."
                }
            }
        }
        if (Test-ByokHasProperty $provider 'models') {
            if ($provider.models -isnot [System.Array]) { throw "Invalid provider config at $basePath.models: array required." }
            $modelIndex = 0
            foreach ($model in $provider.models) {
                $modelId = if ($model -is [string]) { $model } elseif (Test-ByokJsonObject $model) { $model.id } else { $null }
                if ($modelId -isnot [string] -or -not $modelId.Trim() -or $modelId.Length -gt 512 -or $modelId -match '[\x00-\x1F\x7F]') {
                    throw "Invalid provider config at $basePath.models[$modelIndex]: valid model ID required."
                }
                $modelIndex += 1
            }
        }
        if (Test-ByokHasProperty $provider 'environment') {
            if (-not (Test-ByokJsonObject $provider.environment)) { throw "Invalid provider config at $basePath.environment: object required." }
            foreach ($entry in (Get-ByokObjectEntries $provider.environment)) {
                $entryPath = "$basePath.environment.$($entry.Name)"
                if (Test-ByokJsonObject $entry.Value) {
                    if ($entry.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid provider config at ${entryPath}: invalid CLI id." }
                    Assert-ByokEnvMap $entry.Value $entryPath
                } else {
                    if ($entry.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid provider config at ${entryPath}: invalid environment variable name." }
                    $value = $entry.Value
                    $allowedScalar = $value -is [string] -or $value -is [bool] -or (Test-ByokJsonNumber $value)
                    if (-not $allowedScalar) {
                        throw "Invalid provider config at ${entryPath}: template value must be scalar (string, number, or boolean) or a CLI-specific environment object."
                    }
                }
            }
        }
        if (Test-ByokHasProperty $provider 'settings') { Assert-ByokEnvMap $provider.settings "$basePath.settings" }
    }
    return $Config
}

# --- provider config ----------------------------------------------------------

function Load-ByokProviderConfig {
    param([string]$DataDir = (Get-ByokDataDir), [switch]$ReadOnly)
    $configPath = Get-ByokConfigPath $DataDir -NoMigrate:$ReadOnly
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
    $cachePath = Get-ByokCachePath $DataDir
    return (Invoke-WithByokFileLock $cachePath {
    $cache = Read-ByokCache $DataDir
    # Normalize caches into a hashtable keyed by provider id.
    $caches = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
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
    $byId = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $maxOrder = 0
    foreach ($m in $existingModels) {
        $ord = if ($null -ne $m.order) { [int]$m.order } else { 0 }
        if ($ord -gt $maxOrder) { $maxOrder = $ord }
        $byId[$m.id] = [ordered]@{ id = $m.id; order = $ord; available = $false; firstSeen = $m.firstSeen; lastSeen = $m.lastSeen }
    }
    $seenList = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
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
    Write-ByokJsonAtomicUnlocked $cachePath $newCache
    return ($modelsList | Where-Object { $_.available } | ForEach-Object { $_.id })
    })
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

function Resolve-ByokChosenModelSelection {
    param([string]$RequestedModel, [string]$EnvironmentModel, [string]$RememberedModel, [string[]]$AvailableModels, [bool]$ProviderChanged)
    $requested = "$RequestedModel".Trim()
    if ($requested) { return [pscustomobject]@{ model = $requested; source = 'option' } }

    $containsExact = {
        param([string]$Candidate)
        foreach ($availableModel in @($AvailableModels)) {
            if ("$availableModel".Trim() -ceq $Candidate) { return $true }
        }
        return $false
    }
    $environment = "$EnvironmentModel".Trim()
    if ($environment -and (& $containsExact $environment)) {
        return [pscustomobject]@{ model = $environment; source = 'environment' }
    }
    $remembered = "$RememberedModel".Trim()
    if (-not $ProviderChanged -and $remembered -and (& $containsExact $remembered)) {
        return [pscustomobject]@{ model = $remembered; source = 'state' }
    }
    if (@($AvailableModels).Count -gt 0) {
        return [pscustomobject]@{ model = "$($AvailableModels[0])".Trim(); source = 'first-available' }
    }
    return [pscustomobject]@{ model = ''; source = 'first-available' }
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

function Get-ByokProviderEnvironmentMap {
    param($Provider)
    if (-not $Provider -or -not $Provider.environment) { return $null }
    $map = [ordered]@{}
    foreach ($property in (Get-ByokObjectEntries $Provider.environment)) {
        if (-not (Test-ByokJsonObject $property.Value)) { $map[$property.Name] = $property.Value }
    }
    return $map
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

    $providerEnvironment = Get-ByokProviderEnvironmentMap $Provider
    if ($providerEnvironment) {
        foreach ($p in (Get-ByokObjectEntries $providerEnvironment)) {
            $name = "$($p.Name)".Trim()
            if (-not $name) { continue }
            $val = "$($p.Value)"
            foreach ($k in $subs.Keys) { $val = $val.Replace($k, $subs[$k]) }
            $map[$name] = $val
        }
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

function Build-ByokAdapterRuntimeEnvMap {
    param($Provider, [string]$BaseUrl, [string]$Model, [string]$ApiKey, [string]$ProviderId, $Cli)
    # Config-file adapters follow the same configured environment contract as
    # every other CLI. Do not filter variables based on names such as
    # COPILOT_*; a configured environment entry is an explicit instruction.
    return Build-ByokRuntimeEnvMap $Provider $BaseUrl $Model $ApiKey $ProviderId $Cli
}

function Get-ByokOpenCodeProviderId {
    param([string]$ProviderId)
    $original = "$ProviderId"
    $slug = ($original.ToLowerInvariant() -replace '[^a-z0-9]+', '-' -replace '^-+|-+$', '')
    if (-not $slug) { $slug = 'provider' }
    if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).TrimEnd('-') }
    if (-not $slug) { $slug = 'provider' }

    $suffix = ''
    if ($original -cne $slug) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($original)) } finally { $sha.Dispose() }
        $hash = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 8)
        $suffix = "-$hash"
    }
    return "byok-bridge-$slug$suffix"
}

function Convert-ByokOpenCodeTemplateNode {
    param(
        $Value,
        [System.Collections.IDictionary]$Substitutions,
        [bool]$IncludeApiKeyReference,
        [string]$JsonPath = '$',
        [int]$Depth = 0,
        [string]$PropertyName = '',
        [string]$ParentName = ''
    )
    if ($Depth -gt 32) { throw 'OpenCode template exceeds the maximum depth of 32.' }
    if ($Value -is [string]) {
        $text = "$Value"
        if ($text -ceq '{models}') { return $Substitutions['{models}'] }
        if ($text -ceq '{api_key_ref}') { return $Substitutions['{api_key_ref}'] }
        foreach ($token in @('{url}', '{provider_id}', '{opencode_provider_id}', '{provider_name}', '{model}')) {
            $text = $text.Replace($token, "$($Substitutions[$token])")
        }
        return $text
    }
    if ($Value -is [System.Array]) {
        $items = @()
        for ($i = 0; $i -lt $Value.Count; $i++) {
            $items += ,(Convert-ByokOpenCodeTemplateNode $Value[$i] $Substitutions $IncludeApiKeyReference "$JsonPath[$i]" ($Depth + 1))
        }
        return ,$items
    }
    if (Test-ByokJsonObject $Value) {
        $result = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($entry in (Get-ByokObjectEntries $Value)) {
            $key = "$($entry.Name)"
            foreach ($token in @('{url}', '{provider_id}', '{opencode_provider_id}', '{provider_name}', '{model}')) {
                $key = $key.Replace($token, "$($Substitutions[$token])")
            }
            if ($result.Contains($key)) { throw "OpenCode template produced duplicate object key '$key' at $JsonPath." }
            if ($entry.Value -is [string] -and $entry.Value -ceq '{api_key_ref}' -and -not $IncludeApiKeyReference) { continue }
            $rendered = Convert-ByokOpenCodeTemplateNode $entry.Value $Substitutions $IncludeApiKeyReference "$JsonPath.$key" ($Depth + 1) $key $PropertyName
            $result.Add($key, $rendered)
        }
        return $result
    }
    return $Value
}

function Build-ByokOpenCodeConfig {
    param(
        $Template,
        [string]$ProviderId,
        [string]$ProviderName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [bool]$ApiKeyRequired,
        [string[]]$AvailableModels,
        [string]$ChosenModel,
        [string]$ChosenModelSource
    )
    Assert-ByokOpenCodeTemplate $Template
    $runtimeProviderId = Get-ByokOpenCodeProviderId $ProviderId
    $models = [System.Collections.Generic.List[string]]::new()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($rawModel in @($AvailableModels)) {
        $id = "$rawModel".Trim()
        if (-not $id -or -not $seen.Add($id)) { continue }
        if ($id.Length -gt 512 -or $id -match '[\x00-\x1F\x7F]') { throw "Invalid OpenCode model ID '$id'." }
        $models.Add($id)
        if ($models.Count -gt 4096) { throw 'OpenCode model list exceeds the maximum of 4096.' }
    }
    $selectedModel = "$ChosenModel".Trim()
    if ($ChosenModelSource -ceq 'option' -and $selectedModel -and -not $seen.Contains($selectedModel)) {
        if ($models.Count -ge 4096) { throw 'OpenCode model list exceeds the maximum of 4096.' }
        $seen.Add($selectedModel) | Out-Null
        $models.Add($selectedModel)
    }
    if (-not $selectedModel) { throw 'OpenCode requires a selected model.' }
    if (-not $seen.Contains($selectedModel)) { throw "Selected OpenCode model '$selectedModel' is not available." }

    $modelMap = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($id in $models) { $modelMap.Add($id, [ordered]@{ name = $id }) }
    $includeApiKeyReference = $ApiKeyRequired -or -not [string]::IsNullOrEmpty($ApiKey)
    $subs = [ordered]@{
        '{url}' = $BaseUrl
        '{provider_id}' = $ProviderId
        '{opencode_provider_id}' = $runtimeProviderId
        '{provider_name}' = $ProviderName
        '{model}' = $selectedModel
        '{models}' = $modelMap
        '{api_key_ref}' = '{env:BYOK_BRIDGE_OPENCODE_API_KEY}'
    }
    $config = Convert-ByokOpenCodeTemplateNode $Template $subs $includeApiKeyReference
    if (-not $config.Contains('$schema') -or $config['$schema'] -isnot [string] -or -not $config['$schema'].Trim()) {
        throw 'Generated OpenCode config must contain a non-empty $schema string.'
    }
    if ($config['model'] -cne "$runtimeProviderId/$selectedModel") { throw 'Generated OpenCode config has an invalid default model reference.' }
    if (-not $config['provider'].Contains($runtimeProviderId)) { throw "Generated OpenCode config is missing provider '$runtimeProviderId'." }
    $runtimeProvider = $config['provider'][$runtimeProviderId]
    foreach ($id in $models) {
        if (-not $runtimeProvider['models'].Contains($id)) { throw "Generated OpenCode config is missing model '$id'." }
    }
    $hasApiKey = $runtimeProvider['options'].Contains('apiKey')
    if ($includeApiKeyReference -and (-not $hasApiKey -or $runtimeProvider['options']['apiKey'] -cne '{env:BYOK_BRIDGE_OPENCODE_API_KEY}')) {
        throw 'Generated OpenCode config has an invalid API key environment reference.'
    }
    if (-not $includeApiKeyReference -and $hasApiKey) { throw 'Generated OpenCode config must omit options.apiKey.' }
    $json = $config | ConvertTo-Json -Depth 64
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 8388608) { throw 'Generated OpenCode config exceeds 8388608 UTF-8 bytes.' }
    if ($ApiKey.Length -ge 8 -and $json.Contains($ApiKey)) { throw 'Generated OpenCode config contains the plaintext API key.' }
    return [pscustomobject]@{ config = $config; runtimeProviderId = $runtimeProviderId; models = $models.ToArray() }
}

function Get-ByokOpenCodeConfigPath {
    param([string]$DataDir, [string]$FileName = 'opencode.json')
    if ($FileName -cne 'opencode.json') { throw "OpenCode configFileName must be 'opencode.json'." }
    return [IO.Path]::GetFullPath((Join-Path $DataDir $FileName))
}

function Write-ByokOpenCodeConfig {
    param([string]$Path, $Config)
    Write-ByokJsonAtomic $Path $Config
    return $Path
}

# --- model fetch --------------------------------------------------------------

function New-ByokModelFetchError {
    param([string]$Message, [string]$Category = 'response')
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['ByokModelFetchError'] = $true
    $exception.Data['ByokModelFetchCategory'] = $Category
    return $exception
}

function Wait-ByokTaskUntil {
    param(
        [System.Threading.Tasks.Task]$Task,
        [DateTime]$Deadline,
        [System.Threading.CancellationTokenSource]$Cancellation
    )
    $remaining = $Deadline - [DateTime]::UtcNow
    if ($remaining.TotalMilliseconds -le 0) {
        $Cancellation.Cancel()
        throw (New-Object System.OperationCanceledException)
    }

    $delay = [System.Threading.Tasks.Task]::Delay($remaining)
    $completed = [System.Threading.Tasks.Task]::WhenAny(
        [System.Threading.Tasks.Task[]]@($Task, $delay)
    ).GetAwaiter().GetResult()
    if (-not [object]::ReferenceEquals($completed, $Task)) {
        $Cancellation.Cancel()
        throw (New-Object System.OperationCanceledException)
    }
    return $Task.GetAwaiter().GetResult()
}

function Invoke-ByokModelFetch {
    param(
        $Provider,
        [string]$BaseUrl,
        [string]$ApiKey,
        [int]$TimeoutSeconds = 10,
        [int]$MaximumBytes = 2097152
    )
    if ($TimeoutSeconds -le 0) { throw 'Request timeout must be greater than zero seconds.' }
    if ($MaximumBytes -le 0) { throw 'Maximum response size must be greater than zero bytes.' }

    $api = $Provider.modelsApi
    if (-not $api) { $api = [pscustomobject]@{} }
    $apiPath = if ($api.path) { $api.path } else { '/models' }
    $baseUri = $null
    if (-not [Uri]::TryCreate("$BaseUrl".Trim(), [UriKind]::Absolute, [ref]$baseUri) -or
        $baseUri.Scheme -notin @('http', 'https') -or $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) {
        throw 'Base URL must be an absolute http(s) URL without credentials, query, or fragment.'
    }
    if ("$apiPath" -match '[\x00-\x1F\x7F?#]') { throw 'Models API path must not contain control characters, query, or fragment.' }
    $cleanBase = $baseUri.AbsoluteUri.TrimEnd('/')
    if (-not $apiPath.StartsWith('/')) { $apiPath = '/' + $apiPath }
    $fullUrl = "$cleanBase$apiPath"
    $fullUri = $null
    if (-not [Uri]::TryCreate($fullUrl, [UriKind]::Absolute, [ref]$fullUri) -or
        $fullUri.Scheme -notin @('http', 'https') -or $fullUri.UserInfo -or $fullUri.Query -or $fullUri.Fragment) {
        throw 'Resolved models URL is invalid.'
    }
    $safeOrigin = $fullUri.GetLeftPart([System.UriPartial]::Authority)

    $headerName = if ($api.apiKeyHeader) { "$($api.apiKeyHeader)" } elseif ($Provider.apiKeyHeader) { "$($Provider.apiKeyHeader)" } else { 'Authorization' }
    if ($headerName -notmatch "^[!#\$%&'*+.^_``|~0-9A-Za-z-]+$") { throw 'Configured API key header name is invalid.' }
    $prefix = if ($api.PSObject.Properties.Name -contains 'apiKeyPrefix') { "$($api.apiKeyPrefix)" } elseif ($Provider.PSObject.Properties.Name -contains 'apiKeyPrefix') { "$($Provider.apiKeyPrefix)" } else { 'Bearer ' }

    if ($ApiKey) {
        $headerValue = "$prefix$ApiKey"
        if ($headerValue -match '[\x00-\x1F\x7F]') {
            throw (New-ByokModelFetchError 'API key or prefix contains invalid control characters.' 'config')
        }
    }

    Add-Type -AssemblyName System.Net.Http
    $handler = $null
    $client = $null
    $cancellation = $null
    $response = $null
    $stream = $null
    $memory = $null
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
        if ($ApiKey) {
            if (-not $client.DefaultRequestHeaders.TryAddWithoutValidation($headerName, $headerValue)) {
                throw (New-ByokModelFetchError 'API key header could not be added to the request.' 'config')
            }
        }

        $cancellation = New-Object System.Threading.CancellationTokenSource
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $responseTask = $client.GetAsync(
            $fullUri,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token
        )
        $response = Wait-ByokTaskUntil $responseTask $deadline $cancellation
        if (-not $response.IsSuccessStatusCode) {
            $statusCode = [int]$response.StatusCode
            $category = if ($statusCode -in @(401, 403)) { 'auth' } else { 'transport' }
            throw (New-ByokModelFetchError "Provider at $safeOrigin returned HTTP $statusCode." $category)
        }
        $mediaType = if ($response.Content.Headers.ContentType) { "$($response.Content.Headers.ContentType.MediaType)" } else { '' }
        if ($mediaType -notmatch '(?i)(^|[+/])json$') {
            $displayMediaType = if ([string]::IsNullOrWhiteSpace($mediaType)) { 'unknown' } else { $mediaType }
            throw (New-ByokModelFetchError "Expected a JSON response from $safeOrigin; received '$displayMediaType'." 'response')
        }
        $declaredLength = $response.Content.Headers.ContentLength
        if ($null -ne $declaredLength -and [long]$declaredLength -gt $MaximumBytes) {
            throw (New-ByokModelFetchError "Provider response exceeds the $MaximumBytes-byte limit." 'response')
        }

        $streamTask = $response.Content.ReadAsStreamAsync()
        $stream = Wait-ByokTaskUntil $streamTask $deadline $cancellation
        $memory = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 8192
        $total = 0
        while ($true) {
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token)
            $read = Wait-ByokTaskUntil $readTask $deadline $cancellation
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $MaximumBytes) { throw (New-ByokModelFetchError "Provider response exceeds the $MaximumBytes-byte limit." 'response') }
            $memory.Write($buffer, 0, $read)
        }
        $body = [Text.Encoding]::UTF8.GetString($memory.ToArray()).TrimStart([char]0xFEFF)
        try {
            if ($body.TrimStart().StartsWith('[')) { $resp = @($body | ConvertFrom-Json -ErrorAction Stop) }
            else { $resp = $body | ConvertFrom-Json -ErrorAction Stop }
        } catch {
            throw (New-ByokModelFetchError "Provider at $safeOrigin returned invalid JSON." 'response')
        }
    } catch [System.OperationCanceledException] {
        throw (New-ByokModelFetchError "Request timed out after $TimeoutSeconds seconds when connecting to $safeOrigin." 'transport')
    } catch {
        $message = $_.Exception.Message
        if ($_.Exception.Data['ByokModelFetchError'] -eq $true) { throw }
        throw (New-ByokModelFetchError "Unable to fetch models from ${safeOrigin}: $message" 'transport')
    } finally {
        if ($memory) { $memory.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
        if ($cancellation) { $cancellation.Dispose() }
    }

    $itemsPath = if ($api.itemsPath) { "$($api.itemsPath)" } else { 'data' }
    $idPath = if ($api.idPath) { "$($api.idPath)" } else { 'id' }
    $items = $resp
    foreach ($part in ($itemsPath -split '\.' | Where-Object { $_ })) {
        if ($null -eq $items) { break }
        $property = $items.PSObject.Properties[$part]
        if ($property) { $items = $property.Value } else { $items = $null }
    }
    if ($null -eq $items -and $resp -is [System.Array]) { $items = $resp }
    if ($null -eq $items -or $items -is [string] -or $items -isnot [System.Collections.IEnumerable]) {
        throw (New-ByokModelFetchError "Provider response from $safeOrigin does not contain an array at '$itemsPath'." 'response')
    }

    $ids = [System.Collections.Generic.List[string]]::new()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($item in @($items)) {
        $cur = $item
        if ($item -isnot [string]) {
            foreach ($part in ($idPath -split '\.' | Where-Object { $_ })) {
                if ($null -eq $cur) { break }
                $property = $cur.PSObject.Properties[$part]
                if ($property) { $cur = $property.Value } else { $cur = $null }
            }
        }
        if ($null -ne $cur) {
            $s = "$cur".Trim()
            if ($s -and $s.Length -le 512 -and $s -notmatch '[\x00-\x1F\x7F]' -and $seen.Add($s)) { $ids.Add($s) }
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
    $apiKeyProvided = -not [string]::IsNullOrWhiteSpace($ApiKey)

    $provider = [pscustomobject][ordered]@{
        name          = $name
        enabled       = $true
        type          = 'openai'
        baseUrl       = $url
        apiKeyRequired = $apiKeyProvided
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
    Resolve-ByokChosenModel, Resolve-ByokChosenModelSelection, Get-ByokCliSupportStatus, Expand-ByokTemplateValue, Resolve-ByokCliArgs,
    Build-ByokRuntimeEnvMap, Build-ByokAdapterRuntimeEnvMap, Invoke-ByokModelFetch, Add-ByokProvider, Get-ByokApiKeySource,
    Assert-ByokProviderConfig, Assert-ByokOpenCodeTemplate, Get-ByokOpenCodeProviderId,
    Build-ByokOpenCodeConfig, Get-ByokOpenCodeConfigPath, Write-ByokOpenCodeConfig
