Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Resolve-ProxyNode {
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne 'AMD64') { throw 'This package requires Windows x64.' }
    $nodePath = Join-Path $PSScriptRoot 'runtime\win-x64\node.exe'
    if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
        $systemNode = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $systemNode) { throw 'Node.js not found. Extract the complete Windows package, or install Node.js 24 or newer.' }
        $nodePath = $systemNode.Source
    }
    $version = & $nodePath --version
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.') { throw "Could not start Node.js: $nodePath" }
    if ([int]$Matches[1] -lt 24) { throw "Node.js 24 or newer is required. Found $version at $nodePath." }
    return $nodePath
}

function Start-ProxyProcess([string]$NodePath, [string]$LogPath) {
    $proxyFile = Join-Path $PSScriptRoot 'proxy.mjs'
    # Let Node open the log as a literal path. Start-Process redirection treats brackets as wildcards.
    $previousLog = $env:LOCAL_PROXY_SERVER_LOG
    [IO.File]::WriteAllText($LogPath, '')
    try {
        $env:LOCAL_PROXY_SERVER_LOG = $LogPath
        return Start-Process -FilePath $NodePath -ArgumentList @('"' + $proxyFile + '"') -WindowStyle Hidden -PassThru
    } finally {
        if ($null -eq $previousLog) { Remove-Item Env:LOCAL_PROXY_SERVER_LOG }
        else { $env:LOCAL_PROXY_SERVER_LOG = $previousLog }
    }
}

function New-ProxyToken {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return 'lp-' + ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
}

function Protect-ProxySecret([Security.SecureString]$Secret) {
    return ConvertFrom-SecureString -SecureString $Secret
}

function Unprotect-ProxySecret([string]$Protected) {
    $secure = ConvertTo-SecureString $Protected
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $secure.Dispose() }
}

function Save-ProxyVault($Vault, [string]$Path) {
    $directory = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Force -Path $directory
    $temporary = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, ($Vault | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Read-ProxyVault([string]$Path, [int]$Port = 8787, [string]$Model = 'gpt-5.6-sol') {
    if (Test-Path -LiteralPath $Path) {
        $vault = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($vault.version -ne 1) { throw 'Unsupported vault version.' }
        # Verify DPAPI ownership without displaying the decrypted value.
        $null = Unprotect-ProxySecret $vault.tokenProtected
        return $vault
    }
    $token = ConvertTo-SecureString (New-ProxyToken) -AsPlainText -Force
    try {
        $vault = [pscustomobject]@{ version = 1; port = $Port; model = $Model;
            tokenProtected = (Protect-ProxySecret $token); activeName = $null; keys = @() }
    } finally { $token.Dispose() }
    Save-ProxyVault $vault $Path
    return $vault
}

function Add-ProxyKey($Vault, [string]$Name, [Security.SecureString]$Secret) {
    if ($Name -notmatch '^[\p{L}\p{N}_. -]{1,40}$') { throw 'Use 1-40 letters, numbers, spaces, _, . or - for the key name.' }
    $protected = Protect-ProxySecret $Secret
    $plain = Unprotect-ProxySecret $protected
    if ([string]::IsNullOrWhiteSpace($plain) -or $plain -match '\s' -or $plain.Length -lt 8) { throw 'Invalid API key: empty, too short, or contains whitespace.' }
    $hint = '...' + $plain.Substring([Math]::Max(0, $plain.Length - 4))
    $plain = $null
    $Vault.keys = @($Vault.keys | Where-Object { $_.name -ne $Name }) + @([pscustomobject]@{
        name = $Name; hint = $hint; protectedKey = $protected })
    if (-not $Vault.activeName) { $Vault.activeName = $Name }
}

function Get-ProxyCredential($Vault, [string]$Name) {
    $entry = @($Vault.keys | Where-Object { $_.name -eq $Name })
    if ($entry.Count -ne 1) { throw 'Key not found.' }
    return [pscustomobject]@{ name = $entry[0].name; apiKey = (Unprotect-ProxySecret $entry[0].protectedKey) }
}

function Remove-ProxyKey($Vault, [string]$Name) {
    if ($Vault.activeName -eq $Name) { throw 'Select another key before removing the active key.' }
    $Vault.keys = @($Vault.keys | Where-Object { $_.name -ne $Name })
}

function Export-ProxyConnection($Vault, [string]$Directory) {
    $null = New-Item -ItemType Directory -Force -Path $Directory
    $token = Unprotect-ProxySecret $Vault.tokenProtected
    $catalog = (Join-Path $PSScriptRoot 'model-catalog.standard.json').Replace('\', '/')
    $modelLiteral = ConvertTo-Json -InputObject ([string]$Vault.model) -Compress
    $catalogLiteral = ConvertTo-Json -InputObject $catalog -Compress
    $config = @"
model_provider = "custom"
model = $modelLiteral
model_catalog_json = $catalogLiteral

[model_providers.custom]
name = "Local OpenAI Manager"
base_url = "http://127.0.0.1:$($Vault.port)/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
experimental_bearer_token = "$token"
"@
    $auth = @{ OPENAI_API_KEY = $token } | ConvertTo-Json
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $Directory 'ccswitch-config.toml'), $config + "`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'ccswitch-auth.json'), $auth + "`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'local-token.txt'), $token + "`n", $encoding)
    return [pscustomobject]@{ baseUrl = "http://127.0.0.1:$($Vault.port)/v1"; token = $token; directory = $Directory }
}

function Start-ManagedProxy($Vault, [string]$LogDirectory) {
    $nodePath = Resolve-ProxyNode
    $null = New-Item -ItemType Directory -Force -Path $LogDirectory
    $instance = [Guid]::NewGuid().ToString('N')
    $adminToken = New-ProxyToken
    $localToken = Unprotect-ProxySecret $Vault.tokenProtected
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $instance.Substring(0, 8)
    $names = @('OPENAI_API_KEY', 'CODEX_PROXY_KEY', 'LOCAL_PROXY_ADMIN_TOKEN', 'LOCAL_PROXY_PORT',
        'LOCAL_PROXY_AUDIT', 'LOCAL_PROXY_INSTANCE', 'LOCAL_PROXY_KEY_NAME')
    $previous = @{}
    foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $null, 'Process')
        $env:LOCAL_PROXY_KEY_NAME = 'none'
        if ($Vault.activeName) {
            $selected = Get-ProxyCredential $Vault $Vault.activeName
            $env:OPENAI_API_KEY = $selected.apiKey
            $env:LOCAL_PROXY_KEY_NAME = $selected.name
        }
        $env:CODEX_PROXY_KEY = $localToken
        $env:LOCAL_PROXY_ADMIN_TOKEN = $adminToken
        $env:LOCAL_PROXY_PORT = [string]$Vault.port
        $env:LOCAL_PROXY_INSTANCE = $instance
        $env:LOCAL_PROXY_AUDIT = Join-Path $LogDirectory "audit-$runId.jsonl"
        $auditPath = $env:LOCAL_PROXY_AUDIT
        $serverLog = Join-Path $LogDirectory "server-$runId.log"
        $process = Start-ProxyProcess $nodePath $serverLog
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
    $session = [pscustomobject]@{ process = $process; base = "http://127.0.0.1:$($Vault.port)";
        adminToken = $adminToken; instanceId = $instance; auditPath = $auditPath }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($process.HasExited) {
            if ([IO.File]::ReadAllText($serverLog).Contains('EADDRINUSE')) {
                throw "Port $($Vault.port) is already in use. Close the old proxy or start API-Manager.cmd with -Port 8788."
            }
            throw "Proxy exited. Check $serverLog."
        }
        try {
            $status = Invoke-ProxyManager $session 'GET' '/admin/status'
            if ($status.instance_id -eq $instance) { return $session }
        } catch { }
        Start-Sleep -Milliseconds 200
    }
    Stop-ManagedProxy $session
    throw "Proxy did not become ready. Check $serverLog"
}

function Stop-ManagedProxy($Session) {
    if ($Session -and $Session.process -and -not $Session.process.HasExited) {
        Stop-Process -Id $Session.process.Id -ErrorAction SilentlyContinue
        $null = $Session.process.WaitForExit(3000)
    }
}

function Invoke-ProxyManager($Session, [string]$Method, [string]$Path, $Body = $null) {
    $params = @{ Uri = $Session.base + $Path; Method = $Method;
        Headers = @{ Authorization = 'Bearer ' + $Session.adminToken }; TimeoutSec = 5;
        UseBasicParsing = $true; MaximumRedirection = 0 }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json; charset=utf-8'
        $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
    }
    return Invoke-RestMethod @params
}

Export-ModuleMember -Function New-ProxyToken, Protect-ProxySecret, Unprotect-ProxySecret, Save-ProxyVault,
    Read-ProxyVault, Add-ProxyKey, Get-ProxyCredential, Remove-ProxyKey, Export-ProxyConnection, Resolve-ProxyNode,
    Start-ProxyProcess, Start-ManagedProxy, Stop-ManagedProxy, Invoke-ProxyManager
