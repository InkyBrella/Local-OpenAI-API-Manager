# 接入排查

## 获取模型时返回 502

如果「最近请求」显示 `models 502`，下一行是 `upstream_connection_or_stream_error`，说明管理器已收到本地请求，连接 OpenAI 时发生了错误。新版会在后面显示具体网络错误码。`ENOTFOUND` 表示 DNS 解析失败，`ETIMEDOUT` 表示超时，`ERR_PROXY_TUNNEL` 表示 HTTP 代理隧道未建立。证书校验失败时，检查网络代理使用的证书是否已由你信任并正确安装到 Windows 证书存储。

管理器会优先使用 `HTTPS_PROXY`，未设置时读取 Windows 针对 OpenAI 地址解析出的系统 HTTP(S) 代理，并遵循 `NO_PROXY`。如果可用的代理只在其他应用里单独配置，可以在解压目录打开 PowerShell，按实际地址设置受信任的 HTTP 代理后启动：

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
.\API-Manager.cmd
```

`7890` 只是示例，请填写该代理的 **HTTP 或 Mixed 端口**。重新打开管理器后按 **M** 验证。若仍有错误，排查时提供状态、网络错误码和 Endpoint 即可。

## CLI 可以请求，桌面 App 返回 422

`responses_lite_tool_declarations_not_supported_use_standard_catalog` 表示代理在本地收到无法安全转换的 Lite 工具声明，已结束该请求。CLI 如果是用 `Start-Codex.ps1` 打开的，会直接为本次进程传入目录配置；App 则从自己加载的配置读取。不要因为 CLI 成功而跳过以下检查：

1. 按 **D** 看管理器检查的 `config.toml` 路径和状态。在 CC Switch 选中本地供应商；缺少目录或指向旧安装时按 **I**，再按 **D**。
2. 在 Codex App 核对它实际加载的配置文件与 **D** 显示的是同一份。使用了自定义 `CODEX_HOME`、CC Switch 自定义目录或 Codex profile 时，也检查相应目录和 profile 内的 `model_catalog_json`。
3. 核对 App 实际选择的模型在 `model-catalog.standard.json` 里设为 `"use_responses_lite": false`。**D** 检查的是 TOML 的默认模型；会话里选中的模型可能不同。
4. 完全退出并重开 Codex App，再新建对话测试。保留原会话作为对照。如果新会话仍报错，先记录 **D** 的结果、App 选择的模型和新的日志错误码。不要把含令牌的完整配置发给别人。
