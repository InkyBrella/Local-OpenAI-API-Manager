[CmdletBinding()]
param(
    [string]$Model = 'gpt-6.1-sol',
    [ValidateRange(1, 65535)][int]$Port = 8787,
    [switch]$Baseline,
    [switch]$ProxyOnly,
    [string]$Prompt
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyManager.psm1') -DisableNameChecking
$nodePath = Resolve-ProxyNode
if (-not $ProxyOnly) { $null = Get-Command codex -ErrorAction Stop }
$variableNames = @('OPENAI_API_KEY', 'CODEX_PROXY_KEY', 'LOCAL_PROXY_PORT', 'LOCAL_PROXY_AUDIT', 'LOCAL_PROXY_INSTANCE')
$previous = @{}
foreach ($name in $variableNames) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$proxyProcess = $null
$exitCode = 0

try {
    if (-not $env:OPENAI_API_KEY) {
        $secureKey = Read-Host 'OpenAI API Key (hidden; not saved)' -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        try { $env:OPENAI_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer); $secureKey.Dispose() }
    }
    if (-not $env:OPENAI_API_KEY -or $env:OPENAI_API_KEY -match '[\r\n]') { throw 'A normal API Platform key is required.' }
    $randomBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($randomBytes) } finally { $rng.Dispose() }
    $env:CODEX_PROXY_KEY = [Convert]::ToBase64String($randomBytes)
    $env:LOCAL_PROXY_PORT = [string]$Port
    $env:LOCAL_PROXY_INSTANCE = [Guid]::NewGuid().ToString('N')
    $logDirectory = Join-Path $PSScriptRoot 'logs'
    $null = New-Item -ItemType Directory -Force -Path $logDirectory
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $env:LOCAL_PROXY_INSTANCE.Substring(0, 8)
    $env:LOCAL_PROXY_AUDIT = Join-Path $logDirectory "audit-$runId.jsonl"
    $serverLog = Join-Path $logDirectory "server-$runId.log"
    $proxyProcess = Start-ProxyProcess $nodePath $serverLog
    # Only the proxy keeps the upstream key. The Codex child receives the local token.
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $null, 'Process')
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($proxyProcess.HasExited) { throw "Proxy exited. Check $serverLog" }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -Headers @{ Authorization = "Bearer $env:CODEX_PROXY_KEY" } -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 1
            if ($health.instance_id -eq $env:LOCAL_PROXY_INSTANCE) { $ready = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 200
    }
    if (-not $ready) { throw "Proxy did not become ready. Check port $Port and $serverLog" }
    $baseUrl = "http://127.0.0.1:$Port/v1"
    if ($Baseline) { $baseUrl = "http://127.0.0.1:$Port/baseline/v1" }
    Write-Host "Proxy: $baseUrl"
    Write-Host "Audit: $env:LOCAL_PROXY_AUDIT"
    if ($ProxyOnly) {
        Write-Host 'Local token for another terminal / custom provider (not the OpenAI key):'
        Write-Host ('$env:CODEX_PROXY_KEY = ' + "'$env:CODEX_PROXY_KEY'")
        Write-Host 'Press Ctrl+C to stop the proxy.'
        while (-not $proxyProcess.HasExited) { Start-Sleep -Milliseconds 500 }
        $exitCode = $proxyProcess.ExitCode
    } else {
        $catalogPath = (Join-Path $PSScriptRoot 'model-catalog.standard.json').Replace('\', '/')
        $codexArgs = @(
            '-c', ('model_catalog_json="' + $catalogPath + '"'),
            '-c', 'model_provider="local_probe"',
            '-c', 'model_providers.local_probe.name="Local API probe"',
            '-c', ('model_providers.local_probe.base_url="' + $baseUrl + '"'),
            '-c', 'model_providers.local_probe.env_key="CODEX_PROXY_KEY"',
            '-c', 'model_providers.local_probe.wire_api="responses"',
            '-c', 'model_providers.local_probe.requires_openai_auth=false',
            '-c', 'model_providers.local_probe.supports_websockets=false',
            '-m', $Model
        )
        if ($Prompt) { $codexArgs += @('exec', '--skip-git-repo-check', '--ephemeral', '--sandbox', 'read-only', $Prompt) }
        & codex @codexArgs
        $exitCode = $LASTEXITCODE
    }
} finally {
    Stop-ManagedProxy ([pscustomobject]@{ process = $proxyProcess })
    foreach ($name in $variableNames) {
        if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
}
exit $exitCode
