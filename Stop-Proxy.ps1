[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Port,
    [string]$StateDirectory,
    [switch]$Pause
)
$ErrorActionPreference = 'Stop'
$exitCode = 0

function Get-PortListeners([int]$LocalPort) {
    Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq $LocalPort
}

try {
    if (-not $PSBoundParameters.ContainsKey('Port')) {
        $Port = 8787
        if (-not $StateDirectory) { $StateDirectory = Join-Path $PSScriptRoot '.local' }
        $vaultPath = Join-Path $StateDirectory 'vault.json'
        if (Test-Path -LiteralPath $vaultPath -PathType Leaf) {
            try { $settings = Get-Content -LiteralPath $vaultPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { throw '无法读取保存的端口。可以在命令行用 -Port 指定端口。' }
            if (-not [int]::TryParse([string]$settings.port, [ref]$Port) -or $Port -lt 1 -or $Port -gt 65535) {
                throw '保存的端口无效。可以在命令行用 -Port 指定端口。'
            }
        }
    }

    $listeners = @(Get-PortListeners $Port)
    if ($listeners.Count -eq 0) {
        Write-Host "端口 $Port 未被监听。" -ForegroundColor Green
    } else {
        $ownerIds = @($listeners | Where-Object LocalAddress -eq '127.0.0.1' |
            Select-Object -ExpandProperty OwningProcess -Unique)
        if ($ownerIds.Count -ne 1) { throw "无法在端口 $Port 确认本代理。" }

        $ownerId = $ownerIds[0]
        $process = Get-Process -Id $ownerId
        try {
            if ($process.ProcessName -ne 'node') { throw "端口 $Port 由其他服务监听（PID $ownerId）。" }
            # Hold the process handle while checking its identity and stopping it.
            $null = $process.Handle
            $details = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId"
            $scriptPath = [regex]::Escape((Join-Path $PSScriptRoot 'proxy.mjs'))
            if ($details.CommandLine -notmatch ('^\s*(?:"[^"]+"|\S+)\s+"' + $scriptPath + '"\s*$')) {
                throw "端口 $Port 由其他进程监听（PID $ownerId）。"
            }
            $currentOwners = @(Get-PortListeners $Port | Where-Object LocalAddress -eq '127.0.0.1' |
                Select-Object -ExpandProperty OwningProcess -Unique)
            if ($currentOwners.Count -ne 1 -or $currentOwners[0] -ne $ownerId) {
                throw "端口 $Port 的监听进程已改变，请重试。"
            }
            if (-not $process.HasExited) { $process.Kill() }
            if (-not $process.WaitForExit(5000)) { throw "代理进程仍在退出（PID $ownerId），请稍后重试。" }
        } finally {
            $process.Dispose()
        }

        if (@(Get-PortListeners $Port).Count) { throw "已停止本代理，但端口 $Port 仍有其他监听。" }
        Write-Host "已停止本地代理（PID $ownerId），端口 $Port 已释放。" -ForegroundColor Green
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($Pause -and -not [Console]::IsInputRedirected) {
        Write-Host '按任意键关闭窗口。'
        $null = [Console]::ReadKey($true)
    }
}
exit $exitCode
