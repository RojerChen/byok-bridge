#requires -Version 5.1

$script:ByokUiRequiredMessages = @{
    app = @('name', 'description', 'steps.selectCli', 'steps.selectProvider', 'summary.cli', 'summary.provider')
    prompts = @('selectCli', 'selectProvider', 'apiKey', 'back', 'addProvider', 'exit')
    status = @('selectedCli', 'selectedProvider', 'configurationApplied', 'launching', 'exited')
    errors = @('invalidSelection', 'cancelled')
    hints = @('number')
}

function Get-ByokUiObjectValue {
    param($Object, [string]$Path)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$part]
        if (-not $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Read-ByokUiJson {
    param([string]$Path)
    try {
        $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "UI resource '$Path' could not be read or contains malformed JSON."
    }
    if (-not $parsed -or $parsed.schemaVersion -ne 1) {
        throw "UI resource '$Path' has an unsupported schemaVersion."
    }
    return $parsed
}

function Import-ByokUiResources {
    param([string]$AppRoot)
    if (-not $AppRoot) { throw 'An installed application root is required to load UI resources.' }
    $root = [IO.Path]::GetFullPath($AppRoot)
    $uiRoot = Join-Path $root 'ui'
    $themePath = Join-Path $uiRoot 'theme.json'
    $theme = Read-ByokUiJson $themePath
    if ($null -ne $theme.preferredWidth -and
        (($theme.preferredWidth -isnot [int]) -and ($theme.preferredWidth -isnot [long]) -or
         $theme.preferredWidth -lt 40 -or $theme.preferredWidth -gt 100)) {
        throw "UI resource '$themePath' has an invalid preferredWidth."
    }
    foreach ($symbol in @('default', 'success', 'warning', 'error', 'info')) {
        if ([string]::IsNullOrEmpty("$($theme.symbols.$symbol)")) {
            throw "UI resource '$themePath' is missing the string symbol '$symbol'."
        }
    }

    $messages = [ordered]@{}
    foreach ($group in @('app', 'prompts', 'status', 'errors', 'hints')) {
        $path = Join-Path (Join-Path $uiRoot 'messages') "$group.json"
        $messages[$group] = Read-ByokUiJson $path
        foreach ($messagePath in $script:ByokUiRequiredMessages[$group]) {
            if ([string]::IsNullOrEmpty("$(Get-ByokUiObjectValue $messages[$group] $messagePath)")) {
                throw "UI resource '$path' is missing the string message '$messagePath'."
            }
        }
    }
    return [pscustomobject]@{ root = $root; theme = $theme; messages = $messages }
}

function Format-ByokUiMessage {
    param([string]$Template, [hashtable]$Values = @{})
    return [regex]::Replace($Template, '\{([A-Za-z][A-Za-z0-9_]*)\}', {
        param($match)
        $name = $match.Groups[1].Value
        if (-not $Values.ContainsKey($name) -or $null -eq $Values[$name]) {
            throw "UI message requires placeholder '$name'."
        }
        return "$($Values[$name])"
    })
}

function Get-ByokUiMessage {
    param($Ui, [string]$Group, [string]$Id, [hashtable]$Values = @{})
    $template = Get-ByokUiObjectValue $Ui.messages[$Group] $Id
    if ($template -isnot [string]) { throw "UI message '$Group.$Id' is unavailable." }
    return Format-ByokUiMessage $template $Values
}

function Get-ByokUiWidth {
    param($Ui)
    $preferred = if ($null -ne $Ui.theme.preferredWidth) { [int]$Ui.theme.preferredWidth } else { 60 }
    try {
        $available = [int]$Host.UI.RawUI.WindowSize.Width
        if ($available -gt 0) { return [Math]::Max(4, [Math]::Min($preferred, $available)) }
    } catch { }
    return $preferred
}

function Split-ByokUiText {
    param([string]$Text, [int]$Width)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($original in ($Text -split "`r?`n")) {
        $remaining = "$original"
        do {
            if ($remaining.Length -le $Width) {
                $lines.Add($remaining)
                $remaining = ''
            } else {
                $candidate = $remaining.Substring(0, [Math]::Min($remaining.Length, $Width + 1))
                $breakAt = $candidate.LastIndexOf(' ')
                $cut = if ($breakAt -gt 0) { $breakAt } else { $Width }
                $lines.Add($remaining.Substring(0, $cut))
                $remaining = $remaining.Substring($cut).TrimStart()
            }
        } while ($remaining)
    }
    return @($lines)
}

function Test-ByokUiColorEnabled {
    if ($null -ne $env:NO_COLOR -or $env:BYOK_UI_COLOR -eq '0' -or $env:TERM -eq 'dumb') { return $false }
    try { return -not [Console]::IsOutputRedirected } catch { return $false }
}

function Write-ByokUiLine {
    param([AllowEmptyString()][string]$Text, [string]$Role = '')
    if (-not (Test-ByokUiColorEnabled) -or -not $Role) {
        Write-Host $Text
        return
    }
    $color = switch ($Role) {
        'header' { 'Cyan' }
        'title' { 'White' }
        'section' { 'Cyan' }
        'info' { 'Cyan' }
        'success' { 'Green' }
        'warning' { 'Yellow' }
        'error' { 'Red' }
        'muted' { 'DarkGray' }
        default { $null }
    }
    if ($color) { Write-Host $Text -ForegroundColor $color }
    else { Write-Host $Text }
}

function Write-ByokUiHeader {
    param($Ui)
    $width = Get-ByokUiWidth $Ui
    $inner = [Math]::Max(1, $width - 2)
    $border = '+' + ('-' * $inner) + '+'
    Write-ByokUiLine $border 'header'
    foreach ($text in @($Ui.messages.app.name, $Ui.messages.app.description)) {
        foreach ($line in (Split-ByokUiText "$text" ([Math]::Max(1, $inner - 2)))) {
            Write-ByokUiLine ('| ' + $line.PadRight([Math]::Max(1, $inner - 2)) + ' |') 'header'
        }
    }
    Write-ByokUiLine $border 'header'
}

function Write-ByokUiStep {
    param($Ui, [int]$Step, [string]$Title)
    Write-Host ''
    Write-ByokUiLine "[ Step $Step of 2 ]  $Title" 'title'
    Write-ByokUiLine ('-' * (Get-ByokUiWidth $Ui)) 'muted'
    Write-Host ''
}

function Write-ByokUiChoices {
    param($Ui, [string[]]$Items, [int]$DefaultIndex, [bool]$IncludeBack = $false, [bool]$IncludeExit = $false)
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $marker = if ($index -eq $DefaultIndex) { "$($Ui.theme.symbols.default)" } else { ' ' }
        Write-ByokUiLine ("{0} {1}. {2}" -f $marker, ($index + 1), $Items[$index]) $(if ($index -eq $DefaultIndex) { 'success' } else { '' })
    }
    if ($IncludeBack) { Write-ByokUiLine ('  ' + (Get-ByokUiMessage $Ui 'prompts' 'back')) 'muted' }
    if ($IncludeExit) { Write-ByokUiLine ('  0. ' + (Get-ByokUiMessage $Ui 'prompts' 'exit')) 'muted' }
    Write-Host ''
    Write-ByokUiLine ('-' * (Get-ByokUiWidth $Ui)) 'muted'
    Write-ByokUiLine (Get-ByokUiMessage $Ui 'hints' 'number') 'muted'
}

function Write-ByokUiProviderChoices {
    param($Ui, [string[]]$Providers, [int]$DefaultIndex, [bool]$IncludeAdd = $false, [bool]$IncludeExit = $true)
    $width = Get-ByokUiWidth $Ui
    for ($index = 0; $index -lt $Providers.Count; $index++) {
        $marker = if ($index -eq $DefaultIndex) { "$($Ui.theme.symbols.default)" } else { ' ' }
        Write-ByokUiLine ("{0} {1}. {2}" -f $marker, ($index + 1), $Providers[$index]) $(if ($index -eq $DefaultIndex) { 'success' } else { '' })
    }
    if ($IncludeAdd -or $IncludeExit) { Write-Host '' }
    if ($IncludeAdd) { Write-ByokUiLine ("  {0}. {1}" -f ($Providers.Count + 1), (Get-ByokUiMessage $Ui 'prompts' 'addProvider')) 'warning' }
    if ($IncludeExit) {
        $exitNumber = $Providers.Count + $(if ($IncludeAdd) { 2 } else { 1 })
        Write-ByokUiLine ("  {0}. {1}" -f $exitNumber, (Get-ByokUiMessage $Ui 'prompts' 'exit')) 'muted'
    }
    Write-ByokUiLine ('  ' + (Get-ByokUiMessage $Ui 'prompts' 'back')) 'muted'
    Write-Host ''
    Write-ByokUiLine ('-' * $width) 'muted'
    Write-ByokUiLine (Get-ByokUiMessage $Ui 'hints' 'number') 'muted'
}

function Write-ByokUiStatus {
    param($Ui, [string]$MessageId, [hashtable]$Values = @{})
    Write-ByokUiLine ("{0} {1}" -f $Ui.theme.symbols.info, (Get-ByokUiMessage $Ui 'status' $MessageId $Values)) 'info'
}

function Write-ByokUiSelectionSummary {
    param($Ui, [string]$Cli = '', [string]$Provider = '')
    if ($Cli) {
        Write-ByokUiLine (Get-ByokUiMessage $Ui 'app' 'summary.cli' @{ cli = $Cli }) 'info'
        Write-Host ''
    }
    if ($Provider) {
        Write-ByokUiLine (Get-ByokUiMessage $Ui 'app' 'summary.provider' @{ provider = $Provider }) 'info'
        Write-Host ''
    }
}

function Write-ByokUiError {
    param($Ui, [string]$MessageId, [hashtable]$Values = @{})
    Write-ByokUiLine ("{0} {1}" -f $Ui.theme.symbols.error, (Get-ByokUiMessage $Ui 'errors' $MessageId $Values)) 'error'
}

function Read-ByokUiNumberSelection {
    param($Ui, [string]$Prompt, [int]$Minimum, [int]$Maximum, [int]$Default)
    while ($true) {
        $line = "$(Read-Host $Prompt)".Trim()
        if (-not $line) { return $Default }
        $value = 0
        if ([int]::TryParse($line, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) {
            return $value
        }
        Write-ByokUiError $Ui 'invalidSelection'
    }
}

function Assert-ByokInteractiveConsole {
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
            throw 'Interactive selection is unavailable: provide CLI, provider, base URL, and any required API key through supported non-interactive inputs.'
        }
    } catch [System.IO.IOException] { }
}

function Write-ByokUiSummary {
    param($Ui, [string]$Provider, [string]$Model, [string]$ApiKey, [bool]$ApiKeyRequired)
    $keyStatus = if ($ApiKey) { '[set]' } elseif (-not $ApiKeyRequired) { '[not required]' } else { '[missing]' }
    Write-ByokUiLine "Provider: $Provider" 'info'
    Write-ByokUiLine "Model: $Model" 'info'
    $keyRole = if ($ApiKey) { 'success' } elseif (-not $ApiKeyRequired) { 'muted' } else { 'warning' }
    Write-ByokUiLine "API key: $keyStatus" $keyRole
}

Export-ModuleMember -Function Import-ByokUiResources, Get-ByokUiMessage, Write-ByokUiHeader,
    Write-ByokUiStep, Write-ByokUiChoices, Write-ByokUiProviderChoices, Write-ByokUiStatus, Write-ByokUiSelectionSummary, Write-ByokUiError,
    Read-ByokUiNumberSelection, Assert-ByokInteractiveConsole, Write-ByokUiSummary
