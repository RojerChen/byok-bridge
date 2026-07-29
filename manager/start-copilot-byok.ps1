#requires -Version 5.1
<#
    start-copilot-byok.ps1 — BYOK CLI Hub manager implementation (PowerShell).
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

function Resolve-ByokCmdExecutable {
    param([string]$CommandName)
    $commands = @(Get-Command $CommandName -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        $path = if ($command.Source) { "$($command.Source)" } elseif ($command.Path) { "$($command.Path)" } else { '' }
        $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($command.CommandType -eq [Management.Automation.CommandTypes]::Application -and
            $extension -in @('.com', '.exe', '.bat', '.cmd')) {
            return $command
        }
    }
    return $null
}

function Format-ByokCliArgsForCmd {
    param([string[]]$Values)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @($Values)) {
        if ($null -eq $arg) { continue }
        $text = [string]$arg
        if ($text -match '[\s"]') {
            $parts.Add(('"{0}"' -f ($text -replace '"', '""')))
        } else {
            $parts.Add($text)
        }
    }
    return [string]::Join(' ', $parts)
}

function ConvertTo-ByokCmdSetLine {
    param([string]$Name, [AllowEmptyString()][string]$Value)
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Cannot write invalid CMD environment variable name '$Name'."
    }
    if ($Value -match '[\x00\r\n]') {
        throw "Environment variable '$Name' contains a value that cannot be represented in a CMD launch plan."
    }
    if ($Value.Contains('"')) {
        throw "Environment variable '$Name' contains a double quote that cannot be safely applied to the caller CMD session."
    }
    # Percent signs are expanded while CMD parses a batch file, including
    # inside set's quoted assignment form. Doubling preserves the literal.
    return ('set "{0}={1}"' -f $Name, $Value.Replace('%', '%%'))
}

function Write-ByokCmdLaunchPlan {
    param(
        [string]$Path,
        $Environment,
        [string]$Executable,
        [string[]]$Arguments,
        [string]$CliId,
        [bool]$Launch
    )
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'The CMD launch-plan path must be absolute.' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('@echo off')
    if ($Launch) {
        foreach ($name in $Environment.Keys) {
            $lines.Add((ConvertTo-ByokCmdSetLine $name ([string]$Environment[$name])))
        }
        $lines.Add((ConvertTo-ByokCmdSetLine '__BYOK_CLI_HUB_ACTION' 'launch'))
        $lines.Add((ConvertTo-ByokCmdSetLine '__BYOK_CLI_HUB_EXECUTABLE' $Executable))
        $lines.Add((ConvertTo-ByokCmdSetLine '__BYOK_CLI_HUB_ARGUMENTS' (Format-ByokCliArgsForCmd $Arguments)))
        $lines.Add((ConvertTo-ByokCmdSetLine '__BYOK_CLI_HUB_CLI_ID' $CliId))
    } else {
        $lines.Add((ConvertTo-ByokCmdSetLine '__BYOK_CLI_HUB_ACTION' 'none'))
    }

    $directory = Split-Path -Parent $Path
    if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "CMD launch-plan directory does not exist: $directory"
    }
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding $false))
        foreach ($line in $lines) { $writer.WriteLine($line) }
        $writer.Flush()
        $stream.Flush()
    } finally {
        if ($writer) { $writer.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Write-DefaultMenuItem {
    param([string]$Text, [int]$Index, [bool]$IsDefault)
    if ($IsDefault) {
        Write-Host ("{0}. {1}" -f $Index, $Text) -ForegroundColor Green
    } else {
        Write-Host ("{0}. {1}" -f $Index, $Text)
    }
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
    $dataDir = Get-ByokDataDir -NoCreate:$DryRun
    $cfg = Load-ByokProviderConfig $dataDir -ReadOnly:$DryRun
    $providers = @($cfg.providers)
    $clis = @($cfg.clis)
    $state = Read-ByokState $dataDir
    $rememberedCliId = if ($state -and $state.cliId) { "$($state.cliId)".Trim() } else { $null }
    $rememberedProviderId = if ($state -and $state.providerId) { "$($state.providerId)".Trim() } else { $null }
    $rememberedModel = if ($state -and $state.model) { "$($state.model)".Trim() } else { $null }
    $cliArg = if ($PSBoundParameters.ContainsKey('Cli')) { Get-OptionalValue $Cli } else { $null }
    $providerArg = if ($PSBoundParameters.ContainsKey('Provider')) { Get-OptionalValue $Provider } else { $null }
    if ($DryRun -and $providerArg -eq '+') { throw "-DryRun cannot be combined with -Provider '+', because adding a provider is a persistent change." }
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
    if ($cliArg) {
        $selectedCli = $configuredClis | Where-Object { $_.id -eq $cliArg } | Select-Object -First 1
        if (-not $selectedCli) { Write-Err "Unknown CLI: $cliArg"; exit 1 }
        if ((Get-ByokCliSupportStatus $selectedCli) -eq 'unsupported') {
            Write-Err "CLI '$cliArg' is marked unsupported for the BYOK environment flow."; exit 1
        }
    } elseif ($clis.Count -eq 1) {
        $selectedCli = $clis[0]
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
    $allowAddProvider = -not $DryRun
    $addIdx = if ($allowAddProvider) { $providers.Count + 1 } else { $providers.Count }
    Write-Host 'Available providers:'
    for ($i = 0; $i -lt $providers.Count; $i++) {
        $isDefault = $null -ne $rememberedProviderIndex -and $i -eq $rememberedProviderIndex
        Write-DefaultMenuItem ('{0} ({1})' -f $providers[$i].name, $providers[$i].id) ($i + 1) $isDefault
    }
    if ($allowAddProvider) { Write-Host ('{0}. Add a new provider...' -f $addIdx) -ForegroundColor Cyan }

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
        if ($idx -lt 0 -or $idx -ge $addIdx) { Write-Err 'Invalid provider selection.'; exit 1 }
        if ($allowAddProvider -and $idx -eq $providers.Count) {
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
    $fromArgument = $PSBoundParameters.ContainsKey('ApiKey') -and -not [string]::IsNullOrWhiteSpace($ApiKey)
    $apiKey = if ($ApiKey) { $ApiKey }
              elseif ($envApiKey) { $envApiKey }
              else { '' }
    if (-not $DryRun -and -not $apiKey -and $selected.apiKeyRequired -ne $false) {
        $apiKey = (Read-SecureStringAsPlain "API key for '$($selected.name)'").Trim()
        $fromPrompt = $true
        if (-not $apiKey) { Write-Err "API key is required for provider '$($selected.name)'."; exit 1 }
    }

    $apiPath = if ($selected.modelsApi -and $selected.modelsApi.path) { $selected.modelsApi.path } else { '/models' }
    $modelCacheTtlSeconds = Get-ByokModelCacheTtlSeconds $selected
    $cachedModelIds = @(Get-ByokCachedModelIds $selected.id $dataDir)
    $cacheEntry = Get-ByokProviderCacheEntry $selected.id $dataDir
    $cacheEntryApiPath = if ($cacheEntry.apiPath) { $cacheEntry.apiPath } else { $cacheEntry.modelsApiPath }
    $cacheIdentityMatches = $cacheEntry -and "$($cacheEntry.baseUrl)".TrimEnd('/') -eq "$base".TrimEnd('/') -and "$cacheEntryApiPath" -eq "$apiPath"
    $useCachedModels = $modelCacheTtlSeconds -gt 0 -and $cachedModelIds.Count -gt 0 -and
        (Test-ByokModelCacheFresh $selected.id $selected $dataDir $base $apiPath)

    $staticModelIds = @()
    $staticModelSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($configuredModel in @($selected.models)) {
        if ($configuredModel -is [string]) { $configuredId = "$configuredModel".Trim() }
        elseif ($configuredModel -and $configuredModel.available -ne $false) { $configuredId = "$($configuredModel.id)".Trim() }
        else { $configuredId = '' }
        if ($configuredId -and $staticModelSeen.Add($configuredId)) { $staticModelIds += $configuredId }
    }

    $modelIds = @()
    $available = @()
    $promptedForApiKey = $false
    if ($staticModelIds.Count -gt 0) {
        $modelIds = @($staticModelIds)
        $available = @($staticModelIds)
        Write-Inf "Using $($staticModelIds.Count) statically configured models."
    } elseif ($DryRun) {
        $available = if ($cacheIdentityMatches) { @($cachedModelIds) } else { @() }
        $modelIds = @($available)
        Write-Inf 'Dry run: network and cache updates were skipped.'
    } elseif ($useCachedModels -and -not $Refresh) {
        $modelIds = @($cachedModelIds)
        $available = @($cachedModelIds)
        Write-Inf "Using cached models for $($selected.id) (ttl=$modelCacheTtlSeconds sec)"
    } else {
        Write-Inf "Fetching models from $base..."
        $fetchError = $null
        try {
            $modelIds = @(Invoke-ByokModelFetch $selected $base $apiKey)
        } catch {
            $errorMsg = "$($_.Exception.Message)"
            $shouldPromptForApiKey = (-not $apiKey) -and ($selected.apiKeyRequired -ne $false) -and (-not $promptedForApiKey) -and ($errorMsg -match '401|403|Unauthorized|Forbidden|auth')
            if ($shouldPromptForApiKey) {
                $apiKey = (Read-SecureStringAsPlain 'API key').Trim()
                $fromPrompt = $true
                $promptedForApiKey = $true
                try { $modelIds = @(Invoke-ByokModelFetch $selected $base $apiKey) } catch { $fetchError = $_ }
            } else {
                $fetchError = $_
            }
        }
        if ($fetchError) {
            $fetchCategory = "$($fetchError.Exception.Data['ByokModelFetchCategory'])"
            $canUseStaleCache = $fetchCategory -in @('transport', 'auth')
            if (-not $Refresh -and $canUseStaleCache -and $cacheIdentityMatches -and $cachedModelIds.Count -gt 0) {
                $modelIds = @($cachedModelIds)
                $available = @($cachedModelIds)
                Write-Host "Warning: model refresh failed; using stale cache for '$($selected.id)': $($fetchError.Exception.Message)" -ForegroundColor Yellow
            } else {
                throw $fetchError
            }
        } else {
            if ($modelIds.Count -eq 0) { Write-Err 'No models were returned by the provider.'; exit 1 }
            $available = @(Update-ByokCacheForProvider $selected.id $base $apiPath $modelIds $dataDir)
            Write-Inf "Saved $($modelIds.Count) models to $(Join-Path $dataDir 'models-cache.json')"
        }
    }

    $modelFallbackEnv = if ($selectedCli.modelEnvName) { $selectedCli.modelEnvName } else { $null }
    $envModel = [Environment]::GetEnvironmentVariable($modelFallbackEnv)
    $availableModelSet = @($available)
    $providerChanged = ($rememberedProviderId -and $selected.id -ne $rememberedProviderId)
    $isOpenCode = $selectedCli.adapter -ceq 'opencode-config-v1'
    if ($isOpenCode) {
        $modelSelection = Resolve-ByokChosenModelSelection $Model $envModel $rememberedModel $availableModelSet $providerChanged
        $chosenModel = $modelSelection.model
        if (-not $chosenModel) { Write-Err 'No model is available. Run again with -Refresh or specify -Model explicitly.'; exit 1 }
    } else {
        $chosenModel = Resolve-ByokChosenModel $Model $envModel $rememberedModel $availableModelSet $providerChanged
        $modelSelection = [pscustomobject]@{ model = $chosenModel; source = if ($Model) { 'option' } elseif ($envModel) { 'environment' } else { 'state-or-fallback' } }
    }

    $resolvedCliArgs = @(Resolve-ByokCliArgs $selectedCli $selected $base $chosenModel $apiKey $selected.id)
    $resolvedLaunchArgs = @($resolvedCliArgs)
    if ($LaunchArgs) { $resolvedLaunchArgs += @($LaunchArgs) }

    $envMap = if ($isOpenCode) {
        Build-ByokAdapterRuntimeEnvMap $selected $base $chosenModel $apiKey $selected.id $selectedCli
    } else {
        Build-ByokRuntimeEnvMap $selected $base $chosenModel $apiKey $selected.id $selectedCli
    }
    $envMap['BYOK_CLI_HUB_DATA_DIR'] = $dataDir
    $openCodeOutput = $null
    $openCodeConfigPath = $null
    if ($isOpenCode -and -not $Refresh) {
        $openCodeConfigPath = Get-ByokOpenCodeConfigPath $dataDir $selectedCli.configFileName
        $openCodeOutput = Build-ByokOpenCodeConfig $selectedCli.template $selected.id $selected.name $base $apiKey ($selected.apiKeyRequired -ne $false) $availableModelSet $chosenModel $modelSelection.source
        $envMap['OPENCODE_CONFIG'] = $openCodeConfigPath
        if ($apiKey) { $envMap['BYOK_CLI_HUB_OPENCODE_API_KEY'] = $apiKey }
    }

    $state = [ordered]@{
        cliId           = $selectedCli.id
        cliName         = $selectedCli.name
        providerId      = $selected.id
        providerName    = $selected.name
        providerType    = if ($selected.type) { $selected.type } else { 'openai' }
        baseUrl         = $base
        model           = $chosenModel
        modelSource     = $modelSelection.source
        apiKeySource    = Get-ByokApiKeySource $keyEnvName $fromPrompt $fromArgument ([bool]$apiKey)
        updatedAt       = (Get-Date).ToString('o')
    }
    if ($isOpenCode) {
        $state['runtimeProviderId'] = if ($openCodeOutput) { $openCodeOutput.runtimeProviderId } else { Get-ByokOpenCodeProviderId $selected.id }
        $state['runtimeConfigType'] = 'opencode-config-v1'
    }

    $cliCmdName = if ($selectedCli.command) { $selectedCli.command } else { 'copilot' }
    $cliExe = $null
    if (-not $DryRun -and -not $Refresh) {
        $cliExe = if ($EnvFile) { Resolve-ByokCmdExecutable $cliCmdName } else { Get-Command $cliCmdName -ErrorAction SilentlyContinue }
        if (-not $cliExe) {
            if ($EnvFile) { Write-Err "The '$cliCmdName' command has no CMD-compatible .com, .exe, .bat, or .cmd executable in PATH." }
            else { Write-Err "The '$cliCmdName' command was not found in PATH." }
            exit 5
        }
        if ($isOpenCode) {
            Write-ByokOpenCodeConfig $openCodeConfigPath $openCodeOutput.config | Out-Null
            Write-Inf "Generated OpenCode config: $openCodeConfigPath"
            Write-Inf "OpenCode runtime provider: $($openCodeOutput.runtimeProviderId) ($(@($openCodeOutput.models).Count) models)"
        }
    }
    if (-not $DryRun) { Write-ByokState $state $dataDir }

    Write-Inf "Provider: $($selected.name)"
    Write-Inf "Model: $chosenModel"
    Write-Inf ("API key: " + $(if ($apiKey) { '[set]' } elseif ($selected.apiKeyRequired -eq $false) { '[not required]' } elseif ($DryRun) { '[missing]' } else { '[not set]' }))

    if ($EnvFile) {
        $shouldLaunch = -not $DryRun -and -not $Refresh
        Write-ByokCmdLaunchPlan $EnvFile $envMap $(if ($cliExe) { $cliExe.Source } else { '' }) $resolvedLaunchArgs $selectedCli.id $shouldLaunch
        if ($shouldLaunch) { Write-Inf 'Prepared caller CMD environment.' }
        return
    }

    if ($DryRun) { Write-Inf 'Dry run complete.'; return }
    if ($Refresh) { Write-Inf 'Model cache refresh complete.'; return }

    Write-Host 'Applying BYOK environment in the current session...' -ForegroundColor Cyan
    $processEnvironment = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
    $previousEnvironment = [ordered]@{}
    foreach ($k in $envMap.Keys) {
        $previousEnvironment[$k] = [pscustomobject]@{
            present = $processEnvironment.Contains($k)
            value = [Environment]::GetEnvironmentVariable($k, [EnvironmentVariableTarget]::Process)
        }
    }
    $childExitCode = 1
    try {
        foreach ($k in $envMap.Keys) { Set-Item -Path "Env:$k" -Value $envMap[$k] }
        Write-Host "Launching $($selectedCli.name)..." -ForegroundColor Cyan
        & $cliExe.Source @resolvedLaunchArgs
        $childExitCode = $LASTEXITCODE
    } finally {
        foreach ($k in $previousEnvironment.Keys) {
            $previous = $previousEnvironment[$k]
            $restoreValue = if ($previous.present) { $previous.value } else { $null }
            [Environment]::SetEnvironmentVariable($k, $restoreValue, [EnvironmentVariableTarget]::Process)
        }
    }
    if ($isOpenCode -and $childExitCode -ne 0) {
        Write-Err "OpenCode exited with code $childExitCode. Generated config: $openCodeConfigPath"
        Write-Err 'Check the merged configuration with: opencode debug config'
        Write-Err "Check provider models with: opencode models $($openCodeOutput.runtimeProviderId)"
    }
    exit $childExitCode
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
