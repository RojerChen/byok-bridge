#requires -Version 5.1
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("byok-win-shell-{0}" -f [guid]::NewGuid().ToString('N'))
$dataDir = Join-Path $testRoot 'data'
$fakeBin = Join-Path $testRoot 'bin'
$planTemp = Join-Path $testRoot 'temp'
New-Item -ItemType Directory -Force -Path $dataDir, $fakeBin, $planTemp | Out-Null

try {
    $config = [ordered]@{
        version = 1
        clis = [ordered]@{
            opencode = [ordered]@{
                name = 'OpenCode test CLI'
                command = 'opencode'
                args = @()
                adapter = 'opencode-config-v1'
                configEnvName = 'OPENCODE_CONFIG'
                configFileName = 'opencode.json'
                template = [ordered]@{
                    '$schema' = 'https://opencode.ai/config.json'
                    provider = [ordered]@{
                        '{opencode_provider_id}' = [ordered]@{
                            npm = '@ai-sdk/openai-compatible'
                            name = '{provider_name}'
                            options = [ordered]@{ baseURL = '{url}'; apiKey = '{api_key_ref}' }
                            models = '{models}'
                        }
                    }
                    model = '{opencode_provider_id}/{model}'
                }
                environment = [ordered]@{ CLI_SELECTED_ENV = '{model}' }
            }
        }
        providers = [ordered]@{
            duotify = [ordered]@{
                name = 'Duotify'
                enabled = $true
                type = 'openai'
                baseUrl = 'https://gateway.example/v1'
                apiKeyRequired = $true
                apiKeyEnv = @('DUOTIFY_API_KEY')
                modelEnvNames = @('COPILOT_MODEL')
                models = @('model-a')
                environment = [ordered]@{
                    COPILOT_PROVIDER_BASE_URL = '{url}'
                    COPILOT_PROVIDER_API_KEY = '{api_key}'
                    opencode = [ordered]@{ PROVIDER_SELECTED_ENV = '{provider_id}' }
                }
            }
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $dataDir 'providers.json'),
        (($config | ConvertTo-Json -Depth 30) + "`n"),
        (New-Object Text.UTF8Encoding $false)
    )

    $fakeCli = @'
@echo off
if not "%COPILOT_PROVIDER_BASE_URL%"=="https://gateway.example/v1" exit /b 41
if not "%COPILOT_PROVIDER_API_KEY%"=="test-secret" exit /b 42
if not "%DUOTIFY_API_KEY%"=="test-secret" exit /b 43
if not "%COPILOT_MODEL%"=="model-a" exit /b 44
if not "%CLI_SELECTED_ENV%"=="model-a" exit /b 45
if not "%PROVIDER_SELECTED_ENV%"=="duotify" exit /b 46
if not "%BYOK_BRIDGE_OPENCODE_API_KEY%"=="test-secret" exit /b 47
if not exist "%OPENCODE_CONFIG%" exit /b 48
exit /b 0
'@
    [IO.File]::WriteAllText((Join-Path $fakeBin 'opencode.cmd'), $fakeCli, [Text.Encoding]::ASCII)
    # PowerShell resolves a same-name .ps1 before an npm-style .cmd shim. The
    # caller-CMD launcher must deliberately choose the CMD-compatible shim.
    [IO.File]::WriteAllText((Join-Path $fakeBin 'opencode.ps1'), "exit 99`n", (New-Object Text.UTF8Encoding $false))

    $runCmd = Join-Path $repoRoot 'bin\win\run.cmd'
    $driver = @"
@echo off
set "DUOTIFY_API_KEY="
call "$runCmd" -Cli opencode -Provider duotify -Model model-a -ApiKey test-secret
if errorlevel 1 exit /b %errorlevel%
if not "%COPILOT_PROVIDER_BASE_URL%"=="https://gateway.example/v1" exit /b 51
if not "%CLI_SELECTED_ENV%"=="model-a" exit /b 52
if not "%PROVIDER_SELECTED_ENV%"=="duotify" exit /b 53
if not "%DUOTIFY_API_KEY%"=="test-secret" exit /b 54
if not defined OPENCODE_CONFIG exit /b 55
call "$runCmd" -Cli opencode -Provider duotify -Model model-a
if errorlevel 1 exit /b %errorlevel%
if not "%DUOTIFY_API_KEY%"=="test-secret" exit /b 56
echo WINDOWS_CALLER_ENV_OK
exit /b 0
"@
    $driverPath = Join-Path $testRoot 'driver.cmd'
    [IO.File]::WriteAllText($driverPath, $driver, [Text.Encoding]::ASCII)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = "/d /v:off /c `"$driverPath`""
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['BYOK_BRIDGE_DATA_DIR'] = $dataDir
    $startInfo.EnvironmentVariables['TEMP'] = $planTemp
    $startInfo.EnvironmentVariables['TMP'] = $planTemp
    $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$($startInfo.EnvironmentVariables['PATH'])"
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        throw 'Windows caller-shell integration test timed out (possible unexpected API-key prompt).'
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    Assert-True ($process.ExitCode -eq 0) "Windows caller-shell integration failed with $($process.ExitCode):`n$stdout`n$stderr"
    Assert-True ($stdout -match 'WINDOWS_CALLER_ENV_OK') 'Windows caller-shell success marker was missing.'
    Assert-True ($stdout -notmatch 'test-secret' -and $stderr -notmatch 'test-secret') 'Windows caller-shell output leaked the API key.'
    Assert-True ((Get-ChildItem -LiteralPath $planTemp -Force | Measure-Object).Count -eq 0) 'A temporary CMD environment plan was not removed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataDir 'opencode.json')) 'OpenCode config was not generated.'
    Write-Host 'Windows shell integration test passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
