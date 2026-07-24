#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repoRoot 'manager\ByokManager.psm1') -DisableNameChecking -Force -ErrorAction Stop

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

function Start-HttpFixture([int]$Status, [string]$ContentType, [string]$Body, [string]$Location = '') {
    $port = Get-FreeTcpPort
    $ready = Join-Path $env:TEMP "byok-http-ready-$PID-$port"
    $job = Start-Job -ArgumentList $port, $ready, $Status, $ContentType, $Body, $Location -ScriptBlock {
        param($Port, $Ready, $StatusCode, $ResponseContentType, $ResponseBody, $RedirectLocation)
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
        try {
            $listener.Start()
            New-Item -ItemType File -Path $Ready -Force | Out-Null
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') { }
                $bodyBytes = [Text.Encoding]::UTF8.GetBytes($ResponseBody)
                $reason = if ($StatusCode -eq 200) { 'OK' } elseif ($StatusCode -eq 302) { 'Found' } else { 'Error' }
                $headers = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ResponseContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n"
                if ($RedirectLocation) { $headers += "Location: $RedirectLocation`r`n" }
                $headers += "`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()
            } finally {
                $client.Dispose()
            }
        } finally {
            $listener.Stop()
            Remove-Item -LiteralPath $Ready -Force -ErrorAction SilentlyContinue
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ([DateTime]::UtcNow -ge $deadline) { Stop-Job $job -ErrorAction SilentlyContinue; throw 'HTTP fixture did not start.' }
        Start-Sleep -Milliseconds 25
    }
    return [pscustomobject]@{ Port = $port; Job = $job; Ready = $ready }
}

function Stop-HttpFixture($Fixture) {
    Wait-Job $Fixture.Job -Timeout 10 | Out-Null
    Receive-Job $Fixture.Job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $Fixture.Job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Fixture.Ready -Force -ErrorAction SilentlyContinue
}

function New-TestProvider {
    return [pscustomobject]@{
        apiKeyHeader = 'Authorization'
        apiKeyPrefix = 'Bearer '
        modelsApi = [pscustomobject]@{ path = '/models'; itemsPath = 'data'; idPath = 'id' }
    }
}

try {
    $validBody = '{"data":[{"id":"model-a"},{"id":"model-a"},{"id":"bad\u0001"},{"id":"model-b"}]}'
    $fixture = Start-HttpFixture 200 'application/json' $validBody
    try {
        $ids = @(Invoke-ByokModelFetch (New-TestProvider) "http://127.0.0.1:$($fixture.Port)/v1" 'test-secret')
        if ($ids.Count -ne 2 -or $ids[0] -ne 'model-a' -or $ids[1] -ne 'model-b') { throw "Model validation mismatch: $($ids -join ',')" }
    } finally { Stop-HttpFixture $fixture }

    $fixture = Start-HttpFixture 302 'application/json' '{}' 'http://127.0.0.1:1/stolen'
    try {
        $failed = $false
        try { Invoke-ByokModelFetch (New-TestProvider) "http://127.0.0.1:$($fixture.Port)/v1" 'test-secret' | Out-Null } catch { $failed = $_.Exception.Message -match 'HTTP 302' }
        if (-not $failed) { throw 'Redirect was not rejected.' }
    } finally { Stop-HttpFixture $fixture }

    $fixture = Start-HttpFixture 200 'text/plain' '{}'
    try {
        $failed = $false
        try { Invoke-ByokModelFetch (New-TestProvider) "http://127.0.0.1:$($fixture.Port)/v1" '' | Out-Null } catch { $failed = $_.Exception.Message -match 'Expected a JSON response' }
        if (-not $failed) { throw 'Non-JSON content type was not rejected.' }
    } finally { Stop-HttpFixture $fixture }

    $fixture = Start-HttpFixture 200 'application/json' ('x' * 256)
    try {
        $failed = $false
        try { Invoke-ByokModelFetch (New-TestProvider) "http://127.0.0.1:$($fixture.Port)/v1" '' 10 64 | Out-Null } catch { $failed = $_.Exception.Message -match 'exceeds' }
        if (-not $failed) { throw 'Oversized response was not rejected.' }
    } finally { Stop-HttpFixture $fixture }

    Write-Host 'PowerShell HTTP validation tests passed.' -ForegroundColor Green
} finally {
    Get-Job | Where-Object { $_.Name -like 'Job*' } | Remove-Job -Force -ErrorAction SilentlyContinue
}
