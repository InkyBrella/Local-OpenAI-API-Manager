[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Port = 8787,
    [string]$Model = 'gpt-5.6-sol',
    [string]$StateDirectory,
    [switch]$InitializeOnly,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyManager.psm1') -Force -DisableNameChecking
if (-not $StateDirectory) { $StateDirectory = Join-Path $PSScriptRoot '.local' }
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$null = New-Item -ItemType Directory -Force -Path $StateDirectory
$lock = $null
$session = $null
$vaultPath = Join-Path $StateDirectory 'vault.json'
$connectionDirectory = Join-Path $StateDirectory 'connection'
$displayTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$modelIdPattern = '^[A-Za-z0-9_.:/-]{1,100}$'

function Show-Connection {
    $connection = Export-ProxyConnection $vault $connectionDirectory
    Clear-Host
    Write-Host 'CC SWITCH / 自定义 Responses 供应商' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Name:       Local OpenAI Manager'
    Write-Host "API URL:    $($connection.baseUrl)" -ForegroundColor Green
    Write-Host "API Key:    $($connection.token)" -ForegroundColor Yellow
    Write-Host "Model:      $($vault.model)"
    Write-Host 'Protocol:   OpenAI Responses (native)'
    Write-Host ''
    Write-Host '把生成的 TOML 粘贴到供应商的 config.toml 编辑区。'
    Write-Host '配置中已固定本地令牌，并指定标准 Responses 模型目录。'
    Write-Host "Config:     $(Join-Path $connection.directory 'ccswitch-config.toml')"
    Write-Host "Auth JSON:  $(Join-Path $connection.directory 'ccswitch-auth.json')"
    Write-Host ''
    Write-Host '建议在 CC Switch 为 Codex 选直连模式，保存后重启 Codex。'
    Write-Host '使用该供应商期间，请保持管理窗口打开。'
    Write-Host '这里显示的是本地令牌，导出文件不含真实 OpenAI Key。'
    $null = Read-Host '回车返回'
}

function Resolve-CCSwitchPath([string]$Path, [string]$ProfilePath) {
    if ($Path -eq '~') { return $ProfilePath }
    if ($Path -match '^~[/\\](.+)$') { return Join-Path $ProfilePath $Matches[1] }
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'CC Switch 使用了相对配置目录，请在 CC Switch 中检查目录设置。' }
    return $Path
}

function Get-CCSwitchCodexConfig {
    $profilePath = [Environment]::GetFolderPath('UserProfile')
    $ccSwitchPath = Join-Path $profilePath '.cc-switch'
    $appPathsFile = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'com.ccswitch.desktop\app_paths.json'
    if (Test-Path -LiteralPath $appPathsFile -PathType Leaf) {
        $appPaths = Get-Content -LiteralPath $appPathsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($appPaths.app_config_dir_override) {
            $override = Resolve-CCSwitchPath $appPaths.app_config_dir_override $profilePath
            if (Test-Path -LiteralPath $override -PathType Container) { $ccSwitchPath = $override }
        }
    }
    $codexPath = Join-Path $profilePath '.codex'
    $settingsFile = Join-Path $ccSwitchPath 'settings.json'
    if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
        $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($settings.codexConfigDir) { $codexPath = Resolve-CCSwitchPath $settings.codexConfigDir $profilePath }
    }
    return Join-Path $codexPath 'config.toml'
}

function Install-CCSwitchProvider {
    Clear-Host
    $connection = Export-ProxyConnection $vault $connectionDirectory
    $nodePath = Resolve-ProxyNode
    $helper = Join-Path $PSScriptRoot 'ccswitch-setup.mjs'
    $connectionFile = Join-Path $connection.directory 'ccswitch-config.toml'
    $configPath = Get-CCSwitchCodexConfig
    $opened = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $deadline) {
        $json = & $nodePath $helper 'sync' $connectionFile $configPath
        if ($LASTEXITCODE -ne 0) { throw '无法同步 Codex 配置。可按 C 查看手动配置。' }
        $result = $json | ConvertFrom-Json
        if ($result.status -in 'updated', 'current') {
            Write-Host 'CC Switch 的本地供应商已生效，标准模型目录已配置。' -ForegroundColor Green
            Write-Host "Codex 配置：$configPath"
            if ($result.backup) { Write-Host "原配置备份：$($result.backup)" }
            Write-Host '请重启 Codex，以加载刚才的配置。'
            $null = Read-Host '回车返回'
            return
        }
        if (-not $opened -and $result.status -eq 'not_active') {
            if (-not (Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\ccswitch\shell\open\command')) {
                throw '未找到 CC Switch 的导入协议。请先安装并启动 CC Switch，或按 C 查看手动配置。'
            }
            $url = & $nodePath $helper 'link' $connectionFile
            if ($LASTEXITCODE -ne 0 -or -not $url.StartsWith('ccswitch://v1/import?')) { throw '无法生成 CC Switch 导入链接。' }
            Start-Process -FilePath $url
            $opened = $true
            Write-Host '请在 CC Switch 的 Codex 页面使用直连模式，并在导入框保留「导入后立即切换」后点击「导入」。'
            Write-Host '管理器检测到配置生效后会自动写入标准模型目录。按 Esc 可停止等待。'
        }
        if ($interactiveConsole -and [Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Escape') { return }
        Start-Sleep -Seconds 1
    }
    throw '未检测到本地供应商生效。请检查 CC Switch 是否已导入、是否处于直连模式，再按 I 重试。'
}

function Show-CodexConfigCheck {
    Clear-Host
    $configPath = Get-CCSwitchCodexConfig
    Write-Host "CC Switch 配置目标：$configPath" -ForegroundColor Cyan
    if ($env:CODEX_HOME) {
        Write-Host "当前管理器的 CODEX_HOME：$env:CODEX_HOME"
        Write-Host '请核对 Codex App 实际使用的目录与 CC Switch 配置目标是否相同。' -ForegroundColor Yellow
    }
    $nodePath = Resolve-ProxyNode
    $helper = Join-Path $PSScriptRoot 'ccswitch-setup.mjs'
    $connectionFile = Join-Path $connectionDirectory 'ccswitch-config.toml'
    $json = & $nodePath $helper 'inspect' $connectionFile $configPath
    if ($LASTEXITCODE -ne 0) { throw '无法检查 Codex 配置。请检查上述文件是否是有效的 TOML。' }
    $result = $json | ConvertFrom-Json
    if ($result.model) { Write-Host "配置中的默认模型：$($result.model)" }
    switch ($result.status) {
        'current' { Write-Host '配置指向本管理器，所查模型已配置标准 Responses。若 App 仍报 422，请核对 App 的配置文件、当前模型，并完全退出后重开。' -ForegroundColor Green }
        'missing_config' { Write-Host '未找到 config.toml。请核对 CC Switch 的 Codex 配置目录。' -ForegroundColor Yellow }
        'not_active' { Write-Host '当前供应商、地址、协议或令牌与本管理器不匹配。请在 CC Switch 使用直连模式并选择本地供应商，然后按 I。' -ForegroundColor Yellow }
        'missing_catalog' { Write-Host '缺少顶层 model_catalog_json。请按 I 同步标准模型目录。' -ForegroundColor Yellow }
        'different_catalog' { Write-Host 'model_catalog_json 没有指向此安装的目录文件。若要使用本管理器的模型目录，请按 I。' -ForegroundColor Yellow }
        'invalid_catalog' { Write-Host '此安装的标准模型目录缺失或无法读取。请从发布包恢复 model-catalog.standard.json。' -ForegroundColor Yellow }
        'model_not_listed' { Write-Host '这个配置的默认模型未在标准目录中声明。请核对 Codex 当前模型和项目可用的模型。' -ForegroundColor Yellow }
        'lite_enabled' { Write-Host '这个模型没有显式关闭 Responses Lite。请核对目录版本和配置。' -ForegroundColor Yellow }
    }
    Write-Host '此检查只读取配置文件，不会向 OpenAI 发请求。'
    $null = Read-Host '回车返回'
}

function Pick-Key([string]$Title) {
    Write-Host $Title -ForegroundColor Cyan
    $entries = @($vault.keys)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $marker = if ($entries[$i].name -eq $vault.activeName) { '*' } else { ' ' }
        Write-Host ('  {0}. {1} {2}  {3}' -f ($i + 1), $marker, $entries[$i].name, $entries[$i].hint)
    }
    $answer = Read-Host '输入编号，留空取消'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $entries.Count) { return $null }
    return $entries[$number - 1].name
}

function Apply-ActiveKey {
    if ($vault.activeName) {
        $credential = Get-ProxyCredential $vault $vault.activeName
        $null = Invoke-ProxyManager $session 'POST' '/admin/credential' $credential
        $credential = $null
    }
}

function Select-ApiModel {
    Clear-Host
    $models = @()
    $listMessage = '请先添加或选择 API Key。'
    if ($vault.activeName) {
        Write-Host "正在获取模型（Key：$($vault.activeName)）..." -ForegroundColor Cyan
        try {
            $response = Invoke-RestMethod -Method Get -Uri "$($connection.baseUrl)/models" `
                -Headers @{ Authorization = 'Bearer ' + $connection.token } `
                -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 15
            if ($null -eq $response -or -not $response.PSObject.Properties['data']) { throw '模型列表返回格式不正确。' }
            $models = @($response.data | ForEach-Object { $_.id } |
                Where-Object { $_ -is [string] -and $_ -cmatch $modelIdPattern } | Sort-Object -Unique)
            $listMessage = '当前 Key 的模型列表为空。'
        } catch {
            $failure = $_
            $listMessage = "获取模型失败。$($failure.Exception.Message)"
            if ($failure.ErrorDetails -and $failure.ErrorDetails.Message) {
                try {
                    $detail = ($failure.ErrorDetails.Message | ConvertFrom-Json).error
                    if ($detail.type -ceq 'local_proxy_error' -and $detail.network_code -cmatch '^[A-Z][A-Z0-9_]{1,63}$') {
                        $listMessage += "  网络错误：$($detail.network_code)"
                    }
                } catch { } # Some non-local errors do not contain JSON.
            }
        }
    }

    if (-not $interactiveConsole) {
        if (-not $models.Count) { Write-Host $listMessage -ForegroundColor Yellow }
        for ($i = 0; $i -lt $models.Count; $i++) { Write-Host ('  {0,3}. {1}' -f ($i + 1), $models[$i]) }
        $answer = ([string](Read-Host '输入模型编号或完整模型 ID，留空取消')).Trim()
        $number = 0
        if ([int]::TryParse($answer, [ref]$number)) {
            if ($number -ge 1 -and $number -le $models.Count) { return $models[$number - 1] }
            throw '模型编号超出范围。'
        }
        return $answer
    }

    $query = ''
    $filteredModels = $models
    $selected = [Math]::Max(0, [Array]::IndexOf($models, $vault.model))
    $pageSize = 10
    while ($true) {
        Clear-Host
        Write-Host "  修改默认模型  当前：$($vault.model)" -ForegroundColor Cyan
        Write-Host '  搜索  ' -NoNewline -ForegroundColor Cyan
        Write-Host $query -NoNewline
        $inputLeft = [Console]::CursorLeft
        $inputTop = [Console]::CursorTop
        Write-Host ''
        Write-Host "  匹配 $($filteredModels.Count) / $($models.Count) 个模型" -ForegroundColor DarkGray
        if (-not $models.Count) { Write-Host "  $listMessage" -ForegroundColor Yellow }
        elseif (-not $filteredModels.Count) { Write-Host '  没有匹配的模型，请修改关键词。' -ForegroundColor Yellow }

        $first = [int][Math]::Floor($selected / $pageSize) * $pageSize
        $end = [Math]::Min($first + $pageSize, $filteredModels.Count)
        for ($i = $first; $i -lt $end; $i++) {
            if ($i -eq $selected) {
                Write-Host ('  > {0,3}. {1}' -f ($i + 1), $filteredModels[$i]) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host ('    {0,3}. {1}' -f ($i + 1), $filteredModels[$i])
            }
        }
        Write-Host ''
        Write-Host '  ↑/↓ 选择   PgUp/PgDn 翻页   Enter 保存   Esc 返回   F2 手动输入' -ForegroundColor DarkGray
        [Console]::SetCursorPosition($inputLeft, $inputTop)
        $key = [Console]::ReadKey($true)
        $lastIndex = [Math]::Max(0, $filteredModels.Count - 1)
        $previousQuery = $query
        switch ($key.Key) {
            'UpArrow'   { $selected = [Math]::Max(0, $selected - 1) }
            'DownArrow' { $selected = [Math]::Min($lastIndex, $selected + 1) }
            'PageUp'    { $selected = [Math]::Max(0, $selected - $pageSize) }
            'PageDown'  { $selected = [Math]::Min($lastIndex, $selected + $pageSize) }
            'Home'      { $selected = 0 }
            'End'       { $selected = $lastIndex }
            'Backspace' { if ($query.Length) { $query = $query.Substring(0, $query.Length - 1) } }
            'Enter'     { if ($filteredModels.Count) { return $filteredModels[$selected] } }
            'Escape'    { return }
            'F2' {
                Clear-Host
                return ([string](Read-Host '输入完整模型 ID，留空取消')).Trim()
            }
            default {
                if ($query.Length -lt 100 -and -not [char]::IsControl($key.KeyChar)) { $query += $key.KeyChar }
            }
        }
        if ($query -cne $previousQuery) {
            $filteredModels = $models
            foreach ($keyword in ($query.Trim() -split '\s+')) {
                $filteredModels = @($filteredModels.Where({ $_.IndexOf($keyword, [StringComparison]::OrdinalIgnoreCase) -ge 0 }))
            }
            $selected = [Math]::Max(0, [Array]::IndexOf($filteredModels, $query.Trim()))
        }
    }
}

function Set-DefaultModel([string]$ModelId) {
    if (-not $ModelId) { return }
    if ($ModelId -cnotmatch $modelIdPattern) { throw '模型 ID 格式无效。' }
    $vault.model = $ModelId
    Save-ProxyVault $vault $vaultPath
    $null = Export-ProxyConnection $vault $connectionDirectory
    Write-Host "默认模型已保存：$ModelId" -ForegroundColor Green
    Write-Host '接入文件已更新，请同步 CC Switch 的模型字段并重启 Codex。'
    $null = Read-Host '回车返回'
}

function Edit-DefaultModel {
    $model = Select-ApiModel
    Clear-Host
    Set-DefaultModel $model
}

function Show-Dashboard {
    $status = Invoke-ProxyManager $session 'GET' '/admin/status'
    Clear-Host
    Write-Host '====================================================================' -ForegroundColor DarkCyan
    Write-Host '                     LOCAL OPENAI API MANAGER' -ForegroundColor Cyan
    Write-Host '====================================================================' -ForegroundColor DarkCyan
    Write-Host ('  本地接口    http://127.0.0.1:{0}/v1' -f $vault.port) -ForegroundColor Green
    Write-Host '  上游接口    https://api.openai.com/v1'
    $active = if ($status.credential_name) { $status.credential_name } else { '尚未配置，按 1 添加 Key' }
    Write-Host "  当前 Key    $active" -ForegroundColor Yellow
    Write-Host ('  已存 Key    {0}       默认模型: {1}' -f @($vault.keys).Count, $vault.model)
    $rate = if ($status.completed) { '{0:N1}%' -f (100 * $status.successful / $status.completed) } else { '--' }
    Write-Host ('  本次请求    {0}       HTTP 成功率: {1}       活跃请求: {2}' -f $status.total, $rate, $status.active)
    Write-Host '  过滤状态    已启用：客户端身份头和追踪元数据'
    Write-Host '  实际扣费    请在 API Platform 核对额度及账单'
    Write-Host ''
    Write-Host '  最近请求（时间：America/New York）' -ForegroundColor Cyan
    $rows = @($status.recent | Select-Object -First 8)
    $models = @(foreach ($row in $rows) {
        if ($row.model) { [string]$row.model -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?' }
        else { '--' }
    })
    $endpointWidth = [Math]::Max(8, [int](($rows.endpoint | Measure-Object -Property Length -Maximum).Maximum))
    $modelWidth = [Math]::Max(5, [int](($models | Measure-Object -Property Length -Maximum).Maximum))
    $rowFormat = "  {0,-8}  {1,4}  {2,8}  {3,-8}  {4,-7}  {5,-$endpointWidth}  {6,-$modelWidth}  {7}"
    Write-Host ($rowFormat -f 'Time', 'HTTP', 'Latency', 'Mode', 'Client', 'Endpoint', 'Model', 'Key') -ForegroundColor Cyan
    if (-not $rows.Count) { Write-Host '  等待客户端请求...' -ForegroundColor DarkGray }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $client = if ($row.client -in 'Desktop', 'CLI') { $row.client } else { 'Unknown' }
        $at = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse($row.time), $displayTimeZone).ToString('HH:mm:ss')
        $color = if ($row.status -ge 200 -and $row.status -lt 300 -and -not $row.PSObject.Properties['proxy_error']) { 'Green' } else { 'Yellow' }
        Write-Host ($rowFormat -f $at, $row.status, ($row.duration_ms.ToString() + 'ms'), $row.mode, $client, $row.endpoint, $models[$i], ('[{0}]' -f $row.credential_name)) -ForegroundColor $color
        if ($row.PSObject.Properties['proxy_error']) {
            $detail = $row.proxy_error
            if ($row.network_code) { $detail += " ($($row.network_code))" }
            Write-Host ('           ' + $detail) -ForegroundColor DarkYellow
        }
    }
    Write-Host ''
    Write-Host '  [1] 添加/替换 API Key       [2] 选择当前 Key'
    Write-Host '  [3] 删除未使用的 Key       [I] 导入 / 同步 CC Switch'
    Write-Host '  [C] 查看接入配置           [D] 检查 Codex 配置'
    Write-Host '  [M] 修改默认模型           [R] 刷新       [Q] 停止并退出'
    Write-Host ''
    Write-Host '  Key 使用 Windows 当前用户加密，手动选择，不自动故障转移。' -ForegroundColor DarkGray
    Write-Host '  每 2 秒刷新；按上面的单个按键选择功能。' -ForegroundColor DarkGray
}

try {
    try { $lock = [IO.File]::Open((Join-Path $StateDirectory 'manager.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Another manager is using this state directory. Close it before starting a second one.' }
    $vault = Read-ProxyVault $vaultPath $Port $Model
    if ($PSBoundParameters.ContainsKey('Port')) { $vault.port = $Port }
    if ($PSBoundParameters.ContainsKey('Model')) { $vault.model = $Model }
    Save-ProxyVault $vault $vaultPath
    $connection = Export-ProxyConnection $vault $connectionDirectory
    if ($InitializeOnly) {
        Write-Host "Connection files ready: $connectionDirectory"
        return
    }
    $session = Start-ManagedProxy $vault (Join-Path $PSScriptRoot 'logs')
    if ($Check) {
        $status = Invoke-ProxyManager $session 'GET' '/admin/status'
        Write-Output ('Manager OK: {0}; active key: {1}; saved keys: {2}' -f $connection.baseUrl, $status.credential_name, @($vault.keys).Count)
        return
    }
    $interactiveConsole = -not [Console]::IsInputRedirected
    $quit = $false
    while (-not $quit) {
        Show-Dashboard
        if ($interactiveConsole) {
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            while (-not [Console]::KeyAvailable -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            if (-not [Console]::KeyAvailable) { continue }
            $choice = [string][Console]::ReadKey($true).KeyChar
        } else {
            $choice = Read-Host '命令'
            if ($null -eq $choice) { break }
        }
        try {
            switch ($choice.ToUpperInvariant()) {
                '1' {
                    $name = Read-Host 'Key 名称，例如 personal 或 项目A'
                    if ($name) {
                        $secret = Read-Host '真实 OpenAI API Key，已启用隐藏输入' -AsSecureString
                        try { Add-ProxyKey $vault $name $secret } finally { $secret.Dispose() }
                        Save-ProxyVault $vault $vaultPath
                        Apply-ActiveKey
                    }
                }
                '2' {
                    $name = Pick-Key '选择用于后续请求的 Key'
                    if ($name) {
                        $credential = Get-ProxyCredential $vault $name
                        $null = Invoke-ProxyManager $session 'POST' '/admin/credential' $credential
                        $credential = $null
                        $vault.activeName = $name
                        Save-ProxyVault $vault $vaultPath
                    }
                }
                '3' {
                    $name = Pick-Key '删除本地保存的 Key'
                    if ($name) { Remove-ProxyKey $vault $name; Save-ProxyVault $vault $vaultPath }
                }
                'C' { Show-Connection }
                'I' { Install-CCSwitchProvider }
                'D' { Show-CodexConfigCheck }
                'M' { Edit-DefaultModel }
                'Q' { $quit = $true }
            }
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            $null = Read-Host '回车返回'
        }
    }
} finally {
    Stop-ManagedProxy $session
    if ($lock) { $lock.Dispose() }
}
