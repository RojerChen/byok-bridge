#requires -Version 5.1
<#
    start-byok-cli-hub.ps1 — BYOK CLI Hub manager (PowerShell).
    1. select a CLI to launch (copilot, gemini, aider, …) from clis config
    2. list providers / pick one (or -Provider <id>)
    3. resolve baseUrl / apiKey (flags, env, or interactive prompt)
    4. GET {baseUrl}/models, update models-cache.json + state.json
    5. apply BYOK env vars to the current PowerShell session
    6. launch the selected CLI (inherits the session env)

    Copilot integration can run /model_byok to switch models from the cache.
#>
[CmdletBinding()]
param(
    [string]$Provider,
    [string]$Cli,
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$Model,
    [switch]$DryRun,
    [switch]$Refresh,
    [switch]$EmitEnv,
    [ValidateSet('cmd', 'ps')][string]$EmitEnvFormat = 'cmd',
    [string]$EnvFile,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$LaunchArgs
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ByokManager.psm1') -DisableNameChecking -ErrorAction Stop
function Write-Err([string]$Msg) { Write-Host $Msg -ForegroundColor Red }
function Write-Inf([string]$Msg) { Write-Host $Msg -ForegroundColor DarkGray }

function Read-SecureStringAsPlain {
    param([string]$Prompt)
    $ss = Read-Host $Prompt -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-SelectionIndex {
    param($Items, [string]$RememberedId)
    if (-not $RememberedId) { return $null }
    $list = @($Items)
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i].id -and "$($list[$i].id)" -eq $RememberedId) { return $i }
    }
    return $null
}

function Get-OptionalValue {
    param([string]$Value)
    if ($null -eq $Value) { return $null }
    $trimmed = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }
    return $trimmed
}

function Write-DefaultMenuItem {
    param([string]$Text, [int]$Index, [bool]$IsDefault)
    if ($IsDefault) {
        Write-Host ("{0}. {1}" -f $Index, $Text) -ForegroundColor Green
    } else {
        Write-Host ("{0}. {1}" -f $Index, $Text)
    }
}

function Format-ByokCliArgsForShell {
    param([string[]]$Values)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @($Values)) {
        if ($null -eq $arg) { continue }
        $text = [string]$arg
        if ($text -match '[\s"]') {
            $escaped = $text -replace '"', '""'
            $parts.Add(('"{0}"' -f $escaped))
        } else {
            $parts.Add($text)
        }
    }
    return [string]::Join(' ', $parts)
}

# Interactive flow that captures a new provider, writes it into providers.json,
# tells the user the config file path, applies the API key env var to this
# session, then reloads and returns the freshly added provider object.
function Invoke-AddProviderFlow {
    param($Cli = $null)
    Write-Host '--- Add a new provider ---' -ForegroundColor Cyan
    $name = (Read-Host 'Provider display name').Trim()
    if (-not $name) { Write-Err 'Provider name is required.'; exit 1 }
    $url = (Read-Host 'Base URL (e.g. https://api.example.com/v1)').Trim()
    if (-not $url) { Write-Err 'Base URL is required.'; exit 1 }
    $key = (Read-SecureStringAsPlain 'API key (optional, press Enter to skip)').Trim()

    $result = Add-ByokProvider -Name $name -BaseUrl $url -ApiKey $key -Cli $Cli -DataDir $dataDir
    Write-Host ("Provider '{0}' added with id '{1}'." -f $name, $result.id) -ForegroundColor Green
    Write-Host ("Config file: {0}" -f $result.configPath) -ForegroundColor Yellow
    Write-Host 'Edit that file yourself to customize advanced settings (type, headers, modelsApi, environment, etc.).' -ForegroundColor DarkGray
    Write-Host ''

    if ($key) { Set-Item -Path ("Env:{0}" -f $result.apiKeyEnvName) -Value $key }

    $cfg2 = Load-ByokProviderConfig $dataDir
    $newProvider = ($cfg2.providers | Where-Object { $_.id -eq $result.id } | Select-Object -First 1)
    if (-not $newProvider) { Write-Err 'Failed to reload the newly added provider.'; exit 1 }
    return $newProvider
}

try {
    # Start every interactive run with a clean console.
    try { Clear-Host } catch { }
    $dataDir = Get-ByokDataDir
    $cfg = Load-ByokProviderConfig $dataDir
    $providers = @($cfg.providers)
    $clis = @($cfg.clis)
    $state = Read-ByokState $dataDir
    $rememberedCliId = if ($state -and $state.cliId) { "$($state.cliId)".Trim() } else { $null }
    $rememberedProviderId = if ($state -and $state.providerId) { "$($state.providerId)".Trim() } else { $null }
    $rememberedModel = if ($state -and $state.model) { "$($state.model)".Trim() } else { $null }
    $cliArg = if ($PSBoundParameters.ContainsKey('Cli')) { Get-OptionalValue $Cli } else { $null }
    $providerArg = if ($PSBoundParameters.ContainsKey('Provider')) { Get-OptionalValue $Provider } else { $null }
    Write-Inf "Using provider config: $($cfg.configPath)"
    if ($providers.Count -eq 0) { Write-Err 'No enabled providers were found.'; exit 1 }

    # --- CLI selection -------------------------------------------------------
    # If no clis are configured, fall back to a copilot default so existing
    # setups keep working unchanged.
    if ($clis.Count -eq 0) {
        $clis = @([pscustomobject][ordered]@{
            id = 'copilot'
            name = 'GitHub Copilot CLI'
            command = 'copilot'
            args = @('--experimental')
            modelEnvName = 'COPILOT_MODEL'
            capabilities = [pscustomobject]@{ status = 'supported'; providerEnv = $true; apiKeyEnv = $true; modelEnv = $true }
        })
    }

    $configuredClis = @($clis)
    $clis = @($configuredClis | Where-Object { (Get-ByokCliSupportStatus $_) -ne 'unsupported' })
    if ($clis.Count -eq 0) { Write-Err 'No supported or partial CLIs were found.'; exit 1 }

    $selectedCli = $null
    if ($clis.Count -eq 1) {
        $selectedCli = $clis[0]
    } elseif ($cliArg) {
        $selectedCli = $configuredClis | Where-Object { $_.id -eq $cliArg } | Select-Object -First 1
        if (-not $selectedCli) { Write-Err "Unknown CLI: $cliArg"; exit 1 }
        if ((Get-ByokCliSupportStatus $selectedCli) -eq 'unsupported') {
            Write-Err "CLI '$cliArg' is marked unsupported for the BYOK environment flow."; exit 1
        }
    }
    if (-not $selectedCli) {
        $rememberedCliIndex = Get-SelectionIndex $clis $rememberedCliId
        $cliDefaultDisplay = if ($null -ne $rememberedCliIndex) { ($rememberedCliIndex + 1) } else { 1 }
        Write-Host 'Available CLIs:'
        for ($c = 0; $c -lt $clis.Count; $c++) {
            $isDefault = $null -ne $rememberedCliIndex -and $c -eq $rememberedCliIndex
            $status = Get-ByokCliSupportStatus $clis[$c]
            $suffix = if ($status -eq 'partial') { ' [partial]' } else { '' }
            Write-DefaultMenuItem ('{0} ({1}){2}' -f $clis[$c].name, $clis[$c].id, $suffix) ($c + 1) $isDefault
        }
        $cliLine = Read-Host "Select CLI [1-$($clis.Count)] (default: $cliDefaultDisplay)"
        $cliLine = "$cliLine".Trim()
        $cliIdx = if ($cliLine -eq '') {
            if ($null -ne $rememberedCliIndex) { $rememberedCliIndex } else { 0 }
        } else {
            ([int]$cliLine - 1)
        }
        if ($cliIdx -lt 0 -or $cliIdx -ge $clis.Count) { Write-Err 'Invalid CLI selection.'; exit 1 }
        $selectedCli = $clis[$cliIdx]
    }
    Write-Inf "Selected CLI: $($selectedCli.name) ($($selectedCli.id))"
    $cliStatus = Get-ByokCliSupportStatus $selectedCli
    if ($cliStatus -eq 'partial') {
        $reason = if ($selectedCli.capabilities.reason) { $selectedCli.capabilities.reason } else { 'This CLI may require additional configuration.' }
        Write-Host "Warning: CLI '$($selectedCli.id)' is partial. $reason" -ForegroundColor Yellow
    }

    # --- Provider selection --------------------------------------------------
    $rememberedProviderIndex = Get-SelectionIndex $providers $rememberedProviderId
    $addIdx = $providers.Count + 1
    Write-Host 'Available providers:'
    for ($i = 0; $i -lt $providers.Count; $i++) {
        $isDefault = $null -ne $rememberedProviderIndex -and $i -eq $rememberedProviderIndex
        Write-DefaultMenuItem ('{0} ({1})' -f $providers[$i].name, $providers[$i].id) ($i + 1) $isDefault
    }
    Write-Host ('{0}. Add a new provider...' -f $addIdx) -ForegroundColor Cyan

    $selected = $null
    if ($providerArg) {
        if ($providerArg -eq '+') {
            $selected = Invoke-AddProviderFlow -Cli $selectedCli
        } else {
            $selected = $providers | Where-Object { $_.id -eq $providerArg } | Select-Object -First 1
            if (-not $selected) { Write-Err "Unknown provider: $providerArg"; exit 1 }
        }
    }
    if (-not $selected) {
        $providerDefaultDisplay = if ($null -ne $rememberedProviderIndex) { ($rememberedProviderIndex + 1) } else { 1 }
        $prompt = "Select provider [1-$addIdx] (default: $providerDefaultDisplay)"
        $line = Read-Host $prompt
        $line = "$line".Trim()
        $idx = if ($line -eq '') {
            if ($null -ne $rememberedProviderIndex) { $rememberedProviderIndex } else { 0 }
        } else {
            ([int]$line - 1)
        }
        if ($idx -lt 0 -or $idx -gt $providers.Count) { Write-Err 'Invalid provider selection.'; exit 1 }
        if ($idx -eq $providers.Count) {
            $selected = Invoke-AddProviderFlow -Cli $selectedCli
        } else {
            $selected = $providers[$idx]
        }
    }

    $providerBaseUrl = if ($selected.baseUrl) { $selected.baseUrl } else { '' }
    if ($BaseUrl) { $base = $BaseUrl }
    elseif ($providerBaseUrl) { $base = $providerBaseUrl }
    else { $base = (Read-Host "Base URL [$providerBaseUrl]").Trim(); if (-not $base) { $base = $providerBaseUrl } }
    $base = $base.Trim().TrimEnd('/')
    if (-not $base) { Write-Err 'No base URL could be determined.'; exit 1 }

    $keyEnvName = Get-ByokApiKeyEnvName $selected
    $envApiKey = Resolve-ByokEnvValue $(if ($selected.apiKeyEnvNames) { $selected.apiKeyEnvNames } else { $selected.apiKeyEnv })
    $fromPrompt = $false
    $apiKey = if ($ApiKey) { $ApiKey }
              elseif ($envApiKey) { $envApiKey }
              else { '' }

    $apiPath = if ($selected.modelsApi -and $selected.modelsApi.path) { $selected.modelsApi.path } else { '/models' }
    $modelCacheTtlSeconds = Get-ByokModelCacheTtlSeconds $selected
    $cachedModelIds = @()
    $useCachedModels = $false
    if ($modelCacheTtlSeconds -gt 0) {
        $cachedModelIds = @(Get-ByokCachedModelIds $selected.id $dataDir)
        $useCachedModels = $cachedModelIds.Count -gt 0 -and (Test-ByokModelCacheFresh $selected.id $selected $dataDir)
    }

    $modelIds = @()
    $promptedForApiKey = $false
    if ($useCachedModels) {
        $modelIds = @($cachedModelIds)
        $available = @($cachedModelIds)
        Write-Inf "Using cached models for $($selected.id) (ttl=$modelCacheTtlSeconds sec)"
    } else {
        Write-Inf "Fetching models from $base..."
        try {
            $modelIds = @(Invoke-ByokModelFetch $selected $base $apiKey)
        } catch {
            $errorMsg = "$($_.Exception.Message)"
            $shouldPromptForApiKey = (-not $apiKey) -and ($selected.apiKeyRequired -ne $false) -and (-not $promptedForApiKey) -and ($errorMsg -match '401|403|Unauthorized|Forbidden|auth')
            if ($shouldPromptForApiKey) {
                $apiKey = (Read-SecureStringAsPlain 'API key').Trim()
                $fromPrompt = $true
                $promptedForApiKey = $true
                $modelIds = @(Invoke-ByokModelFetch $selected $base $apiKey)
            } else {
                throw
            }
        }
        if ($modelIds.Count -eq 0) { Write-Err 'No models were returned by the provider.'; exit 1 }

        $available = @(Update-ByokCacheForProvider $selected.id $base $apiPath $modelIds $dataDir)
        Write-Inf "Saved $($modelIds.Count) models to $(Join-Path $dataDir 'models-cache.json')"
    }

    $modelFallbackEnv = if ($selectedCli.modelEnvName) { $selectedCli.modelEnvName } else { $null }
    $envModel = [Environment]::GetEnvironmentVariable($modelFallbackEnv)
    $availableModelSet = @($available)
    $providerChanged = ($rememberedProviderId -and $selected.id -ne $rememberedProviderId)
    $chosenModel = Resolve-ByokChosenModel $Model $envModel $rememberedModel $availableModelSet $providerChanged

    $resolvedCliArgs = @(Resolve-ByokCliArgs $selectedCli $selected $base $chosenModel $apiKey $selected.id)
    $resolvedLaunchArgs = @($resolvedCliArgs)
    if ($LaunchArgs) { $resolvedLaunchArgs += @($LaunchArgs) }

    $envMap = Build-ByokRuntimeEnvMap $selected $base $chosenModel $apiKey $selected.id $selectedCli

    $state = [ordered]@{
        cliId           = $selectedCli.id
        cliName         = $selectedCli.name
        providerId      = $selected.id
        providerName    = $selected.name
        providerType    = if ($selected.type) { $selected.type } else { 'openai' }
        baseUrl         = $base
        model           = $chosenModel
        apiKeySource    = Get-ByokApiKeySource $keyEnvName $fromPrompt
        updatedAt       = (Get-Date).ToString('o')
    }
    Write-ByokState $state $dataDir

    Write-Inf "Provider: $($selected.name)"
    Write-Inf "Model: $chosenModel"
    Write-Inf ("API key: " + ('*' * [Math]::Max(8, $apiKey.Length)))

    if ($EmitEnv) {
        foreach ($k in $envMap.Keys) {
            $v = $envMap[$k]
            if ($EmitEnvFormat -eq 'ps') { Write-Output ('$env:{0} = ''{1}''' -f $k, ($v -replace "'", "''")) }
            else { Write-Output ('set "{0}={1}"' -f $k, ($v -replace '"', '""')) }
        }
        return
    }

    # -EnvFile: write set "KEY=value" lines for the calling shell (CMD) to `call`.
    # Used by the BYOK CLI Hub CMD shim so env vars land in the CMD console
    # (and persist there, so the API key is remembered on the next launch).
    if ($EnvFile) {
        $lines = @()
        foreach ($k in $envMap.Keys) {
            $v = [string]$envMap[$k]
            $lines += ('set "{0}={1}"' -f $k, ($v -replace '"', '""'))
        }
        # Embed the selected CLI's command + args so the CMD shim can launch
        # the right CLI without hardcoding copilot.
        $cliCmd = if ($selectedCli.command) { $selectedCli.command } else { 'copilot' }
        $cliArgsStr = Format-ByokCliArgsForShell $resolvedLaunchArgs
        $lines += ('set "__BYOK_CLI_COMMAND={0}"' -f $cliCmd)
        if ($cliArgsStr) { $lines += ('set "__BYOK_CLI_ARGS={0}"' -f $cliArgsStr) }
        $dir = Split-Path -Parent $EnvFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($EnvFile, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
        return
    }

    if ($DryRun -or $Refresh) { Write-Inf 'Dry run complete.'; return }

    Write-Host 'Applying BYOK environment in the current session...' -ForegroundColor Cyan
    foreach ($k in $envMap.Keys) { Set-Item -Path "Env:$k" -Value $envMap[$k] }

    $cliCmdName = if ($selectedCli.command) { $selectedCli.command } else { 'copilot' }

    Write-Host "Launching $($selectedCli.name)..." -ForegroundColor Cyan
    $cliExe = (Get-Command $cliCmdName -ErrorAction SilentlyContinue)
    if (-not $cliExe) { Write-Err "The '$cliCmdName' command was not found in PATH."; exit 5 }

    & $cliExe.Source @resolvedLaunchArgs
    exit $LASTEXITCODE
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
